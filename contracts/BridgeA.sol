// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl}   from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/* -------------------- minimal interfaces -------------------- */
interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address f, address t, uint256 v) external returns (bool);
    function approve(address s, uint256 v) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

interface IERC20Burnable is IERC20 {
    function burnFrom(address a, uint256 v) external;
    function burn(uint256 v) external; // 合约自持时自燃
}

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/* 用于调用 USDT 的 setMinter */
interface IUsdtMinterAdmin {
    function setMinter(address newMinter) external;
}

/* ------ 一级市场（保持原接口） ------ */
interface IBondingCurvePrimaryMarket {
    function sellForUsdt(uint256 ausdAmount, uint256 minUsdtOut, address to) external returns (uint256 usdtOut);
}

/**
 * @title BridgeA (with fees & audited-by-depositId)
 * @notice A 链桥接：AUSD / USDT；支持审核阈值、代币按 rate/base 手续费、原生币固定费、WITHDRAW_ROLE 提现。
 * 审核单使用「目标链的 depositId」作为唯一键；提交时即分配并记录 fee 数值；通过时实际扣费并发 event。
 */
contract BridgeA is AccessControl, ReentrancyGuard {
    /* ---------- roles ---------- */
    bytes32 public constant ADMIN_ROLE    = keccak256("ADMIN_ROLE");
    bytes32 public constant MINTER_ROLE   = keccak256("MINTER_ROLE");
    bytes32 public constant WITHDRAW_ROLE = keccak256("WITHDRAW_ROLE");

    /* ---------- tokens / market ---------- */
    IERC20Burnable public immutable ausd;   // A 链 AUSD（Burnable）
    IMintable      public immutable usdt;   // A 链 USDT（Mintable；作为 IERC20/IERC20Burnable 使用）
    IBondingCurvePrimaryMarket public primaryMarket;

    /* ---------- deposit ids ---------- */
    uint256 public nextDepositIdB2A_USDT; // 展示用
    uint256 public nextDepositIdA2B_USDT; // event2 (A->B: USDT)，用于审核也占用
    uint256 public nextDepositIdB2A_AUSD; // 展示用
    uint256 public nextDepositIdA2B_AUSD; // event4 (A->B: AUSD)，用于审核也占用

    /* ---------- replay guard ---------- */
    mapping(bytes32 => bool) public processed;

    /* ---------- fee config ---------- */
    // 代币费：fee = amount * rate / base（仅当 rate>0 且 base>0 时生效）
    uint256 public usdtFeeRate;
    uint256 public usdtFeeBase;
    uint256 public ausdFeeRate;
    uint256 public ausdFeeBase;

    // 原生币固定费用（wei），>0 必须等额 msg.value；=0 必须不带
    uint256 public feeWei;

    /* ---------- events（保留原名，追加字段） ---------- */
    event UsdtMintedFromBsc(uint256 indexed originChainId, uint256 indexed depositId, address indexed to, uint256 amount);

    // A->B：USDT，amountNet 为净额，feeToken 为 USDT 手续费，feeNative 为原生币手续费（wei）
    event Event2_UsdtDepositOnA(
        address indexed user,
        uint256 indexed depositId,
        address indexed toOnBsc,
        uint256 amountNet,
        uint256 feeToken,
        uint256 feeNative
    );

    event AusdReleasedFromBsc(uint256 indexed originChainId, uint256 indexed depositId, address indexed to, uint256 amount);

    // A->B：AUSD，amountNet 为净额，feeToken 为 AUSD 手续费，feeNative 为原生币手续费（wei）
    event Event4_AusdDepositOnA(
        address indexed user,
        uint256 indexed depositId,
        address indexed toOnBsc,
        uint256 amountNet,
        uint256 feeToken,
        uint256 feeNative
    );

    /* ---------- 审核：按「目标 depositId」存储 ---------- */
    struct Pending {
        bool    isUsdt;     // true: USDT; false: AUSD
        address user;       // 提交人
        address toOnBsc;    // 对端接收地址
        uint256 amount;     // 提交金额（总额）
        uint256 feeToken;   // 提交时计算并锁定的代币手续费
        uint256 feeNative;  // 提交时收取并锁定的原生币费用（wei）
        uint64  createdAt;  // 提交时间
        bool    exists;
    }
    // key = depositId（分别使用 nextDepositIdA2B_USDT / nextDepositIdA2B_AUSD 的分配值）
    mapping(uint256 => Pending) public pending;

    uint256 public usdtAuditThreshold; // >= 则进入审核，先扣到合约（总额），通过时 burn 净额；拒绝全额+原生币退款
    uint256 public ausdAuditThreshold; // >= 则进入审核，先扣到合约（总额），通过时发 event4；拒绝全额+原生币退款

    event PendingQueued(uint256 indexed id, address indexed user, bool indexed isUsdt, uint256 amount, address toOnBsc, uint256 feeToken, uint256 feeNative);
    event PendingApproved(uint256 indexed id, address indexed user, bool indexed isUsdt, uint256 amount, address toOnBsc);
    event PendingRejected(uint256 indexed id, address indexed user, bool indexed isUsdt, uint256 amount, address toOnBsc);

    /* 记录 USDT minter 更新 */
    event UsdtMinterUpdated(address indexed newMinter);

    constructor(address ausd_, address usdt_) {
        require(ausd_ != address(0) && usdt_ != address(0), "ZERO_ADDR");
        ausd = IERC20Burnable(ausd_);
        usdt = IMintable(usdt_);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        usdtAuditThreshold = 1000 * 1e18;
        ausdAuditThreshold = 1000 * 1e18;
    }

    /* ---------- admin ---------- */
    function setAuditThresholds(uint256 usdtThreshold, uint256 ausdThreshold)
        external onlyRole(ADMIN_ROLE)
    {
        usdtAuditThreshold = usdtThreshold;
        ausdAuditThreshold = ausdThreshold;
    }

     /* 默认超管可调用，转发到 USDT 合约的 setMinter */
    function setPrimaryMarket(address primary_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        primaryMarket = IBondingCurvePrimaryMarket(primary_);
    }
    function setUsdtFee(uint256 rate, uint256 base) external onlyRole(DEFAULT_ADMIN_ROLE) {
        usdtFeeRate = rate;
        usdtFeeBase = base;
    }
    function setAusdFee(uint256 rate, uint256 base) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ausdFeeRate = rate;
        ausdFeeBase = base;
    }
    function setFeeWei(uint256 feeWei_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        feeWei = feeWei_;
    }
    function adminSetUsdtMinter(address newMinter)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(newMinter != address(0), "ZERO_ADDR");
        IUsdtMinterAdmin(address(usdt)).setMinter(newMinter);
        emit UsdtMinterUpdated(newMinter);
    }

    /* ============================== FEE VIEW ============================== */
    function quoteUsdtFee(uint256 amount) public view returns (uint256 fee, uint256 net) {
        fee = (usdtFeeRate > 0 && usdtFeeBase > 0) ? (amount * usdtFeeRate) / usdtFeeBase : 0;
        net = amount - fee;
    }
    function quoteAusdFee(uint256 amount) public view returns (uint256 fee, uint256 net) {
        fee = (ausdFeeRate > 0 && ausdFeeBase > 0) ? (amount * ausdFeeRate) / ausdFeeBase : 0;
        net = amount - fee;
    }

    /* ============================== USDT (A -> BSC) ============================== */

    /// @notice [2.1] A -> BSC：未达阈值即时处理；达阈值进入审核（占用 depositId），通过时才实际扣费/销毁净额并发 event2
    function depositUsdtToBsc(uint256 amount, address toOnBsc)
        external
        payable
        nonReentrant
    {
        require(toOnBsc != address(0), "ZERO_to");
        require(amount > 0, "ZERO_amt");
        require(msg.value == feeWei, "BAD_NATIVE_FEE");

        (uint256 feeToken, uint256 net) = quoteUsdtFee(amount);
        require(net > 0, "FEE_GE_AMT");

        if (usdtAuditThreshold > 0 && amount >= usdtAuditThreshold) {
            // ---- 进入审核：转入总额，记录 fee 数值与原生币费用，分配 depositId ----
            require(IERC20(address(usdt)).transferFrom(msg.sender, address(this), amount), "USDT_TFR_FAIL");
            uint256 depId = ++nextDepositIdA2B_USDT;
            pending[depId] = Pending({
                isUsdt:    true,
                user:      msg.sender,
                toOnBsc:   toOnBsc,
                amount:    amount,
                feeToken:  feeToken,
                feeNative: feeWei,
                createdAt: uint64(block.timestamp),
                exists:    true
            });
            emit PendingQueued(depId, msg.sender, true, amount, toOnBsc, feeToken, feeWei);
            return;
        }

        // ---- 未达阈值：即时处理 ----
        // 总额先拉入合约；销毁净额，手续费留存
        require(IERC20(address(usdt)).transferFrom(msg.sender, address(this), amount), "USDT_TFR_FAIL");
        IERC20Burnable(address(usdt)).burn(net);

        uint256 depIdNow = ++nextDepositIdA2B_USDT;
        emit Event2_UsdtDepositOnA(msg.sender, depIdNow, toOnBsc, net, feeToken, feeWei);
    }

    /// @notice [1.2] BSC -> A：监听 BSC event1 后，在 A 链增发 USDT 给 to
    function mintUsdtFromBsc(
        uint256 originChainId,
        uint256 depositIdOnBsc,
        address toOnA,
        uint256 amount
    ) external onlyRole(MINTER_ROLE) nonReentrant {
        require(toOnA != address(0), "ZERO_to");
        require(amount > 0, "ZERO_amt");

        bytes32 key = keccak256(abi.encodePacked("BSC2A_USDT", originChainId, depositIdOnBsc));
        require(!processed[key], "ALREADY_DONE");
        processed[key] = true;

        usdt.mint(toOnA, amount);
        emit UsdtMintedFromBsc(originChainId, depositIdOnBsc, toOnA, amount);
    }

    /* ============================== AUSD (A -> BSC) ============================== */

    /// @notice [4.1] A -> BSC：未达阈值即时发 event4；达阈值进入审核（占用 depositId），通过时发 event4
    function depositAusdToBsc(uint256 amount, address toOnBsc)
        external
        payable
        nonReentrant
    {
        require(toOnBsc != address(0), "ZERO_to");
        require(amount > 0, "ZERO_amt");
        require(msg.value == feeWei, "BAD_NATIVE_FEE");

        (uint256 feeToken, uint256 net) = quoteAusdFee(amount);
        require(net > 0, "FEE_GE_AMT");

        if (ausdAuditThreshold > 0 && amount >= ausdAuditThreshold) {
            // ---- 进入审核：转入总额，记录 fee 数值与原生币费用，分配 depositId ----
            require(IERC20(address(ausd)).transferFrom(msg.sender, address(this), amount), "AUSD_TFR_FAIL");
            uint256 depId = ++nextDepositIdA2B_AUSD;
            pending[depId] = Pending({
                isUsdt:    false,
                user:      msg.sender,
                toOnBsc:   toOnBsc,
                amount:    amount,
                feeToken:  feeToken,
                feeNative: feeWei,
                createdAt: uint64(block.timestamp),
                exists:    true
            });
            emit PendingQueued(depId, msg.sender, false, amount, toOnBsc, feeToken, feeWei);
            return;
        }

        // ---- 未达阈值：即时处理 ----
        require(IERC20(address(ausd)).transferFrom(msg.sender, address(this), amount), "AUSD_TFR_FAIL");
        uint256 depIdNow = ++nextDepositIdA2B_AUSD;
        emit Event4_AusdDepositOnA(msg.sender, depIdNow, toOnBsc, net, feeToken, feeWei);
    }

    /// @notice [3.2] BSC -> A：监听 BSC event3 后，用本合约持有的 AUSD 支付给 to
    function releaseAusdFromBsc(
        uint256 originChainId,
        uint256 depositIdOnBsc,
        address toOnA,
        uint256 amount
    ) external onlyRole(MINTER_ROLE) nonReentrant {
        require(toOnA != address(0), "ZERO_to");
        require(amount > 0, "ZERO_amt");

        bytes32 key = keccak256(abi.encodePacked("BSC2A_AUSD", originChainId, depositIdOnBsc));
        require(!processed[key], "ALREADY_DONE");
        processed[key] = true;

        require(IERC20(address(ausd)).transfer(toOnA, amount), "AUSD_PAY_FAIL");
        emit AusdReleasedFromBsc(originChainId, depositIdOnBsc, toOnA, amount);
    }

    /* =================== 管理：曲线卖 AUSD 得 USDT（合约余额） =================== */

    function swapAusdForUsdtOnPrimary(uint256 ausdAmount, address to)
        external onlyRole(MINTER_ROLE) nonReentrant returns (uint256 usdtOut)
    {
        require(address(primaryMarket) != address(0), "NO_PRIMARY");
        require(to != address(0), "ZERO_to");
        require(ausdAmount > 0, "ZERO_amt");

        require(IERC20(address(ausd)).approve(address(primaryMarket), ausdAmount), "APP_FAIL");
        usdtOut = primaryMarket.sellForUsdt(ausdAmount, 0, to);
    }

    /* ============================== 审核操作（按 depositId） ============================== */

    /// @notice 审核通过：USDT→burn(净额) 并发 event2；AUSD→发 event4；手续费与原生币留在合约可提现
    function approvePending(uint256 depositId)
        external onlyRole(ADMIN_ROLE) nonReentrant
    {
        Pending memory p = pending[depositId];
        require(p.exists, "NO_PENDING");

        uint256 net = p.amount - p.feeToken;
        require(net > 0, "BAD_NET");

        if (p.isUsdt) {
            // 合约自持 USDT：销毁净额（手续费留存）
            IERC20Burnable(address(usdt)).burn(net);
            emit Event2_UsdtDepositOnA(p.user, depositId, p.toOnBsc, net, p.feeToken, p.feeNative);
        } else {
            // 合约已托管 AUSD：继续留在合约，事件给对端释放
            emit Event4_AusdDepositOnA(p.user, depositId, p.toOnBsc, net, p.feeToken, p.feeNative);
        }

        delete pending[depositId];
        emit PendingApproved(depositId, p.user, p.isUsdt, p.amount, p.toOnBsc);
    }

    /// @notice 审核拒绝：退回托管代币总额 + 原生币费用，删除单据
    function rejectPending(uint256 depositId)
        external onlyRole(ADMIN_ROLE) nonReentrant
    {
        Pending memory p = pending[depositId];
        require(p.exists, "NO_PENDING");

        if (p.isUsdt) {
            require(IERC20(address(usdt)).transfer(p.user, p.amount), "USDT_REFUND_FAIL");
        } else {
            require(IERC20(address(ausd)).transfer(p.user, p.amount), "AUSD_REFUND_FAIL");
        }

        if (p.feeNative > 0) {
            (bool ok, ) = payable(p.user).call{value: p.feeNative}("");
            require(ok, "NATIVE_REFUND_FAIL");
        }

        delete pending[depositId];
        emit PendingRejected(depositId, p.user, p.isUsdt, p.amount, p.toOnBsc);
    }

    /* ============================== 提现（WITHDRAW_ROLE） ============================== */

    function withdrawERC20(address token, address to, uint256 amount) external onlyRole(WITHDRAW_ROLE) nonReentrant {
        require(to != address(0), "ZERO_to");
        require(IERC20(token).transfer(to, amount), "ERC20_TFR_FAIL");
    }

    function withdrawNative(address payable to, uint256 amount) external onlyRole(WITHDRAW_ROLE) nonReentrant {
        require(to != address(0), "ZERO_to");
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "NATIVE_TFR_FAIL");
    }
}
