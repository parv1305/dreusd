// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IdreVault
 * @notice USDC holding vault that forwards its balance to a downstream address via Chainlink Automation
 */
interface IdreVault {
    error ZeroAddress();
    error NothingToForward();
    error ConfiguredTokenNotRecoverable();

    event UsdcForwarded(address indexed to, uint256 amount);
    event TokenRecovered(address indexed token, address indexed recipient, uint256 amount);
    event EtherRecovered(address indexed recipient, uint256 amount);

    /// @notice ERC20 token held and forwarded (e.g. USDC)
    function token() external view returns (address);

    /// @notice Downstream recipient: another dreVault or corporate wallet
    function forwardVault() external view returns (address);

    /// @notice Chainlink Automation: returns true when this contract holds a non-zero token balance
    function checkUpkeep(bytes calldata checkData) external view returns (bool upkeepNeeded, bytes memory performData);

    /// @notice Chainlink Automation: forwards the full token balance to `forwardVault`
    function performUpkeep(bytes calldata performData) external;

    /// @notice Owner-only: recover any ERC20 except the configured `token` (that token is only forwarded via `performUpkeep`)
    function recoverToken(address token, address recipient) external;

    /// @notice Owner-only: recover ETH sent to this contract by mistake
    function recoverEther(address recipient) external;
}
