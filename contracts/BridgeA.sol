// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* -------------------- minimal interfaces -------------------- */
interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address f, address t, uint256 v) external returns (bool);
    function approve(address s, uint256 v) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IERC20Burnable is IERC20 {
    function burnFrom(address a, uint256 v) external;
}

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/* ------ BondingCurvePrimaryMarket (你之前的一级市场) ------ */
interface IBondingCurvePrimaryMarket {
    /// @notice 卖出 AUSD 换 USDT（函数名根据你给的“sellForUsdt”）
    /// @return usdtOut 实际得到的 USDT 数量
    function sellForUsdt(uint256 ausdAmount, uint256 minUsdtOut, address to) external returns (uint256 usdtOut);
}

/* ---------------------- ownable + reentrancy ---------------------- */
abstract contract Ownable {
    event OwnershipTransferred(address indexed prev, address indexed next);
    address public owner;
    constructor() { owner = msg.sender; emit OwnershipTransferred(address(0), msg.sender); }
    modifier onlyOwner() { require(msg.sender == owner, "NOT_OWNER"); _; }
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "ZERO_ADDR");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

abstract contract ReentrancyGuard {
    uint256 private locked = 1;
    modifier nonReentrant() {
        require(locked == 1, "REENTRANT");
        locked = 2;
        _;
        locked = 1;
    }
}

/**
 * @title BridgeA
 * @notice A 链桥接合约：对接 A 链 AUSD / USDT，含从曲线把 AUSD 卖成 USDT 的管理函数。
 *
 * 流程（对应你的编号）：
 * - [1.2] owner.mintUsdtFromBsc(...)       : 监听到 BSC event1 后，在 A 链增发 USDT 到目标
 * - [2.1] user.depositUsdtToBsc(...)       : 用户在 A 链存入（burnFrom）USDT，触发 event2
 * - [3.2] owner.releaseAusdFromBsc(...)    : 监听到 BSC event3 后，用合约余额 AUSD 在 A 链支付
 * - [4.1] user.depositAusdToBsc(...)       : 用户在 A 链存入（transferFrom 到合约）AUSD，触发 event4
 *
 * 额外：
 * - swapAusdForUsdtOnPrimary(...)          : 用合约 AUSD 走一级市场 sellForUsdt，把 USDT 打给 to
 */
contract BridgeA is Ownable, ReentrancyGuard {
    /* --------------------- external tokens / market --------------------- */
    IERC20Burnable public immutable ausd;   // A 链 AUSD（Burnable）
    IMintable      public immutable usdt;   // A 链 USDT（Mintable）
    IBondingCurvePrimaryMarket public primaryMarket; // 一级市场

    /* -------------------------- deposit ids -------------------------- */
    uint256 public nextDepositIdB2A_USDT; // 为了对齐 BSC->A 的 USDT 充值日志（只做展示无需自增使用）
    uint256 public nextDepositIdA2B_USDT; // A->B：USDT 的本地 depositId（event2 用）
    uint256 public nextDepositIdB2A_AUSD; // B->A：AUSD 的对端日志展示
    uint256 public nextDepositIdA2B_AUSD; // A->B：AUSD 的本地 depositId（event4 用）

    /* ----------------------- processed (replay-guard) ----------------------- */
    mapping(bytes32 => bool) public processed; 
    // key = keccak256(abi.encodePacked(flowTag, originChainId, depositId))

    /* ------------------------------ events ------------------------------ */
    // event1: BSC USDT -> A （在 BSC 合约里触发，这里仅定义 withdraw 事件）
    event UsdtMintedFromBsc(uint256 indexed originChainId, uint256 indexed depositId, address indexed to, uint256 amount);

    // event2: A USDT -> BSC （本合约触发）
    event Event2_UsdtDepositOnA(address indexed user, uint256 indexed depositId, address indexed toOnBsc, uint256 amount);

    // event3: BSC AUSD -> A （在 BSC 合约触发，这里仅定义 withdraw 事件）
    event AusdReleasedFromBsc(uint256 indexed originChainId, uint256 indexed depositId, address indexed to, uint256 amount);

    // event4: A AUSD -> BSC （本合约触发）
    event Event4_AusdDepositOnA(address indexed user, uint256 indexed depositId, address indexed toOnBsc, uint256 amount);

    /* ------------------------------ ctor ------------------------------ */
    constructor(address ausd_, address usdt_) {
        require(ausd_ != address(0) && usdt_ != address(0), "ZERO_ADDR");
        ausd = IERC20Burnable(ausd_);
        usdt = IMintable(usdt_);
        // if (primary_ != address(0)) {
        //     primaryMarket = IBondingCurvePrimaryMarket(primary_); // todo
        // }
    }

    /* --------------------------- owner config --------------------------- */
    function setPrimaryMarket(address primary_) external onlyOwner {
        primaryMarket = IBondingCurvePrimaryMarket(primary_);
    }

    /* ============================== USDT ============================== */

    /// @notice [2.1] A -> BSC：用户授权后，销毁其 A 链 USDT，触发 event2
    function depositUsdtToBsc(uint256 amount, address toOnBsc)
        external
        nonReentrant
    {
        require(toOnBsc != address(0), "ZERO_to");
        require(amount > 0, "ZERO_amt");
        // 需要用户预先 approve 给本合约
        ausd; // no-op keep compiler quiet for interface mix (not used here)
        IERC20Burnable(address(usdt)).burnFrom(msg.sender, amount);
        uint256 id = ++nextDepositIdA2B_USDT;
        emit Event2_UsdtDepositOnA(msg.sender, id, toOnBsc, amount);
    }

    /// @notice [1.2] BSC -> A：监听程序根据 BSC 的 event1 调用；在 A 链增发 USDT 给 to
    function mintUsdtFromBsc(
        uint256 originChainId,  // 56 for BSC（或你的私有链 ID）
        uint256 depositIdOnBsc, // BSC event1 的 depositId
        address toOnA,
        uint256 amount
    ) external onlyOwner nonReentrant {
        require(toOnA != address(0), "ZERO_to");
        require(amount > 0, "ZERO_amt");

        bytes32 key = keccak256(abi.encodePacked("BSC2A_USDT", originChainId, depositIdOnBsc));
        require(!processed[key], "ALREADY_DONE");
        processed[key] = true;

        usdt.mint(toOnA, amount);
        emit UsdtMintedFromBsc(originChainId, depositIdOnBsc, toOnA, amount);
    }

    /* ============================== AUSD ============================== */

    /// @notice [4.1] A -> BSC：用户授权后，把 A 链 AUSD 转入桥合约，触发 event4
    function depositAusdToBsc(uint256 amount, address toOnBsc)
        external
        nonReentrant
    {
        require(toOnBsc != address(0), "ZERO_to");
        require(amount > 0, "ZERO_amt");
        require(IERC20(address(ausd)).transferFrom(msg.sender, address(this), amount), "TFR_FAIL");
        uint256 id = ++nextDepositIdA2B_AUSD;
        emit Event4_AusdDepositOnA(msg.sender, id, toOnBsc, amount);
    }

    /// @notice [3.2] BSC -> A：监听程序根据 BSC 的 event3 调用；用本合约持有的 AUSD 支付给 to
    function releaseAusdFromBsc(
        uint256 originChainId,  // 56
        uint256 depositIdOnBsc, // BSC event3 的 depositId
        address toOnA,
        uint256 amount
    ) external onlyOwner nonReentrant {
        require(toOnA != address(0), "ZERO_to");
        require(amount > 0, "ZERO_amt");

        bytes32 key = keccak256(abi.encodePacked("BSC2A_AUSD", originChainId, depositIdOnBsc));
        require(!processed[key], "ALREADY_DONE");
        processed[key] = true;

        require(IERC20(address(ausd)).transfer(toOnA, amount), "TFR_FAIL");
        emit AusdReleasedFromBsc(originChainId, depositIdOnBsc, toOnA, amount);
    }

    /* =================== 管理：用曲线把 AUSD 卖成 USDT =================== */

    /// @notice 仅 owner：用“本合约余额”的 AUSD 走一级市场 sellForUsdt，把 USDT 直接打给 to
    function swapAusdForUsdtOnPrimary(uint256 ausdAmount, address to)
        external
        onlyOwner
        nonReentrant
        returns (uint256 usdtOut)
    {
        require(address(primaryMarket) != address(0), "NO_PRIMARY");
        require(to != address(0), "ZERO_to");
        require(ausdAmount > 0, "ZERO_amt");

        require(IERC20(address(ausd)).approve(address(primaryMarket), ausdAmount), "APP_FAIL");
        usdtOut = primaryMarket.sellForUsdt(ausdAmount, 0, to);
    }
}
