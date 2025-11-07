// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl}   from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/* -------------------- minimal interfaces -------------------- */
interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address f, address t, uint256 v) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

interface IERC20Burnable is IERC20 {
    function burnFrom(address a, uint256 v) external;
}

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/* AUSD 需具备的 Ownable 接口（用来把所有权转走） */
interface IOwnableLike {
    function transferOwnership(address newOwner) external;
}

/**
 * @title BridgeBsc
 * @notice BSC 桥接合约：对接 BSC-USDT（0x55d3...7955）与 BSC-AUSD（本桥需具备增发权限）。
 *
 * 流程（对应你的编号）：
 * - [1.1] user.depositUsdtToA(...)         : 用户把 BSC-USDT 转入桥合约，触发 event1
 * - [2.2] MINTER.releaseUsdtFromA(...)     : 监听 A 链 event2 后，从合约余额支付 USDT 给目标地址
 * - [3.1] user.depositAusdToA(...)         : 用户在 BSC 销毁 AUSD，触发 event3
 * - [4.2] MINTER.mintAusdFromA(...)        : 监听 A 链 event4 后，在 BSC 增发 AUSD 给目标地址
 *
 * 额外：
 * - 默认超管（DEFAULT_ADMIN_ROLE）可调用 adminTransferAusdOwnership，把 AUSD 合约所有权转移。
 */
contract BridgeBsc is AccessControl, ReentrancyGuard {
    /* --------------------- roles --------------------- */
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /* --------------------- external tokens --------------------- */
    IERC20 public immutable usdtBsc;                      // 0x55d398326f99059fF775485246999027B3197955
    IERC20Burnable public immutable ausdBscBurnable;      // 用于 burnFrom
    IMintable      public immutable ausdBscMintable;      // 用于 mint（本桥应持有增发权限/owner）

    /* -------------------------- deposit ids -------------------------- */
    uint256 public nextDepositIdB2A_USDT; // BSC->A：USDT（event1 本地自增）
    uint256 public nextDepositIdB2A_AUSD; // BSC->A：AUSD（event3 本地自增）

    /* ----------------------- processed (replay-guard) ----------------------- */
    mapping(bytes32 => bool) public processed; 
    // key = keccak256(abi.encodePacked(flowTag, originChainId, depositId))

    /* ------------------------------ events ------------------------------ */
    // event1: BSC USDT -> A（本合约触发）
    event Event1_UsdtDepositOnBsc(address indexed user, uint256 indexed depositId, address indexed toOnA, uint256 amount);

    // event3: BSC AUSD -> A（本合约触发）
    event Event3_AusdDepositOnBsc(address indexed user, uint256 indexed depositId, address indexed toOnA, uint256 amount);

    // 对应 A 链提现/增发完成的回执（可选）
    event UsdtReleasedFromA(uint256 indexed originChainId, uint256 indexed depositId, address indexed to, uint256 amount);
    event AusdMintedFromA(uint256 indexed originChainId, uint256 indexed depositId, address indexed to, uint256 amount);

    /* AUSD 所有权迁移（默认超管操作） */
    event AusdOwnershipTransferred(address indexed newOwner);

    /* ------------------------------ ctor ------------------------------ */
    constructor(address ausdBsc_, address usdtBsc_) {
        address _usdt = usdtBsc_ == address(0)
            ? 0x55d398326f99059fF775485246999027B3197955
            : usdtBsc_;
        require(ausdBsc_ != address(0), "ZERO_AUSD");

        usdtBsc        = IERC20(_usdt);
        ausdBscBurnable = IERC20Burnable(ausdBsc_);
        ausdBscMintable = IMintable(ausdBsc_);

        // 角色设置：部署者为默认超管
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /* ============================== USDT ============================== */

    /// @notice [1.1] BSC -> A：用户授权后把 USDT 转入桥合约，触发 event1
    function depositUsdtToA(uint256 amount, address toOnA)
        external
        nonReentrant
    {
        require(toOnA != address(0), "ZERO_to");
        require(amount > 0, "ZERO_amt");
        require(usdtBsc.transferFrom(msg.sender, address(this), amount), "TFR_FAIL");
        uint256 id = ++nextDepositIdB2A_USDT;
        emit Event1_UsdtDepositOnBsc(msg.sender, id, toOnA, amount);
    }

    /// @notice [2.2] A -> BSC：监听 A 链 event2 后，仅 MINTER_ROLE 可从本合约余额释放 USDT 给目标
    function releaseUsdtFromA(
        uint256 originChainId,  // A 链 chainId（你的私有链）
        uint256 depositIdOnA,   // A 链 event2 的 depositId
        address toOnBsc,
        uint256 amount
    ) external onlyRole(MINTER_ROLE) nonReentrant {
        require(toOnBsc != address(0), "ZERO_to");
        require(amount > 0, "ZERO_amt");

        bytes32 key = keccak256(abi.encodePacked("A2B_USDT", originChainId, depositIdOnA));
        require(!processed[key], "ALREADY_DONE");
        processed[key] = true;

        require(usdtBsc.transfer(toOnBsc, amount), "TFR_FAIL");
        emit UsdtReleasedFromA(originChainId, depositIdOnA, toOnBsc, amount);
    }

    /* ============================== AUSD ============================== */

    /// @notice [3.1] BSC -> A：用户授权后，销毁其 BSC-AUSD，触发 event3
    function depositAusdToA(uint256 amount, address toOnA)
        external
        nonReentrant
    {
        require(toOnA != address(0), "ZERO_to");
        require(amount > 0, "ZERO_amt");
        ausdBscBurnable.burnFrom(msg.sender, amount);
        uint256 id = ++nextDepositIdB2A_AUSD;
        emit Event3_AusdDepositOnBsc(msg.sender, id, toOnA, amount);
    }

    /// @notice [4.2] A -> BSC：监听 A 链 event4 后，仅 MINTER_ROLE 可在 BSC 增发 AUSD 给目标
    function mintAusdFromA(
        uint256 originChainId,  // A 链 chainId
        uint256 depositIdOnA,   // A 链 event4 的 depositId
        address toOnBsc,
        uint256 amount
    ) external onlyRole(MINTER_ROLE) nonReentrant {
        require(toOnBsc != address(0), "ZERO_to");
        require(amount > 0, "ZERO_amt");

        bytes32 key = keccak256(abi.encodePacked("A2B_AUSD", originChainId, depositIdOnA));
        require(!processed[key], "ALREADY_DONE");
        processed[key] = true;

        ausdBscMintable.mint(toOnBsc, amount);
        emit AusdMintedFromA(originChainId, depositIdOnA, toOnBsc, amount);
    }

    /* ============================== 管理（默认超管） ============================== */

    /// @notice 默认超管把 AUSD 合约的所有权转移给 newOwner（AUSD 需实现 Ownable 的 transferOwnership）
    function adminTransferAusdOwnership(address newOwner)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(newOwner != address(0), "ZERO_ADDR");
        IOwnableLike(address(ausdBscMintable)).transferOwnership(newOwner);
        emit AusdOwnershipTransferred(newOwner);
    }
}
