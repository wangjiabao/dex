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
 * @title BridgeA
 * @notice A 链桥接合约：AUSD / USDT + 审核阈值（超额先扣款托管到合约；通过时按原逻辑走；拒绝退回）。
 */
contract BridgeA is AccessControl, ReentrancyGuard {
    /* ---------- roles ---------- */
    bytes32 public constant ADMIN_ROLE  = keccak256("ADMIN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /* ---------- tokens / market ---------- */
    IERC20Burnable public immutable ausd;   // A 链 AUSD（Burnable）
    IMintable      public immutable usdt;   // A 链 USDT（Mintable，但这里也当作 ERC20Burnable 使用）
    IBondingCurvePrimaryMarket public primaryMarket;

    /* ---------- deposit ids ---------- */
    uint256 public nextDepositIdB2A_USDT; // 展示用
    uint256 public nextDepositIdA2B_USDT; // event2
    uint256 public nextDepositIdB2A_AUSD; // 展示用
    uint256 public nextDepositIdA2B_AUSD; // event4

    /* ---------- replay guard ---------- */
    mapping(bytes32 => bool) public processed;

    /* ---------- events（保持原名） ---------- */
    event UsdtMintedFromBsc(uint256 indexed originChainId, uint256 indexed depositId, address indexed to, uint256 amount);
    event Event2_UsdtDepositOnA(address indexed user, uint256 indexed depositId, address indexed toOnBsc, uint256 amount);
    event AusdReleasedFromBsc(uint256 indexed originChainId, uint256 indexed depositId, address indexed to, uint256 amount);
    event Event4_AusdDepositOnA(address indexed user, uint256 indexed depositId, address indexed toOnBsc, uint256 amount);

    /* ---------- 审核：按 id 存储 ---------- */
    struct Pending {
        bool    isUsdt;     // true: USDT; false: AUSD
        address user;       // 提交人
        address toOnBsc;    // 对端接收地址
        uint256 amount;     // 金额
        uint64  createdAt;  // 提交时间
        bool    exists;
    }

    mapping(uint256 => Pending) public pending;
    uint256 public nextPendingId;

    uint256 public usdtAuditThreshold; // >= 则进入审核，且先扣到合约
    uint256 public ausdAuditThreshold; // >= 则进入审核，且先扣到合约

    event PendingQueued(uint256 indexed id, address indexed user, bool indexed isUsdt, uint256 amount, address toOnBsc);
    event PendingApproved(uint256 indexed id, address indexed user, bool indexed isUsdt, uint256 amount, address toOnBsc);
    event PendingRejected(uint256 indexed id, address indexed user, bool indexed isUsdt, uint256 amount, address toOnBsc);

    /* 记录 USDT minter 更新 */
    event UsdtMinterUpdated(address indexed newMinter);

    constructor(address ausd_, address usdt_) {
        require(ausd_ != address(0) && usdt_ != address(0), "ZERO_ADDR");
        ausd = IERC20Burnable(ausd_);
        usdt = IMintable(usdt_);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        usdtAuditThreshold = 1000*1e18;
        ausdAuditThreshold = 1000*1e18;
    }

    /* ---------- admin ---------- */
    function setPrimaryMarket(address primary_) external onlyRole(ADMIN_ROLE) {
        primaryMarket = IBondingCurvePrimaryMarket(primary_);
    }

    function setAuditThresholds(uint256 usdtThreshold, uint256 ausdThreshold)
        external onlyRole(ADMIN_ROLE)
    {
        usdtAuditThreshold = usdtThreshold;
        ausdAuditThreshold = ausdThreshold;
    }

    /* 默认超管可调用，转发到 USDT 合约的 setMinter */
    function adminSetUsdtMinter(address newMinter)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(newMinter != address(0), "ZERO_ADDR");
        IUsdtMinterAdmin(address(usdt)).setMinter(newMinter);
        emit UsdtMinterUpdated(newMinter);
    }

    /* ============================== USDT ============================== */

    /// @notice [2.1] A -> BSC：未达阈值直接 burnFrom；达到阈值则先从用户 transferFrom 到合约托管，生成审核单
    function depositUsdtToBsc(uint256 amount, address toOnBsc)
        external nonReentrant
    {
        require(toOnBsc != address(0), "ZERO_to");
        require(amount > 0, "ZERO_amt");

        if (usdtAuditThreshold > 0 && amount >= usdtAuditThreshold) {
            // 先扣到合约里（需要用户提前 approve）
            require(IERC20(address(usdt)).transferFrom(msg.sender, address(this), amount), "USDT_TFR_FAIL");
            uint256 id = ++nextPendingId;
            pending[id] = Pending({
                isUsdt:    true,
                user:      msg.sender,
                toOnBsc:   toOnBsc,
                amount:    amount,
                createdAt: uint64(block.timestamp),
                exists:    true
            });
            emit PendingQueued(id, msg.sender, true, amount, toOnBsc);
            return;
        }

        // 原逻辑：直接从用户销毁
        IERC20Burnable(address(usdt)).burnFrom(msg.sender, amount);
        uint256 depId = ++nextDepositIdA2B_USDT;
        emit Event2_UsdtDepositOnA(msg.sender, depId, toOnBsc, amount);
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

    /* ============================== AUSD ============================== */

    /// @notice [4.1] A -> BSC：未达阈值照旧转入合约并发 event4；达到阈值则同样先从用户扣到合约，生成审核单
    function depositAusdToBsc(uint256 amount, address toOnBsc)
        external nonReentrant
    {
        require(toOnBsc != address(0), "ZERO_to");
        require(amount > 0, "ZERO_amt");

        if (ausdAuditThreshold > 0 && amount >= ausdAuditThreshold) {
            // 先扣到合约里（需要用户提前 approve）
            require(IERC20(address(ausd)).transferFrom(msg.sender, address(this), amount), "AUSD_TFR_FAIL");
            uint256 id = ++nextPendingId;
            pending[id] = Pending({
                isUsdt:    false,
                user:      msg.sender,
                toOnBsc:   toOnBsc,
                amount:    amount,
                createdAt: uint64(block.timestamp),
                exists:    true
            });
            emit PendingQueued(id, msg.sender, false, amount, toOnBsc);
            return;
        }

        // 原逻辑：转入合约并发 event4
        require(IERC20(address(ausd)).transferFrom(msg.sender, address(this), amount), "AUSD_TFR_FAIL");
        uint256 depId = ++nextDepositIdA2B_AUSD;
        emit Event4_AusdDepositOnA(msg.sender, depId, toOnBsc, amount);
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

    /* ============================== 审核操作 ============================== */

    /// @notice 审核通过：USDT→合约自燃并发 event2；AUSD→直接发 event4（资金已在合约）
    function approvePending(uint256 id)
        external onlyRole(ADMIN_ROLE) nonReentrant
    {
        Pending memory p = pending[id];
        require(p.exists, "NO_PENDING");

        if (p.isUsdt) {
            // 合约自持 USDT：自燃烧后发 event2
            IERC20Burnable(address(usdt)).burn(p.amount);
            uint256 depId = ++nextDepositIdA2B_USDT;
            emit Event2_UsdtDepositOnA(p.user, depId, p.toOnBsc, p.amount);
        } else {
            // 合约已托管 AUSD：直接发 event4（继续留在合约里供对端释放）
            uint256 depId2 = ++nextDepositIdA2B_AUSD;
            emit Event4_AusdDepositOnA(p.user, depId2, p.toOnBsc, p.amount);
        }

        delete pending[id];
        emit PendingApproved(id, p.user, p.isUsdt, p.amount, p.toOnBsc);
    }

    /// @notice 审核拒绝：把托管资金原路退回用户，然后删除
    function rejectPending(uint256 id)
        external onlyRole(ADMIN_ROLE) nonReentrant
    {
        Pending memory p = pending[id];
        require(p.exists, "NO_PENDING");

        if (p.isUsdt) {
            require(IERC20(address(usdt)).transfer(p.user, p.amount), "USDT_REFUND_FAIL");
        } else {
            require(IERC20(address(ausd)).transfer(p.user, p.amount), "AUSD_REFUND_FAIL");
        }

        delete pending[id];
        emit PendingRejected(id, p.user, p.isUsdt, p.amount, p.toOnBsc);
    }
}
