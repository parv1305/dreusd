// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAaveV3Pool} from "../interfaces/IAaveV3Pool.sol";

/**
 * @title AaveV3PoolMockWithConfigurableAToken
 * @dev Mock Aave V3 Pool that allows setting aTokenAddress for testing
 * @notice This mock is used specifically for testing aTokenAddress validation in dreAaveAdapter
 */
contract AaveV3PoolMockWithConfigurableAToken is IAaveV3Pool {
    address public aTokenAddress;
    address public usdc;
    
    constructor(address _usdc) {
        usdc = _usdc;
    }
    
    /**
     * @notice Set the aToken address returned by getReserveData
     * @param _aTokenAddress The aToken address to return
     */
    function setATokenAddress(address _aTokenAddress) external {
        aTokenAddress = _aTokenAddress;
    }
    
    /**
     * @notice Returns the state and configuration of the reserve
     * @param asset The address of the underlying asset of the reserve
     * @return The state and configuration data of the reserve
     */
    function getReserveData(address asset) external view returns (ReserveData memory) {
        require(asset == usdc, "Invalid asset");
        ReserveData memory data;
        data.aTokenAddress = aTokenAddress;
        return data;
    }
    
    /**
     * @notice Withdraw function - not implemented for this mock
     * @dev This mock is only used for testing initialization, not withdrawals
     */
    function withdraw(address, uint256, address) external pure returns (uint256) {
        revert("Not implemented");
    }
}
