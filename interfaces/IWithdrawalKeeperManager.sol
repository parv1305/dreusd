// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IWithdrawalKeeperManager
 * @notice dreUSDManager views and `fillWithdrawal` used by `dreWithdrawalKeeperBot`
 */
interface IWithdrawalKeeperManager {
    function withdrawalNFT() external view returns (address);

    function withdrawalWaitingTime() external view returns (uint256);

    function dreUSD() external view returns (address);

    function usdc() external view returns (address);

    function withdrawalVaultAdapter() external view returns (address);

    function paused() external view returns (bool);

    function fillWithdrawal(uint256[] calldata tokenIds, bool useVault)
        external
        returns (uint256 filledCount, uint256 totalFilled);
}
