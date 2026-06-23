// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

contract SimpleOracle is IPriceOracle {

    // owner of the oracle,谁有权修改价格
    address public owner;

    // 映射：代币合约地址-> 价格，8位小数
    mapping(address => uint256) public prices;

    // 修饰器：只有owner可以修改价格
    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    // 构造函数：设置owner为msg.sender
    constructor() {
        owner = msg.sender;
    }
    
    // 设置价格，线上环境这个只能从oracle获取价格
    function setPrice(address asset, uint256 price) external onlyOwner {
        prices[asset] = price;
    }

    // 获取价格：通过资产获取价格
    function getPrice(address asset) external view returns (uint256) {
        uint256 price = prices[asset];
        if (price == 0) {
            revert PriceNotSet(asset);
        }
        return price;
    }
}