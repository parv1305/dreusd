// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IAaveV3Adapter
 * @notice Interface for Aave V3 adapter that withdraws USDC from Aave
 * @dev The adapter pulls aTokens from a vault (multisig) and redeems them for USDC
 */
interface IAaveV3Adapter {
    // ============ Errors ============
    
    error ZeroAddress();
    error InvalidATokenAddress();
    error ZeroAmount();
    error InsufficientBalance(uint256 available, uint256 required);
    error WithdrawalFailed();
    error MaxSentinelNotSupported();
    error InsufficientAllowance(address vault, uint256 allowance);
    error InvalidCaller();

    // ============ Events ============

    /// @notice Emitted when funds are withdrawn from Aave
    event Withdrawn(address indexed to, uint256 amount);

    // ============ Functions ============

    /**
     * @notice Withdraw USDC from Aave by pulling aTokens from vault and redeeming
     * @param amount Amount of USDC to withdraw
     * @param to Address to receive the USDC
     * @return withdrawn Actual amount withdrawn
     * @dev MAX sentinel values (type(uint256).max) are not supported. The function requires
     *      an explicit amount and will revert with MaxSentinelNotSupported if amount is MAX.
     *      While Aave V3 Pool withdraw() supports MAX as a sentinel for "withdraw all",
     *      this adapter wrapper does not support this convention.
     */
    function withdraw(uint256 amount, address to) external returns (uint256 withdrawn);

    /**
     * @notice Get the available USDC that can be withdrawn
     * @dev Returns minimum of: vault's aToken balance, allowance to adapter, and Aave pool liquidity
     * @return Available balance in USDC
     */
    function getAvailableBalance() external view returns (uint256);

    /**
     * @notice Get the Aave Pool address
     * @return Address of the Aave V3 Pool
     */
    function getAavePool() external view returns (address);

    /**
     * @notice Get the aToken address for USDC
     * @return Address of the aUSDC token
     */
    function getAToken() external view returns (address);

    /**
     * @notice Get the USDC token address
     * @return Address of USDC
     */
    function getUsdc() external view returns (address);

    /**
     * @notice Get the vault address that holds aTokens
     * @return Address of the vault (multisig)
     */
    function getVault() external view returns (address);
}
