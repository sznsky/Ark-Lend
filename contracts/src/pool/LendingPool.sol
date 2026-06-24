// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;


// 精度说明:
// WETH amount:  18 decimals
// USDC amount:  6 decimals
// Oracle price: 8 decimals (USD)
// HF:           1e18 = 健康线 1.0




import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

// 借贷池，ReentrancyGuard
contract LendingPool is ReentrancyGuard {
    

    using SafeERC20 for IERC20;

    // --- 风险参数 (basis points, 10000 = 100%)
    // 70% 最大借款
    uint256 public constant LTV_BPS = 7000;  
    // 80% 清算线               
    uint256 public constant LIQUIDATION_THRESHOLD_BPS = 8000;  
    // 5% 清算奖励
    uint256 public constant LIQUIDATION_BONUS_BPS = 500;       
    // 100%，BPS=Basis Points，基点，10000=100%
    uint256 public constant BPS = 10_000;
    // 1e18，健康因子精度,1e18是1后面18位小数
    uint256 public constant HF_PRECISION = 1e18;

    // 代币合约地址
    IERC20 public immutable usdc;
    // WETH合约地址
    IERC20 public immutable weth;
    // 价格预言机,用来读取weth,usdc的价格，immutable=部署时候配置一次，之后不再改变，节省gas
    IPriceOracle public immutable oracle;

    // 存款总额
    uint256 public totalShares;
    // 用户存款份额
    mapping (address => uint256) public shares;

    // 借款仓位
    struct Position {
        // 抵押品(ETH)
        uint256 collateral;
        // 债务(USDC)
        uint256 debt;
    }
    // 用户借款仓位
    mapping (address => Position) public positions;
    // 借款总额
    uint256 public totalDebt;

    // 事件
    event Supply(address indexed user, uint256 amount, uint256 sharesMinted);
    event Withdraw(address indexed user, uint256 amount, uint256 sharesBurned);
    event DepositCollateral(address indexed user, uint256 amount);
    event WithdrawCollateral(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount);
    event Repay(address indexed user, uint256 amount);
    event Liquidate(
        address indexed liquidator,
        address indexed borrower,
        uint256 debtRepaid,
        uint256 collateralSeized
    );

    // 构造函数
    constructor(address _usdc, address _weth, address _oracle) {
        usdc = IERC20(_usdc);
        weth = IERC20(_weth);
        oracle = IPriceOracle(_oracle);
    }

    // 池子总资产=池内udsc现金+全部应收的债务,也就是：池内 USDC 现金 + 全部应收债务 = 存款人应得的总 USDC 资产
    function totalAssets() public view returns (uint256) {
        return usdc.balanceOf(address(this)) + totalDebt;
    }

    // 健康因子HF=抵押品的价值*清算阈值 / 债务价值。用来判断借款人的仓位是否还安全，以及能不能被清算。
    // HF>=1e18(也就是1)表示仓位安全，不能被清算。HF<1e18(1)表示仓位不安全，可以被清算。
    function getHealthFactor(address user) public view returns (uint256) {
        // 读取用户仓位,抵押了多少weth,欠了多少usdc
        Position memory position = positions[user];
        // 如果用户没有欠债，则健康因子为最大值
        if (pos.debt == 0) return type(uint256).max;

        // 计算抵押品的价值
        uint256 collateralValue = pos.collateral * oracle.getPrice(address(weth)) / 1e18;
        // 计算债务的价值
        uint256 debtValue = pos.debt * oracle.getPrice(address(usdc)) / 1e6;
        // 计算健康因子
        return (collateralValue * LIQUIDATION_THRESHOLD_BPS * HF_PRECISION) / (debtValue * BPS);
    }

    // phase1: 存款和取款
    function supply(uint256 amount) external nonReentrant {
        // 存款金额大于0
        require(amount > 0, "Amount must be greater than 0");
        // 存款前池子总资产
        uint256 assetsBefore = totalAssets();
        // 从用户账户转出USDC到池子
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        // 计算用户存款份额,首次存款时，份额与存款金额相等，之后按比例分配
        uint256 sharesToMint = totalShares == 0? amount: (amount * totalShares) / assetsBefore; 
        // 更新用户存款份额
        shares[msg.sender] += sharesToMint;
        // 更新池子总份额
        totalShares += sharesToMint;
        emit Supply(msg.sender, amount, sharesToMint);
    }

    // 取款
    function withdraw(uint256 amount) external nonReentrant {
        // 取款金额大于0
        require(amount > 0, "zero amount");
        // 用户存款份额
        uint256 userShares = shares[msg.sender];
        // 用户存款份额大于0
        require(userShares > 0, "no shares");
        // 池子总资产
        uint256 assets = totalAssets();
        // 计算用户需要销毁的份额
        uint256 sharesToBurn = (amount * totalShares) / assets;
        // 用户需要销毁的份额大于0且小于等于用户存款份额
        require(sharesToBurn > 0 && sharesToBurn <= userShares, "insufficient shares");
        // 池子内USDC现金
        uint256 cash = usdc.balanceOf(address(this));
        // 取款金额小于等于池子内USDC现金
        require(amount <= cash, "insufficient liquidity");
        // 更新用户存款份额
        shares[msg.sender] -= sharesToBurn;
        // 更新池子总份额
        totalShares -= sharesToBurn;
        // 从池子转出USDC到用户账户
        usdc.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount, sharesToBurn);
    }

    // phase2: 抵押和借款
    function depositCollateral(uint256 amount) external nonReentrant {
        // 抵押金额大于0
        require(amount > 0, "zero amount");
        // 从用户账户转出WETH到池子,this是部署以后得当前合约
        weth.safeTransferFrom(msg.sender, address(this), amount);
        // 更新用户抵押品数量
        positions[msg.sender].collateral += amount;
        emit DepositCollateral(msg.sender, amount);
    }

    // 借款
    function borrow(uint256 amount) external nonReentrant {
        require(amount > 0, "zero amount");
        Position storage pos = positions[msg.sender];
        uint256 newDebt = pos.debt + amount;
        require(newDebt <= _maxBorrow(msg.sender), "exceeds LTV");
        require(usdc.balanceOf(address(this)) >= amount, "insufficient liquidity");
        pos.debt = newDebt;
        totalDebt += amount;
        usdc.safeTransfer(msg.sender, amount);
        emit Borrow(msg.sender, amount);
    }

    // phase3: 还款+提现抵押品
    function repay(uint256 amount) external nonReentrant {
        require(amount > 0, "zero amount");
        Position storage pos = positions[msg.sender];
        require(pos.debt > 0, "no debt");
        uint256 repayAmount = amount > pos.debt ? pos.debt : amount;
        usdc.safeTransferFrom(msg.sender, address(this), repayAmount);
        pos.debt -= repayAmount;
        totalDebt -= repayAmount;
        emit Repay(msg.sender, repayAmount);
    }

    function withdrawCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, "zero amount");
        Position storage pos = positions[msg.sender];
        require(pos.collateral >= amount, "insufficient collateral");
        pos.collateral -= amount;
        _requireHealthy(msg.sender);
        weth.safeTransfer(msg.sender, amount);
        emit WithdrawCollateral(msg.sender, amount);
    }

    //phase4: 清算
    function liquidate(address borrower, uint256 debtToCover) external nonReentrant {
        require(debtToCover > 0, "zero amount");
        require(getHealthFactor(borrower) < HF_PRECISION, "healthy position");

        Position storage pos = positions[borrower];
        require(pos.debt > 0, "no debt");

        uint256 actualDebt = debtToCover > pos.debt ? pos.debt : debtToCover;

        usdc.safeTransferFrom(msg.sender, address(this), actualDebt);

        uint256 collateralToSeize = _collateralToSeize(actualDebt);
        if (collateralToSeize > pos.collateral) {
            collateralToSeize = pos.collateral;
        }

        pos.debt -= actualDebt;
        pos.collateral -= collateralToSeize;
        totalDebt -= actualDebt;

        weth.safeTransfer(msg.sender, collateralToSeize);

        emit Liquidate(msg.sender, borrower, actualDebt, collateralToSeize);
    }














    // 下面是辅助函数，相当于内部方法，给其他函数调用使用的
    // 计算抵押品的价值,也就是抵押品值多少usdc
    function _collateralValue(uint256 collateral) internal view returns (uint256) {
         // 8 decimals，获取weth的价格
        uint256 price = oracle.getPrice(address(weth));
        // 这里为什么要除以1e18呢？因为weth的价格是以18位小数表示的，所以需要除以1e18转换为18位小数    
        return (collateral * price) / 1e18;
    }

    // 计算债务的价值,也就是债务值多少usdc
    function _debtValue(uint256 debt) internal view returns (uint256) {
        uint256 price = oracle.getPrice(address(usdc)); // 6 decimals
        // 下面为什么要除以 1e6?
        // debt 是usdc的数量，比如1usdc=1,000,000;链上没有小数，只能这样存储1,000，000=1e6。
        // price 是价格，8位数存储。比如价格是1400usdc=1.0234e8;链上没有小数，只能这样存储123,400,000。
        // 现在计算债务的价值，debt * price = 1e6 * 1.0234e8 = 1.0234e8e14。所以要除以1e6,结果就是1.0234e8。
        return (debt * price) / 1e6;
    }
    
    // 计算用户最大可借金额
    function _maxBorrow(address user) internal view returns (uint256) {
        uint256 collateralValue = _collateralValue(positions[user].collateral);
        // collateralValue(8 dec) -> USDC amount(6 dec)
        return (collateralValue * LTV_BPS * 1e6) / (BPS * 1e8);
    }

    // 检查用户仓位是否健康
    function _requireHealthy(address user) internal view {
        require(getHealthFactor(user) >= HF_PRECISION, "unhealthy");
    }

    // 计算用户需要被清算的抵押品数量
    function _collateralToSeize(uint256 debtToCover) internal view returns (uint256) {
        uint256 ethPrice = oracle.getPrice(address(weth));
        uint256 seizedValue = (_debtValue(debtToCover) * (BPS + LIQUIDATION_BONUS_BPS)) / BPS;
        return (seizedValue * 1e18) / ethPrice;
    }

















    
}