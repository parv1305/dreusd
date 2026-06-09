// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IdreUSDs
 * @dev Interface for dreUSDs vault
 */
interface IdreUSDs {
    // Errors
    error ZeroAddress();
    error ZeroExcess();
    error SameRewardsDistributor();
    error SameShareOFTAdapter();

    /**
     * @notice Returns the rewards distributor address (single source of truth for reward mint routing and vault accounting).
     */
    function rewardsDistributor() external view returns (address);

    // Events
    event RewardsDistributorUpdated(address indexed oldDistributor, address indexed newDistributor);
    event ShareOFTAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);
    event ExcessDreUSDWithdrawn(address indexed to, uint256 amount);

    /**
     * @notice Claims vested rewards from the rewards distributor and adds them to the vault virtual balance.
     * @dev Callable by anyone when not paused. Rewards are transferred from the distributor to this vault
     *      and reflected in totalAssets. Returns 0 if no distributor is set or nothing has vested.
     * @return claimed Amount of dreUSD claimed and added to virtual balance
     */
    function claimVestedRewards() external returns (uint256 claimed);

    /**
     * @notice Returns the amount of dreUSD held by the vault in excess of _virtualBalance (e.g. donations).
     * @dev Excess dreUSD is not reflected in totalAssets and cannot be redeemed with shares; this view helps identify recoverable amount.
     */
    function excessDreUSD() external view returns (uint256);

    /**
     * @notice Withdraws excess dreUSD from the vault to a recipient (e.g. donated tokens above _virtualBalance).
     * @dev Only DEFAULT_ADMIN_ROLE. Reverts if there is no excess. Does not affect share price (totalAssets uses _virtualBalance).
     * @param to Recipient of the excess dreUSD
     * @return amount Amount transferred
     */
    function withdrawExcessDreUSD(address to) external returns (uint256 amount);
}
