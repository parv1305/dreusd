// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAaveV3Adapter} from "../interfaces/IAaveV3Adapter.sol";

/**
 * @title AaveV3AdapterMock
 * @dev Mock Aave V3 adapter for testing
 */
contract AaveV3AdapterMock is IAaveV3Adapter {
    IERC20 public usdc;
    address public vault;
    uint256 public availableBalance;
    
    constructor(address _usdc, address _vault) {
        usdc = IERC20(_usdc);
        vault = _vault;
    }
    
    function setAvailableBalance(uint256 _balance) external {
        availableBalance = _balance;
    }
    
    function withdraw(uint256 amount, address to) external returns (uint256) {
        require(amount > 0, "ZeroAmount");
        require(availableBalance >= amount, "InsufficientBalance");
        
        availableBalance -= amount;
        IERC20(usdc).transfer(to, amount);
        
        emit Withdrawn(to, amount);
        return amount;
    }
    
    function getAvailableBalance() external view returns (uint256) {
        return availableBalance;
    }
    
    function getAavePool() external pure returns (address) {
        return address(0);
    }
    
    function getAToken() external pure returns (address) {
        return address(0);
    }
    
    function getUsdc() external view returns (address) {
        return address(usdc);
    }
    
    function getVault() external view returns (address) {
        return vault;
    }
}
