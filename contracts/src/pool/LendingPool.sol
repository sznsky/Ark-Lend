// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

// 借贷池
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
    // 1e18，健康因子精度
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

    // 池子总资产=池内udsc现金+全部应收的债务
    function totalAssets() public view returns (uint256) {
        return usdc.balanceOf(address(this)) + weth.balanceOf(address(this));
    }

    // 健康因子HF=抵押品的价值*清算阈值 / 债务价值。
    function getHealthFactor(address user) public view returns (uint256) {
        Position memory position = positions[user];
        uint256 collateralValue = position.collateral * oracle.getPrice(address(weth)) / HF_PRECISION;
        uint256 debtValue = position.debt * oracle.getPrice(address(usdc)) / HF_PRECISION;
        return collateralValue * LIQUIDATION_THRESHOLD_BPS / debtValue;
    }

    // phase1: 存款和取款
    function supply(uint256 amount) public nonReentrant {
        // 存款金额大于0
        require(amount > 0, "Amount must be greater than 0");
        // 存款前池子总资产
        uint256 assetsBefore = totalAssets();
        // 从用户账户转出USDC到池子
        usdc.transferFrom(msg.sender, address(this), amount);
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















    
}