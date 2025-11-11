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
 * @title BridgeBsc (with fee fields merged)
 */
contract BridgeBsc is AccessControl, ReentrancyGuard {
    /* --------------------- roles --------------------- */
    bytes32 public constant MINTER_ROLE   = keccak256("MINTER_ROLE");
    bytes32 public constant WITHDRAW_ROLE = keccak256("WITHDRAW_ROLE");

    /* --------------------- external tokens --------------------- */
    IERC20 public immutable usdtBsc;
    IERC20Burnable public immutable ausdBscBurnable;
    IMintable      public immutable ausdBscMintable;

    /* -------------------------- deposit ids -------------------------- */
    uint256 public nextDepositIdB2A_USDT;
    uint256 public nextDepositIdB2A_AUSD;

    /* ----------------------- processed ----------------------- */
    mapping(bytes32 => bool) public processed;

    /* ------------------------------ fee config ------------------------------ */
    uint256 public usdtFeeRate;
    uint256 public usdtFeeBase;
    uint256 public ausdFeeRate;
    uint256 public ausdFeeBase;
    uint256 public nativeFeeWei;

    /* ------------------------------ events ------------------------------ */
    // 追加字段 feeToken, feeNative
    event Event1_UsdtDepositOnBsc(
        address indexed user,
        uint256 indexed depositId,
        address indexed toOnA,
        uint256 amountNet,
        uint256 feeToken,
        uint256 feeNative
    );

    event Event3_AusdDepositOnBsc(
        address indexed user,
        uint256 indexed depositId,
        address indexed toOnA,
        uint256 amountNet,
        uint256 feeToken,
        uint256 feeNative
    );

    event UsdtReleasedFromA(uint256 indexed originChainId, uint256 indexed depositId, address indexed to, uint256 amount);
    event AusdMintedFromA  (uint256 indexed originChainId, uint256 indexed depositId, address indexed to, uint256 amount);
    event AusdOwnershipTransferred(address indexed newOwner);
    event UsdtFeeUpdated(uint256 rate, uint256 base);
    event AusdFeeUpdated(uint256 rate, uint256 base);
    event NativeFeeUpdated(uint256 nativeFeeWei);

    /* ------------------------------ ctor ------------------------------ */
    constructor(address ausdBsc_, address usdtBsc_) {
        address _usdt = usdtBsc_ == address(0)
            ? 0x55d398326f99059fF775485246999027B3197955
            : usdtBsc_;
        require(ausdBsc_ != address(0), "ZERO_AUSD");

        usdtBsc         = IERC20(_usdt);
        ausdBscBurnable = IERC20Burnable(ausdBsc_);
        ausdBscMintable = IMintable(ausdBsc_);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
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

    /* ============================== USDT (BSC->A) ============================== */

    function depositUsdtToA(uint256 amount, address toOnA)
        external
        payable
        nonReentrant
    {
        require(toOnA != address(0), "ZERO_to");
        require(amount > 0, "ZERO_amt");
        require(msg.value == nativeFeeWei, "BAD_NATIVE_FEE");

        (uint256 fee, uint256 net) = quoteUsdtFee(amount);
        require(net > 0, "FEE_GE_AMT");

        require(usdtBsc.transferFrom(msg.sender, address(this), amount), "USDT_TFR_FAIL");

        uint256 id = ++nextDepositIdB2A_USDT;
        emit Event1_UsdtDepositOnBsc(msg.sender, id, toOnA, net, fee, nativeFeeWei);
    }

    function releaseUsdtFromA(
        uint256 originChainId,
        uint256 depositIdOnA,
        address toOnBsc,
        uint256 amount
    ) external onlyRole(MINTER_ROLE) nonReentrant {
        require(toOnBsc != address(0), "ZERO_to");
        require(amount > 0, "ZERO_amt");

        bytes32 key = keccak256(abi.encodePacked("A2B_USDT", originChainId, depositIdOnA));
        require(!processed[key], "ALREADY_DONE");
        processed[key] = true;

        require(usdtBsc.transfer(toOnBsc, amount), "USDT_TFR_FAIL");
        emit UsdtReleasedFromA(originChainId, depositIdOnA, toOnBsc, amount);
    }

    /* ============================== AUSD (BSC->A) ============================== */

    function depositAusdToA(uint256 amount, address toOnA)
        external
        payable
        nonReentrant
    {
        require(toOnA != address(0), "ZERO_to");
        require(amount > 0, "ZERO_amt");
        require(msg.value == nativeFeeWei, "BAD_NATIVE_FEE");

        (uint256 fee, uint256 net) = quoteAusdFee(amount);
        require(net > 0, "FEE_GE_AMT");

        if (fee > 0) {
            require(ausdBscBurnable.transferFrom(msg.sender, address(this), fee), "AUSD_FEE_TFR_FAIL");
        }

        ausdBscBurnable.burnFrom(msg.sender, net);

        uint256 id = ++nextDepositIdB2A_AUSD;
        emit Event3_AusdDepositOnBsc(msg.sender, id, toOnA, net, fee, nativeFeeWei);
    }

    function mintAusdFromA(
        uint256 originChainId,
        uint256 depositIdOnA,
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

    /* ============================== 管理 ============================== */

    function adminTransferAusdOwnership(address newOwner)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(newOwner != address(0), "ZERO_ADDR");
        IOwnableLike(address(ausdBscMintable)).transferOwnership(newOwner);
        emit AusdOwnershipTransferred(newOwner);
    }

    function setUsdtFee(uint256 rate, uint256 base) external onlyRole(DEFAULT_ADMIN_ROLE) {
        usdtFeeRate = rate;
        usdtFeeBase = base;
        emit UsdtFeeUpdated(rate, base);
    }

    function setAusdFee(uint256 rate, uint256 base) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ausdFeeRate = rate;
        ausdFeeBase = base;
        emit AusdFeeUpdated(rate, base);
    }

    function setNativeFeeWei(uint256 feeWei) external onlyRole(DEFAULT_ADMIN_ROLE) {
        nativeFeeWei = feeWei;
        emit NativeFeeUpdated(feeWei);
    }

    /* ============================== 提现 ============================== */

    function withdrawERC20(address token, address to, uint256 amount) external onlyRole(WITHDRAW_ROLE) nonReentrant {
        require(to != address(0), "ZERO_to");
        require(IERC20(token).transfer(to, amount), "ERC20_TFR_FAIL");
    }

    function withdrawNative(address payable to, uint256 amount) external onlyRole(WITHDRAW_ROLE) nonReentrant {
        require(to != address(0), "ZERO_to");
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "NATIVE_TFR_FAIL");
    }

    receive() external payable {}
}
