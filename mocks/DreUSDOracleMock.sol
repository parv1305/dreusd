// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IDreUSDOracle} from "../interfaces/IDreUSDOracle.sol";

/**
 * @title DreUSDOracleMock
 * @dev Mock oracle for testing dreUSDManager
 */
contract DreUSDOracleMock is IDreUSDOracle {
    mapping(address => uint8) public priceDecimals;
    mapping(address => uint256) public usdValueToReturn;
    mapping(address => uint256) public tokenAmountToReturn;
    
    constructor() {
        // Default price decimals (8 for Chainlink feeds)
        priceDecimals[address(0)] = 8;
    }
    
    function setPriceDecimals(address token, uint8 decimals) external {
        priceDecimals[token] = decimals;
    }
    
    function setUsdValue(address token, uint256 value) external {
        usdValueToReturn[token] = value;
    }
    
    function setTokenAmount(address token, uint256 amount) external {
        tokenAmountToReturn[token] = amount;
    }
    
    function getUsdValue(address token, uint256 amount) external view returns (uint256) {
        if (usdValueToReturn[token] > 0) {
            return usdValueToReturn[token];
        }
        // Default: 1:1 for same decimals
        return amount;
    }
    
    function getTokenAmount(address token, uint256 usdAmount) external view returns (uint256) {
        if (tokenAmountToReturn[token] > 0) {
            return tokenAmountToReturn[token];
        }
        // Default: 1:1 for same decimals
        return usdAmount;
    }
    
    function getPriceDecimals(address token) external view returns (uint8) {
        return priceDecimals[token] > 0 ? priceDecimals[token] : 8;
    }
    
    function validatePrice(address) external pure returns (bool) {
        return true;
    }
    
    function getLatestPrice(address) external view returns (int256, uint256) {
        return (1e8, block.timestamp);
    }
    
    function setOracle(address, address, uint256) external {}
    function setStalenessThreshold(address, uint256) external {}
    function setDeviationThreshold(address, uint256) external {}
    function removeOracle(address) external {}
    function setSequencerUptimeFeed(address) external {}
    function setGracePeriod(uint256) external {}
    function sequencerUptimeFeed() external pure returns (address) {
        return address(0);
    }
    function gracePeriod() external pure returns (uint256) {
        return 3600;
    }
}
