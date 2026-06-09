// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IDreUSDOracle
 * @dev Interface for dreUSD price oracle contract
 */
interface IDreUSDOracle {
    // ============ Errors ============

    error ZeroAddress();
    error OracleNotSet(address token);
    error StaleOracleData(address token, uint256 updatedAt, uint256 staleness);
    error InvalidPrice(address token, int256 price);
    error InvalidStalenessThreshold();
    error StalenessThresholdOutOfBounds(uint256 value, uint256 min, uint256 max);
    error PriceDeviationExceeded(address token, int256 price, int256 expectedPrice, uint256 deviationBps);
    error InvalidDeviationThreshold();
    error SequencerDown();
    error InvalidOracleInterface(address oracleAddress);
    error InvalidOracleDecimals(address oracleAddress, uint8 decimals);
    error InvalidOraclePrice(address oracleAddress, int256 price);
    error SameOracle();
    error SameStalenessThreshold();
    error SameDeviationThreshold();
    error SameSequencerUptimeFeed();
    error SameGracePeriod();
    error GracePeriodOutOfBounds(uint256 value, uint256 min, uint256 max);

    // ============ Events ============

    event OracleSet(address indexed token, address indexed oracle, uint256 stalenessThreshold);
    event OracleRemoved(address indexed token);
    event StalenessThresholdUpdated(address indexed token, uint256 oldThreshold, uint256 newThreshold);
    event DeviationThresholdUpdated(address indexed token, uint256 oldThreshold, uint256 newThreshold);
    event SequencerUptimeFeedSet(address indexed oldFeed, address indexed newFeed);
    event GracePeriodUpdated(uint256 oldGracePeriod, uint256 newGracePeriod);

    // ============ Admin Functions ============

    /**
     * @notice Sets the Chainlink oracle for a token with staleness threshold
     * @param token The stablecoin address
     * @param oracleAddress The Chainlink AggregatorV3Interface address
     * @param stalenessThreshold Maximum age of oracle data in seconds for this feed
     */
    function setOracle(address token, address oracleAddress, uint256 stalenessThreshold) external;

    /**
     * @notice Updates the staleness threshold for a token's oracle
     * @param token The stablecoin address
     * @param stalenessThreshold New staleness threshold in seconds
     */
    function setStalenessThreshold(address token, uint256 stalenessThreshold) external;

    /**
     * @notice Updates the deviation threshold for a token's oracle
     * @param token The stablecoin address
     * @param deviationBps New deviation threshold in basis points (e.g., 200 = 2%, 500 = 5%)
     */
    function setDeviationThreshold(address token, uint256 deviationBps) external;

    /**
     * @notice Removes the oracle for a token
     * @param token The stablecoin address
     */
    function removeOracle(address token) external;

    /**
     * @notice Sets the sequencer uptime feed address (for L2 chains)
     * @param sequencerUptimeFeed The Chainlink sequencer uptime feed address (AggregatorV2V3Interface)
     */
    function setSequencerUptimeFeed(address sequencerUptimeFeed) external;

    /**
     * @notice Sets the grace period after sequencer recovery (in seconds)
     * @param gracePeriod The grace period in seconds (e.g., 3600 = 1 hour)
     */
    function setGracePeriod(uint256 gracePeriod) external;

    // ============ View Functions ============

    /**
     * @notice Gets the USD value of a token amount, validating the oracle
     * @param token The stablecoin address
     * @param amount The amount of tokens (in token decimals)
     * @return usdValue The USD value (in oracle decimals from Chainlink feed)
     */
    function getUsdValue(address token, uint256 amount) external view returns (uint256 usdValue);

    /**
     * @notice Gets the token amount for a given USD value, validating the oracle
     *         Used for withdrawals: converts USD (dreUSD) to stablecoin amount
     * @param token The stablecoin address (e.g., USDC)
     * @param usdAmount The USD amount (in dreUSD decimals, which is 1:1 with USD)
     * @return tokenAmount The token amount to receive (in token decimals)
     */
    function getTokenAmount(address token, uint256 usdAmount) external view returns (uint256 tokenAmount);

    /**
     * @notice Validates the price feed for a token
     * @param token The stablecoin address
     * @return valid True if price is valid (not stale, positive price)
     */
    function validatePrice(address token) external view returns (bool valid);

    /**
     * @notice Gets the latest price for a token
     * @param token The stablecoin address
     * @return price The price in USD (in feed's decimals)
     * @return updatedAt Timestamp of last update
     */
    function getLatestPrice(address token) external view returns (int256 price, uint256 updatedAt);

    /**
     * @notice Gets the decimals for a token's price feed
     * @param token The stablecoin address
     * @return The number of decimals in the price feed
     */
    function getPriceDecimals(address token) external view returns (uint8);

    /**
     * @notice Gets the sequencer uptime feed address
     * @return The sequencer uptime feed address (address(0) if not set)
     */
    function sequencerUptimeFeed() external view returns (address);

    /**
     * @notice Gets the grace period after sequencer recovery
     * @return The grace period in seconds
     */
    function gracePeriod() external view returns (uint256);
}
