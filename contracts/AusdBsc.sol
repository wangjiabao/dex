// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/* ---------------- UniswapV2 / PancakeV2 minimal interfaces ---------------- */
interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address);
    function createPair(address tokenA, address tokenB) external returns (address);
}

interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function WETH() external view returns (address);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title AusdToken (AUSD)
 * @notice BSC：仅对 Pancake USDT 交易对的买/卖收手续费；加/减流动性免收；手续费直接燃烧。
 * 权限分离：owner(增发/换人) 与 feeOwner(设置费率/换人)。
 *
 * 默认费率：3 / 100（3%）
 */
contract AusdToken is ERC20, ERC20Burnable, ERC20Permit {
    /* -------------------------------- errors -------------------------------- */
    error ZeroAddress();
    error NotOwner();
    error NotFeeOwner();
    error InvalidFee(); // base==0 或 rate>base
    error SameOwner();
    error SameFeeOwner();
    error TokenOrderRequire(); // 需要 address(this) > USDT，保证 pair 中 token0=USDT, token1=this
    error PairTokenMismatch(); // pair 的 token0/1 与期望不一致

    /* ------------------------------- ownership ------------------------------ */
    address public owner;      // 增发/换人
    address public feeOwner;   // 设置费率/换人

    event OwnershipTransferred(address indexed prev, address indexed next);
    event FeeOwnershipTransferred(address indexed prev, address indexed next);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }
    modifier onlyFeeOwner() {
        if (msg.sender != feeOwner) revert NotFeeOwner();
        _;
    }

    /* --------------------------------- fee cfg -------------------------------- */
    uint256 public feeRate; // 默认 3
    uint256 public feeBase; // 默认 100

    event FeeConfigUpdated(uint256 rate, uint256 base);
    event FeeBurned(address indexed from, address indexed to, uint256 feeAmount, uint256 rate, uint256 base);

    /* ------------------------ pancake router / pair / usdt ------------------------ */
    address public immutable pancakeRouter;
    address public immutable pancakeFactory;
    address public immutable usdt;
    address public immutable pair; // AUSD/USDT 交易对（token0=USDT, token1=AUSD）

    /* ---------------------------------- ctor ---------------------------------- */
    /**
     * @param name_          代币名
     * @param symbol_        符号
     * @param initialOwner   初始 owner
     * @param initialFeeOwner 初始 feeOwner
     */
    constructor(
        string memory name_,
        string memory symbol_,
        address initialOwner,
        address initialFeeOwner
    )
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        if (
            initialOwner == address(0) ||
            initialFeeOwner == address(0)
        ) revert ZeroAddress();

        usdt = 0x6D8E995C00F512CC4De6AC0C3D7Cc9F3D86C2A4c; // todo
        pancakeRouter = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

        // 需要 AUSD 地址 > USDT 地址，确保 pair 排序为 token0=USDT, token1=AUSD
        if (address(this) <= usdt) revert TokenOrderRequire();

        owner = initialOwner;
        feeOwner = initialFeeOwner;
        emit OwnershipTransferred(address(0), initialOwner);
        emit FeeOwnershipTransferred(address(0), initialFeeOwner);

        pancakeFactory = IUniswapV2Router02(pancakeRouter).factory();

        // 获取或创建 USDT/AUSD pair
        address p = IUniswapV2Factory(pancakeFactory).getPair(usdt, address(this));
        if (p == address(0)) {
            p = IUniswapV2Factory(pancakeFactory).createPair(usdt, address(this));
        }

        // 校验 pair 顺序
        address t0 = IUniswapV2Pair(p).token0();
        address t1 = IUniswapV2Pair(p).token1();
        if (!(t0 == usdt && t1 == address(this))) revert PairTokenMismatch();

        pair = p;

        // 默认费率 3%
        feeRate = 3;
        feeBase = 100;
        emit FeeConfigUpdated(feeRate, feeBase);
    }

    function decimals() public pure override returns (uint8) { return 18; }

    /* -------------------------------- owner ops -------------------------------- */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        if (newOwner == owner) revert SameOwner();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function transferFeeOwnership(address newFeeOwner) external {
        if (msg.sender != owner && msg.sender != feeOwner) revert NotFeeOwner();
        if (newFeeOwner == address(0)) revert ZeroAddress();
        if (newFeeOwner == feeOwner) revert SameFeeOwner();
        emit FeeOwnershipTransferred(feeOwner, newFeeOwner);
        feeOwner = newFeeOwner;
    }

    /// @notice owner 增发
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /* ------------------------------ feeOwner ops ------------------------------ */
    function setFeeConfig(uint256 rate_, uint256 base_) external onlyFeeOwner {
        if (base_ == 0 || rate_ > base_) revert InvalidFee();
        feeRate = rate_;
        feeBase = base_;
        emit FeeConfigUpdated(feeRate, feeBase);
    }

    /* ---------------------- liquidity add/remove detection ---------------------- */
    /// @dev 利用「当前余额 vs 上次同步的储备」来判断是否加/减池。
    /// 由于我们强制 token0=USDT、token1=AUSD，这里按固定顺序读取。
    function _checkAddOrRemove()
        private
        view
        returns (bool isAdd, bool isRemove)
    {
        (uint112 r0, uint112 r1, ) = IUniswapV2Pair(pair).getReserves();
        // 当前余额（未 sync 前，路由已把 token 打入 pair）
        uint256 bal0 = IERC20Minimal(usdt).balanceOf(pair);
        uint256 bal1 = IERC20Minimal(address(this)).balanceOf(pair);

        // 经典判定：
        // 加池：一个余额增加，另一个不变
        // 减池：一个余额减少，另一个不变或同时减少（外取）
        // 注意：这只是“启发式”但在 V2 路由顺序下非常稳定可用
        isAdd =
            (bal0 > r0 && bal1 == r1) ||
            (bal0 == r0 && bal1 > r1);

        isRemove =
            (bal0 < r0 && bal1 <= r1) ||
            (bal0 <= r0 && bal1 < r1);
    }

    /* --------------------------- FOT with fine detection --------------------------- */
    /**
     * @dev 仅对「与 pair 的买/卖」收税：
     * - 卖出：to==pair，且不是加流动性
     * - 买入：from==pair，且不是移除流动性
     * 其它（普通转账、加池、减池、铸造、销毁）不收税。
     */
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && feeRate != 0 && value != 0) {
            bool involvesPair = (from == pair) || (to == pair);
            if (involvesPair) {
                (bool isAdd, bool isRemove) = _checkAddOrRemove();

                bool isSell = (to == pair) && (!isAdd);       // 用户 -> pair 但不是加池
                bool isBuy  = (from == pair) && (!isRemove);  // pair -> 用户 但不是减池

                if (isSell || isBuy) {
                    uint256 fee = (value * feeRate) / feeBase;
                    if (fee > 0) {
                        uint256 net = value - fee;

                        // 手续费直接燃烧
                        _burn(from, fee);
                        emit FeeBurned(from, to, fee, feeRate, feeBase);

                        super._update(from, to, net);
                        return;
                    }
                }
            }
        }
        super._update(from, to, value);
    }
}
