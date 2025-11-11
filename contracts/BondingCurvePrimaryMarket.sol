// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PRBMathUD60x18 } from "prb-math/contracts/PRBMathUD60x18.sol";
import { PRBMathSD59x18 } from "prb-math/contracts/PRBMathSD59x18.sol";

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address f, address t, uint256 v) external returns (bool);
    function approve(address s, uint256 v) external returns (bool);
    function allowance(address o, address s) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IMintableBurnableERC20 is IERC20 {
    function mint(address to, uint256 amount) external;
    function burnFrom(address from, uint256 amount) external;
}

/* 用于调用 AUSD 的 setMinter */
interface IAusdMinterAdmin {
    function setMinter(address newMinter) external;
}

/**
 * @title BondingCurvePrimaryMarket (AUSD-side fees + AccessControl + Public Skim)
 * @notice 内部台账：X = x1 - x2；R = s1 - s2
 *         y = sqrt(x/a)；S(x) = K*x*sqrt(x)，K=2/(3*sqrt(a))，C=(3*sqrt(a))/2
 *         60.18 定点（UD60x18 / SD59x18）
 *
 * 费收规则（AUSD侧）：
 *  - 买：ΔX 为总铸造量；fee = floor(ΔX * buyRate/buyBase)，铸给 feeRecipient；用户实收 ΔX - fee
 *  - 卖：用户交割 gross；fee = floor(gross * sellRate/sellBase)，从用户转给 feeRecipient；净量 burn 决定 USDT 出金
 *
 * 报价：理论值（不考虑任何 FOT；且你已确认 USDT/AUSD 均为无FOT标准实现）
 */
contract BondingCurvePrimaryMarket is AccessControl, ReentrancyGuard {
    using PRBMathUD60x18 for uint256;

    // -------------------- 60.18 常量 --------------------
    uint256 private constant ONE   = 1e18;
    uint256 private constant TWO   = 2e18;
    uint256 private constant THREE = 3e18;
    uint256 private constant TWO_THIRDS_CONST = 666_666_666_666_666_667; // 2/3 (60.18)

    // -------------------- Tokens --------------------
    IERC20 public immutable usdt;                 // 18 decimals（此处强制 18）
    IMintableBurnableERC20 public immutable ausd; // 18 decimals

    // -------------------- Curve params (60.18) --------------------
    uint256 public immutable A;          // > 0
    uint256 public immutable SQRT_A;
    uint256 public immutable K;          // 2 / (3 * sqrt(a))
    uint256 public immutable C;          // (3 * sqrt(a)) / 2
    uint256 public immutable TWO_THIRDS; // 2/3

    // -------------------- Fees （买卖分开 + 各自 base） --------------------
    uint256 public buyFeeRate  = 3;     // 默认 3/100
    uint256 public buyFeeBase  = 100;

    uint256 public sellFeeRate = 3;     // 默认 3/100
    uint256 public sellFeeBase = 100;

    address public feeRecipient;

    // -------------------- Internal ledger --------------------
    uint256 public s1; // 累计入金（USDT，面积）
    uint256 public s2; // 累计出金（USDT，面积）
    uint256 public x1; // 累计铸造 AUSD（含手续费部分）
    uint256 public x2; // 累计销毁 AUSD（只计净烧部分）

    // -------------------- Events --------------------
    event FeesUpdated(
        uint256 buyRate,
        uint256 buyBase,
        uint256 sellRate,
        uint256 sellBase,
        address feeRecipient
    );

    /* 记录 AUSD minter 更新 */
    event AusdMinterUpdated(address indexed newMinter);

    event Bought(
        address indexed buyer,
        address indexed to,
        uint256 usdtUsed,         // 推进曲线的入金
        uint256 ausdGrossOut,     // 总铸造
        uint256 ausdFee,          // 手续费（铸给 feeRecipient）
        uint256 ausdNetOut,       // 用户实收
        uint256 priceBefore,
        uint256 priceAfter
    );

    event Sold(
        address indexed seller,
        address indexed to,
        uint256 ausdGrossIn,      // 用户交割总量
        uint256 ausdFee,          // 手续费（从用户转给 feeRecipient）
        uint256 ausdBurn,         // 实际净烧
        uint256 usdtOut,          // 理论出金
        uint256 priceBefore,
        uint256 priceAfter
    );

    event Skimmed(address indexed to, uint256 amount);

    // -------------------- Constructor --------------------
    constructor(
        address usdt_,
        address ausd_,
        uint256 a,               // 60.18
        address admin,
        address feeRecipient_
    ) {
        require(usdt_ != address(0) && ausd_ != address(0), "ZERO_ADDR");
        require(a > 0, "A_ZERO");
        require(admin != address(0), "ADMIN_ZERO");
        require(feeRecipient_ != address(0), "FEE_ZERO");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        usdt = IERC20(usdt_);
        ausd = IMintableBurnableERC20(ausd_);
        A = a;

        // 均强制 18 位
        try usdt.decimals() returns (uint8 d0) { require(d0 == 18, "USDT_DEC"); } catch {}
        try ausd.decimals() returns (uint8 d1) { require(d1 == 18, "AUSD_DEC"); } catch {}

        SQRT_A     = A.sqrt();
        K          = TWO.div(THREE.mul(SQRT_A));
        C          = THREE.mul(SQRT_A).div(TWO);
        TWO_THIRDS = TWO_THIRDS_CONST;

        feeRecipient = feeRecipient_;
    }

    // -------------------- Admin ops --------------------
    function setFees(
        uint256 _buyRate,
        uint256 _buyBase,
        uint256 _sellRate,
        uint256 _sellBase,
        address _feeRecipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_buyBase > 0 && _sellBase > 0, "BASE_ZERO");
        require(_buyRate < _buyBase, "BUY_FEE_CFG");
        require(_sellRate < _sellBase, "SELL_FEE_CFG");
        require(_feeRecipient != address(0), "FEE_ZERO");

        buyFeeRate  = _buyRate;
        buyFeeBase  = _buyBase;
        sellFeeRate = _sellRate;
        sellFeeBase = _sellBase;
        feeRecipient = _feeRecipient;

        emit FeesUpdated(_buyRate, _buyBase, _sellRate, _sellBase, _feeRecipient);
    }

    /// 仅修改买入侧费率与基数
    function setBuyFees(uint256 _buyRate, uint256 _buyBase) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_buyBase > 0, "BASE_ZERO");
        require(_buyRate < _buyBase, "BUY_FEE_CFG");
        buyFeeRate = _buyRate;
        buyFeeBase = _buyBase;
        emit FeesUpdated(buyFeeRate, buyFeeBase, sellFeeRate, sellFeeBase, feeRecipient);
    }

    /// 仅修改卖出侧费率与基数
    function setSellFees(uint256 _sellRate, uint256 _sellBase) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_sellBase > 0, "BASE_ZERO");
        require(_sellRate < _sellBase, "SELL_FEE_CFG");
        sellFeeRate = _sellRate;
        sellFeeBase = _sellBase;
        emit FeesUpdated(buyFeeRate, buyFeeBase, sellFeeRate, sellFeeBase, feeRecipient);
    }

    /* 默认超管可调用，转发到 AUSD 合约的 setMinter */
    function adminSetUsdtMinter(address newMinter)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(newMinter != address(0), "ZERO_ADDR");
        IAusdMinterAdmin(address(ausd)).setMinter(newMinter);
        emit AusdMinterUpdated(newMinter);
    }

    // -------------------- Views --------------------
    function internalSupply() public view returns (uint256) {
        return x1 >= x2 ? x1 - x2 : 0;
    }

    function internalReserve() public view returns (uint256) {
        return s1 >= s2 ? s1 - s2 : 0;
    }

    function modeledReserve() public view returns (uint256) {
        return areaOf(internalSupply());
    }

    function realReserve() public view returns (uint256) {
        return usdt.balanceOf(address(this));
    }

    function currentPrice() public view returns (uint256) {
        return priceAtSupply(internalSupply());
    }

    // y(x) = sqrt(x/a)
    function priceAtSupply(uint256 x) public view returns (uint256) {
        if (x == 0) return 0;
        return x.div(A).sqrt();
    }

    // S(x) = K * x * sqrt(x)
    function areaOf(uint256 x) public view returns (uint256) {
        if (x == 0) return 0;
        uint256 sqrtX = x.sqrt();
        return K.mul(x.mul(sqrtX));
    }

    // S^{-1}(s) = (C*s)^(2/3)  （用 ln/exp 实现）
    function supplyFromArea(uint256 s) public view returns (uint256) {
        if (s == 0) return 0;
        uint256 vUD = C.mul(s);
        require(vUD <= uint256(type(int256).max), "V_TOO_LARGE");
        int256 lnV  = PRBMathSD59x18.ln(int256(vUD));
        int256 expo = PRBMathSD59x18.mul(lnV, int256(TWO_THIRDS));
        int256 res  = PRBMathSD59x18.exp(expo);
        require(res >= 0, "NEG_RESULT");
        return uint256(res);
    }

    // -------------------- Helpers --------------------
    function _mulDivUp(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        return (a == 0 || b == 0) ? 0 : (a * b + d - 1) / d;
    }

    // -------------------- Quotes（理论） --------------------

    function quoteBuyGivenUsdt(uint256 usdtIn)
        external view
        returns (uint256 ausdNetOut, uint256 ausdFee, uint256 ausdGrossOut)
    {
        uint256 X  = internalSupply();
        uint256 Xn = supplyFromArea(areaOf(X) + usdtIn);
        ausdGrossOut = Xn - X;
        ausdFee      = (ausdGrossOut * buyFeeRate) / buyFeeBase; // floor
        ausdNetOut   = ausdGrossOut - ausdFee;
    }

    function quoteBuyForExactAusdt(uint256 ausdNetWant)
        external view
        returns (uint256 usdtIn, uint256 ausdFee, uint256 ausdGross)
    {
        uint256 X  = internalSupply();
        uint256 denom = buyFeeBase - buyFeeRate;
        ausdGross = _mulDivUp(ausdNetWant, buyFeeBase, denom);
        usdtIn    = areaOf(X + ausdGross) - areaOf(X);
        ausdFee   = ausdGross - ausdNetWant;
    }

    function quoteSellGivenAusdt(uint256 ausdGrossIn)
        external view
        returns (uint256 usdtOut, uint256 ausdFee, uint256 ausdBurn)
    {
        uint256 X  = internalSupply();
        ausdFee    = (ausdGrossIn * sellFeeRate) / sellFeeBase; // floor
        ausdBurn   = ausdGrossIn - ausdFee;
        require(ausdBurn <= X, "SELL_EXCEEDS_INTERNAL_SUPPLY");
        usdtOut    = areaOf(X) - areaOf(X - ausdBurn);
    }

    function quoteSellForExactUsdt(uint256 usdtOut)
        external view
        returns (uint256 ausdGrossIn, uint256 ausdFee, uint256 ausdBurn)
    {
        uint256 X     = internalSupply();
        uint256 Sprev = areaOf(X);
        require(usdtOut <= Sprev, "EXCEEDS_INTERNAL_RESERVE");
        uint256 Xnew  = supplyFromArea(Sprev - usdtOut);
        ausdBurn      = X - Xnew;
        uint256 denom = sellFeeBase - sellFeeRate;
        ausdGrossIn   = _mulDivUp(ausdBurn, sellFeeBase, denom);
        ausdFee       = ausdGrossIn - ausdBurn;
    }

    // -------------------- Trades --------------------

    /// 买（简单）：按入参 usdtIn 推进；无FOT前提
    function buyWithUsdt(uint256 usdtIn, uint256 minAusdNetOut, address to)
        external nonReentrant returns (uint256 ausdNetOut)
    {
        require(usdtIn > 0, "ZERO_IN");
        require(feeRecipient != address(0), "FEE_ZERO");

        address _to = to == address(0) ? msg.sender : to;

        // 收款（标准ERC20，无FOT）
        require(usdt.transferFrom(msg.sender, address(this), usdtIn), "TF_FROM");

        uint256 X       = internalSupply();
        uint256 price0  = priceAtSupply(X);
        uint256 Xn      = supplyFromArea(areaOf(X) + usdtIn);
        uint256 dX      = Xn - X;

        uint256 feeA    = (dX * buyFeeRate) / buyFeeBase;
        ausdNetOut      = dX - feeA;
        require(ausdNetOut >= minAusdNetOut, "SLIPPAGE");

        // 台账
        s1 += usdtIn;
        x1 += dX;

        // 铸币：手续费 + 用户
        if (feeA > 0) ausd.mint(feeRecipient, feeA);
        ausd.mint(_to, ausdNetOut);

        emit Bought(msg.sender, _to, usdtIn, dX, feeA, ausdNetOut, price0, priceAtSupply(Xn));
    }

    /// 买（精确拿净 AUSD）：按理论 need 收款并推进，避免粉尘
    function buyExactAusdt(uint256 ausdNetOut, uint256 maxUsdtIn, address to)
        external nonReentrant returns (uint256 usdtUsed)
    {
        require(ausdNetOut > 0, "ZERO_OUT");
        require(feeRecipient != address(0), "FEE_ZERO");

        address _to = to == address(0) ? msg.sender : to;

        uint256 X      = internalSupply();
        uint256 price0 = priceAtSupply(X);
        uint256 denom  = buyFeeBase - buyFeeRate;
        uint256 dX     = _mulDivUp(ausdNetOut, buyFeeBase, denom);
        usdtUsed       = areaOf(X + dX) - areaOf(X);
        require(usdtUsed <= maxUsdtIn, "SLIPPAGE");

        // 只收 need，减少粉尘
        require(usdt.transferFrom(msg.sender, address(this), usdtUsed), "TF_FROM");

        // 台账与铸币
        s1 += usdtUsed;
        x1 += dX;

        uint256 feeA = dX - ausdNetOut;
        if (feeA > 0) ausd.mint(feeRecipient, feeA);
        ausd.mint(_to, ausdNetOut);

        emit Bought(msg.sender, _to, usdtUsed, dX, feeA, ausdNetOut, price0, priceAtSupply(X + dX));
    }

    /// 卖（简单）：输入总量，扣手续费给 feeRecipient，净量 burn，按净烧放 USDT
    function sellForUsdt(uint256 ausdGrossIn, uint256 minUsdtOut, address to)
        external nonReentrant returns (uint256 usdtOut)
    {
        require(ausdGrossIn > 0, "ZERO_IN");
        require(feeRecipient != address(0), "FEE_ZERO");

        address _to = to == address(0) ? msg.sender : to;

        uint256 X      = internalSupply();
        uint256 price0 = priceAtSupply(X);

        uint256 feeA   = (ausdGrossIn * sellFeeRate) / sellFeeBase;
        uint256 burnX  = ausdGrossIn - feeA;
        require(burnX <= X, "SELL_EXCEEDS_INTERNAL_SUPPLY");

        // 手续费从用户 -> feeRecipient（不烧毁）
        if (feeA > 0) {
            require(ausd.transferFrom(msg.sender, feeRecipient, feeA), "TF_FEE");
        }
        // 净量烧毁
        ausd.burnFrom(msg.sender, burnX);

        // 出金（理论）
        usdtOut = areaOf(X) - areaOf(X - burnX);
        require(usdtOut >= minUsdtOut, "SLIPPAGE");

        // 台账
        s2 += usdtOut;
        x2 += burnX;

        require(usdt.transfer(_to, usdtOut), "TF_OUT");

        emit Sold(msg.sender, _to, ausdGrossIn, feeA, burnX, usdtOut, price0, priceAtSupply(X - burnX));
    }

    /// 卖（精确 USDT）：先反推净烧，再上翻总交割；手续费转走，净量烧毁
    function sellExactUsdt(uint256 usdtOut, uint256 maxAusdGrossIn, address to)
        external nonReentrant returns (uint256 ausdGrossIn)
    {
        require(usdtOut > 0, "ZERO_OUT");
        require(feeRecipient != address(0), "FEE_ZERO");

        address _to = to == address(0) ? msg.sender : to;

        uint256 X      = internalSupply();
        uint256 Sprev  = areaOf(X);
        require(usdtOut <= Sprev, "EXCEEDS_INTERNAL_RESERVE");
        uint256 price0 = priceAtSupply(X);

        uint256 Xnew   = supplyFromArea(Sprev - usdtOut);
        uint256 burnX  = X - Xnew;

        uint256 denom  = sellFeeBase - sellFeeRate;
        ausdGrossIn    = _mulDivUp(burnX, sellFeeBase, denom);
        require(ausdGrossIn <= maxAusdGrossIn, "SLIPPAGE");
        uint256 feeA   = ausdGrossIn - burnX;

        if (feeA > 0) {
            require(ausd.transferFrom(msg.sender, feeRecipient, feeA), "TF_FEE");
        }
        ausd.burnFrom(msg.sender, burnX);

        s2 += usdtOut;
        x2 += burnX;

        require(usdt.transfer(_to, usdtOut), "TF_OUT");

        emit Sold(msg.sender, _to, ausdGrossIn, feeA, burnX, usdtOut, price0, priceAtSupply(Xnew));
    }

    // -------------------- Dust handling (public skim) --------------------

    /// 可提走“真实余额 - 模型储备”的正差额，并同步台账（视为一次真实出金）
    function skimExcess() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant returns (uint256 amount) {
        uint256 realR  = realReserve();
        uint256 modelR = modeledReserve();
        require(realR > modelR, "NO_EXCESS");
        amount = realR - modelR;

        s2 += amount; // 同步台账
        require(usdt.transfer(msg.sender, amount), "TF_SKIM");
        emit Skimmed(msg.sender, amount);
    }
}
