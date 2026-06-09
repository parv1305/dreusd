// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IdreRewardsDistributor
 * @dev Interface for dreRewardsDistributor - Yield Streaming Engine
 */
interface IdreRewardsDistributor {
    // Errors
    error ZeroAddress();
    /// @notice Thrown when claimVested() is called by an address other than the vault
    error CallerNotVault();

    // Events
    event RewardsClaimed(uint256 amount);
    /// @notice Emitted when addRewards() updates the reward schedule (new rewards added and/or vest window reset)
    event RewardsScheduleUpdated(uint256 newRewards, uint256 totalRewards, uint256 cTs, uint256 eTs);

    // View functions
    function dreUSD() external view returns (address);
    function vault() external view returns (address);
    function VEST_PERIOD() external view returns (uint256);
    function cTs() external view returns (uint256);
    function eTs() external view returns (uint256);
    function rewards() external view returns (uint256);
    function vestedAmount() external view returns (uint256);

    // State-changing functions
    function claimVested() external returns (uint256);
    function addRewards() external;

    // Roles
    function MODERATOR_ROLE() external view returns (bytes32);
}
