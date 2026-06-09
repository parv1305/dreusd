// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAaveV3Pool} from "../interfaces/IAaveV3Pool.sol";
import {MockERC20} from "./MockERC20.sol";

/**
 * @title AaveV3PoolMock
 * @dev Mock Aave V3 Pool for testing
 * @notice This mock simulates Aave V3 Pool behavior for testing purposes
 */
contract AaveV3PoolMock is IAaveV3Pool {
    IERC20 public usdc;
    MockERC20 public aUsdc;
    uint256 public withdrawAmount; // Amount to return on withdraw (0 means return requested amount)
    
    constructor(address _usdc, address _aUsdc) {
        usdc = IERC20(_usdc);
        aUsdc = MockERC20(_aUsdc);
    }
    
    /**
     * @notice Set the amount to return on withdraw (for testing withdrawal failures)
     * @param _amount Amount to return (0 means return requested amount)
     */
    function setWithdrawAmount(uint256 _amount) external {
        withdrawAmount = _amount;
    }
    
    /**
     * @notice Withdraws an amount of underlying asset from the reserve, burning the equivalent aTokens owned
     * @param asset The address of the underlying asset to withdraw
     * @param amount The underlying amount to be withdrawn
     * @param to The address that will receive the underlying
     * @return The final amount withdrawn
     */
    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(asset == address(usdc), "Invalid asset");
        
        // If withdrawAmount is set, use it; otherwise return the requested amount
        uint256 amountToWithdraw = withdrawAmount > 0 ? withdrawAmount : amount;
        
        // Check if we have enough liquidity
        // In real Aave, the aToken holds USDC, but for testing we can check pool's balance
        // or the aToken's balance. We'll check both for flexibility.
        uint256 poolBalance = usdc.balanceOf(address(this));
        uint256 aTokenBalance = usdc.balanceOf(address(aUsdc));
        require(poolBalance >= amountToWithdraw || aTokenBalance >= amountToWithdraw, "Insufficient liquidity");
        
        // Burn aTokens from the caller (adapter)
        aUsdc.burn(msg.sender, amount);
        
        // Transfer USDC to recipient
        // Prefer transferring from pool's own balance, otherwise from aToken
        if (poolBalance >= amountToWithdraw) {
            require(MockERC20(address(usdc)).transfer(to, amountToWithdraw), "USDC transfer failed");
        } else {
            // Transfer from aToken (requires allowance, but for testing we'll handle it)
            require(MockERC20(address(usdc)).transferFrom(address(aUsdc), to, amountToWithdraw), "USDC transfer failed");
        }
        
        return amountToWithdraw;
    }
    
    /**
     * @notice Returns the state and configuration of the reserve
     * @param asset The address of the underlying asset of the reserve
     * @return The state and configuration data of the reserve
     */
    function getReserveData(address asset) external view returns (ReserveData memory) {
        require(asset == address(usdc), "Invalid asset");
        
        ReserveData memory data;
        data.aTokenAddress = address(aUsdc);
        return data;
    }
}
