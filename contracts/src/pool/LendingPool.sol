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




    
}