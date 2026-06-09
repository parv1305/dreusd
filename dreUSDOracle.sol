// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AggregatorV3Interface} from "@chainlink/contracts/v0.8/interfaces/AggregatorV3Interface.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IDreUSDOracle} from "./interfaces/IDreUSDOracle.sol";
import {ScalingConstants} from "./libraries/ScalingConstants.sol";

/**
 * @title dreUSDOracle
 * @dev Oracle contract for dreUSD that validates stablecoin prices via Chainlink
 *      Ensures stablecoins are within acceptable deviation from USD peg before minting
 *      Reverts if oracle is stale or price deviates beyond configured threshold
 */
contract dreUSDOracle is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    IDreUSDOracle
{
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant MODERATOR_ROLE = keccak256("MODERATOR_ROLE");

    /// @notice Minimum allowed staleness threshold (1 minute). Prevents misconfig that would always revert.
    uint256 public constant MIN_STALENESS_THRESHOLD = 60;
    
    /// @notice Maximum allowed staleness threshold (24 hours). Aligns with Chainlink heartbeat for Base stablecoins (e.g. USDC/USDT/USDE/USDS/GHO).
    uint256 public constant MAX_STALENESS_THRESHOLD = 86400;

    /// @notice Minimum grace period after sequencer recovery (1 minute)
    uint256 public constant MIN_GRACE_PERIOD = 60;
    /// @notice Maximum grace period after sequencer recovery (24 hours, Chainlink recommendation ~1 hour)
    uint256 public constant MAX_GRACE_PERIOD = 86400;

    /// @notice Mapping of token address to Chainlink price feed
    mapping(address => address) public oracles;

    /// @notice Mapping of token address to staleness threshold in seconds
    mapping(address => uint256) public stalenessThresholds;

    /// @notice Mapping of token address to deviation threshold in basis points (e.g., 200 = 2%, 500 = 5%)
    mapping(address => uint256) public deviationThresholds;

    /// @notice Sequencer uptime feed address (for L2 chains like Base)
    /// @dev Set to address(0) to disable sequencer checks (e.g., on L1)
    address public sequencerUptimeFeed;

    /// @notice Grace period after sequencer recovery before accepting price feeds (in seconds)
    /// @dev Default: 3600 seconds (1 hour) as recommended by Chainlink
    uint256 public gracePeriod;

    /// @dev Reserved storage slots for future upgrades
    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the oracle contract
     * @param defaultAdmin Address to grant the default admin role
     * @param _sequencerUptimeFeed Address of the sequencer uptime feed
     */
    function initialize(
        address defaultAdmin,
        address upgrader,
        address moderator,
        address _sequencerUptimeFeed
    ) public initializer {
        if (defaultAdmin == address(0)) revert ZeroAddress();
        if (upgrader == address(0)) revert ZeroAddress();
        if (moderator == address(0)) revert ZeroAddress();
        if (_sequencerUptimeFeed == address(0)) revert ZeroAddress();

        __AccessControl_init_unchained();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(UPGRADER_ROLE, upgrader);
        _grantRole(MODERATOR_ROLE, moderator);

        // Set default grace period to 1 hour (3600 seconds) as recommended by Chainlink
        gracePeriod = 3600;
        sequencerUptimeFeed = _sequencerUptimeFeed;
    }

    /// @inheritdoc IDreUSDOracle
    function setOracle(
        address token,
        address oracleAddress,
        uint256 stalenessThreshold
    ) external onlyRole(MODERATOR_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (oracleAddress == address(0)) revert ZeroAddress();
        if (oracles[token] == oracleAddress) revert SameOracle();

        _requireValidStalenessThreshold(stalenessThreshold);

        // Defensive checks: validate that oracleAddress implements AggregatorV3Interface
        // and returns reasonable values to prevent misconfiguration
        AggregatorV3Interface oracle = AggregatorV3Interface(oracleAddress);
        
        // Check 1: Verify oracle implements decimals() function
        uint8 priceDecimals;
        try oracle.decimals() returns (uint8 decimals) {
            priceDecimals = decimals;
        } catch {
            revert InvalidOracleInterface(oracleAddress);
        }
        
        // Check 2: Validate decimals are within reasonable range (0-18)
        // Chainlink feeds typically use 8 decimals, but some may use 18
        if (priceDecimals > 18) {
            revert InvalidOracleDecimals(oracleAddress, priceDecimals);
        }
        
        // Check 3: Verify oracle implements latestRoundData() and returns valid price
        // This helps catch wrong feed pairs (e.g., ETH/USD feed for USDC)
        int256 price;
        try oracle.latestRoundData() returns (
            uint80 /* roundId */,
            int256 answer,
            uint256 /* startedAt */,
            uint256 /* updatedAt */,
            uint80 /* answeredInRound */
        ) {
            price = answer;
        } catch {
            revert InvalidOracleInterface(oracleAddress);
        }
        
        // Check 4: Validate price is reasonable for a stablecoin (between $0.50 and $2.00)
        // This helps catch misconfigurations like setting ETH/USD feed for USDC
        int256 expectedPrice = int256(ScalingConstants.scaleBase(priceDecimals)); // $1.00 in feed decimals
        int256 lowerBound = expectedPrice / 2; // $0.50
        int256 upperBound = expectedPrice * 2; // $2.00
        
        if (price <= 0 || price < lowerBound || price > upperBound) {
            revert InvalidOraclePrice(oracleAddress, price);
        }

        oracles[token] = oracleAddress;
        stalenessThresholds[token] = stalenessThreshold;
        
        // Set default deviation threshold of 1% (100 bps) if not already set
        if (deviationThresholds[token] == 0) {
            deviationThresholds[token] = 100; // 1% default
        }
        
        emit OracleSet(token, oracleAddress, stalenessThreshold);
    }

    /// @inheritdoc IDreUSDOracle
    function setStalenessThreshold(address token, uint256 stalenessThreshold) external onlyRole(MODERATOR_ROLE) {
        if (oracles[token] == address(0)) revert OracleNotSet(token);
        if (stalenessThresholds[token] == stalenessThreshold) revert SameStalenessThreshold();
        _requireValidStalenessThreshold(stalenessThreshold);

        uint256 oldThreshold = stalenessThresholds[token];
        stalenessThresholds[token] = stalenessThreshold;
        emit StalenessThresholdUpdated(token, oldThreshold, stalenessThreshold);
    }

    /// @inheritdoc IDreUSDOracle
    function setDeviationThreshold(address token, uint256 deviationBps) external onlyRole(MODERATOR_ROLE) {
        if (oracles[token] == address(0)) revert OracleNotSet(token);
        if (deviationThresholds[token] == deviationBps) revert SameDeviationThreshold();
        if (deviationBps > ScalingConstants.BPS_DENOMINATOR) revert InvalidDeviationThreshold(); // Max 100%

        uint256 oldThreshold = deviationThresholds[token];
        deviationThresholds[token] = deviationBps;
        emit DeviationThresholdUpdated(token, oldThreshold, deviationBps);
    }

    /// @inheritdoc IDreUSDOracle
    function removeOracle(address token) external onlyRole(MODERATOR_ROLE) {
        if (oracles[token] == address(0)) revert OracleNotSet(token);

        delete oracles[token];
        delete stalenessThresholds[token];
        delete deviationThresholds[token];
        emit OracleRemoved(token);
    }

    /// @inheritdoc IDreUSDOracle
    function setSequencerUptimeFeed(address _sequencerUptimeFeed) external onlyRole(MODERATOR_ROLE) {
        if (_sequencerUptimeFeed == address(0)) revert ZeroAddress();
        if (_sequencerUptimeFeed == sequencerUptimeFeed) revert SameSequencerUptimeFeed();
        address oldFeed = sequencerUptimeFeed;
        sequencerUptimeFeed = _sequencerUptimeFeed;
        emit SequencerUptimeFeedSet(oldFeed, _sequencerUptimeFeed);
    }

    /// @inheritdoc IDreUSDOracle
    function setGracePeriod(uint256 _gracePeriod) external onlyRole(MODERATOR_ROLE) {
        if (_gracePeriod == gracePeriod) revert SameGracePeriod();
        if (_gracePeriod < MIN_GRACE_PERIOD || _gracePeriod > MAX_GRACE_PERIOD) {
            revert GracePeriodOutOfBounds(_gracePeriod, MIN_GRACE_PERIOD, MAX_GRACE_PERIOD);
        }
        uint256 oldGracePeriod = gracePeriod;
        gracePeriod = _gracePeriod;
        emit GracePeriodUpdated(oldGracePeriod, _gracePeriod);
    }

    /// @inheritdoc IDreUSDOracle
    /// @param token The ERC20 token whose USD value is being queried.
    /// @param amount The token amount in token-native decimals.
    /// @return usdValue USD value of `amount`, scaled by the Chainlink price feed decimals.
    /// @dev Division truncates toward zero. Tokens with 8 or more decimals (e.g. WBTC) can have small amounts
    ///      truncate to zero: e.g. 1 unit of an 8-decimal token with 8-decimal price yields 0 USD value.
    function getUsdValue(address token, uint256 amount) external view returns (uint256 usdValue) {
        if (oracles[token] == address(0)) revert OracleNotSet(token);

        // Check sequencer status before using price feeds
        _checkSequencerStatus();

        (int256 answer, uint256 updatedAt) = _getLatestPrice(token);

        // Check staleness using per-token threshold
        uint256 threshold = stalenessThresholds[token];
        if (block.timestamp - updatedAt > threshold) {
            revert StaleOracleData(token, updatedAt, threshold);
        }

        // Check price validity
        if (answer <= 0) {
            revert InvalidPrice(token, answer);
        }

        // Check price deviation from $1.00 peg
        _checkDeviation(token, answer);

        // Calculate USD value
        // amount is in token decimals, price is in priceDecimals
        // Result is in priceDecimals (from Chainlink feed)
        uint8 tokenDecimals = IERC20Metadata(token).decimals();
        
        // usdValue = amount * price / 10^tokenDecimals
        // forge-lint: disable-next-line(unsafe-typecast)
        usdValue = (amount * uint256(answer)) / ScalingConstants.scaleBase(tokenDecimals);
    }

    /// @inheritdoc IDreUSDOracle
    /// @param token The ERC20 token to quote in units of the token (USDC).
    /// @param dreUSDAmount The USD amount expressed in dreUSD decimals (18).
    /// @return tokenAmount Amount of `token` corresponding to `dreUSDAmount`, in the token's native decimals (USDC decimals).
    function getTokenAmount(
        address token,
        uint256 dreUSDAmount
    ) external view returns (uint256 tokenAmount) {
        if (oracles[token] == address(0)) revert OracleNotSet(token);

        // Check sequencer status before using price feeds
        _checkSequencerStatus();

        AggregatorV3Interface oracleFeed = AggregatorV3Interface(oracles[token]);
        uint8 priceDecimals = oracleFeed.decimals();

        (int256 answer, uint256 updatedAt) = _getLatestPrice(token); //0.99e8

        // Check staleness using per-token threshold
        uint256 threshold = stalenessThresholds[token];
        if (block.timestamp - updatedAt > threshold) {
            revert StaleOracleData(token, updatedAt, threshold);
        }

        // Check price validity
        if (answer <= 0) {
            revert InvalidPrice(token, answer);
        }

        // Check price deviation from $1.00 peg
        _checkDeviation(token, answer);

        // Calculate token amount: single division to preserve precision (avoids truncating dreUSD before multiply).
        // tokenAmount = (dreUSDAmount * 10^tokenDecimals) / (price * 10^(dreUsdDecimals - priceDecimals))
        // when dreUsdDecimals > priceDecimals; else scale numerator up to price decimals first.
        uint8 tokenDecimals = IERC20Metadata(token).decimals();
        uint8 dreUsdDecimals = 18; // dreUSD always has 18 decimals

        // Cast safe: we revert above when answer <= 0
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 price = uint256(answer);
        if (dreUsdDecimals > priceDecimals) {
            // forge-lint: disable-next-line(unsafe-typecast)
            tokenAmount = (dreUSDAmount * ScalingConstants.scaleBase(tokenDecimals)) / (price * ScalingConstants.scaleBase(uint8(dreUsdDecimals - priceDecimals)));
        } else {
            tokenAmount = (dreUSDAmount * ScalingConstants.scaleBase(tokenDecimals) * ScalingConstants.scaleBase(uint8(priceDecimals - dreUsdDecimals))) / price;
        }
    }

    /// @inheritdoc IDreUSDOracle
    function getPriceDecimals(address token) external view returns (uint8) {
        if (oracles[token] == address(0)) revert OracleNotSet(token);
        return AggregatorV3Interface(oracles[token]).decimals();
    }

    /// @inheritdoc IDreUSDOracle
    function validatePrice(address token) external view returns (bool valid) {
        if (oracles[token] == address(0)) return false;

        // Check sequencer status - return false if sequencer is down or grace period not over
        if (!_isSequencerHealthy()) return false;

        (int256 answer, uint256 updatedAt) = _getLatestPrice(token);

        // Check staleness using per-token threshold
        if (block.timestamp - updatedAt > stalenessThresholds[token]) return false;

        // Check price validity
        if (answer <= 0) return false;

        // Check price deviation from $1.00 peg
        uint256 deviationBps = deviationThresholds[token];
        if (deviationBps > 0) {
            if (!_isWithinDeviation(token, answer, deviationBps)) return false;
        }

        return true;
    }

    /// @inheritdoc IDreUSDOracle
    function getLatestPrice(address token) external view returns (int256 answer, uint256 updatedAt) {
        if (oracles[token] == address(0)) revert OracleNotSet(token);
        return _getLatestPrice(token);
    }

    /**
     * @dev Reverts if staleness threshold is zero or outside allowed bounds.
     *      Min bound prevents misconfig that would always revert; max bound aligns with
     *      Chainlink heartbeat (e.g. 24h for Base stablecoins) to avoid disabling staleness protection.
     */
    function _requireValidStalenessThreshold(uint256 stalenessThreshold) internal pure {
        if (stalenessThreshold == 0) revert InvalidStalenessThreshold();
        if (stalenessThreshold < MIN_STALENESS_THRESHOLD || stalenessThreshold > MAX_STALENESS_THRESHOLD) {
            revert StalenessThresholdOutOfBounds(stalenessThreshold, MIN_STALENESS_THRESHOLD, MAX_STALENESS_THRESHOLD);
        }
    }

    /**
     * @dev Internal function to get latest price from Chainlink
     */
    function _getLatestPrice(address token) internal view returns (int256 answer, uint256 updatedAt) {
        AggregatorV3Interface oracle = AggregatorV3Interface(oracles[token]);
        
        (
            /* uint80 roundId */,
            answer,
            /* uint256 startedAt */,
            updatedAt,
            /* uint80 answeredInRound */
        ) = oracle.latestRoundData();
    }

    function _checkSequencerStatus() internal view {
        if (!_isSequencerHealthy()) {
            revert SequencerDown();
        }
    }

    /**
     * @notice https://docs.chain.link/data-feeds/l2-sequencer-feeds
     * @dev Checks if sequencer is healthy (up and grace period passed)
     * @return True if sequencer is healthy or if sequencer check is disabled
     */
    function _isSequencerHealthy() internal view returns (bool) {
        // Skip check if sequencer uptime feed is not set (e.g., on L1)
        if (sequencerUptimeFeed == address(0)) return true;

        AggregatorV3Interface sequencerFeed = AggregatorV3Interface(sequencerUptimeFeed);
        
        // prettier-ignore
        (
            /*uint80 roundID*/,
            int256 answer,
            uint256 startedAt,
            /*uint256 updatedAt*/,
            /*uint80 answeredInRound*/
        ) = sequencerFeed.latestRoundData();

        // Answer == 0: Sequencer is up
        // Answer == 1: Sequencer is down
        bool isSequencerUp = answer == 0;
        if (!isSequencerUp) {
            return false;
        }

        // Check grace period
        if (startedAt > 0) {
            uint256 timeSinceUp = block.timestamp - startedAt;
            if (timeSinceUp <= gracePeriod) {
                return false;
            }
        }

        return true;
    }

    /**
     * @dev Checks if price deviates beyond configured threshold from $1.00 peg
     * @param token The token address
     * @param price The current price from oracle (in price feed decimals)
     */
    function _checkDeviation(address token, int256 price) internal view {
        uint256 deviationBps = deviationThresholds[token];
        
        // If no deviation threshold is set, skip check
        if (deviationBps == 0) return;

        if (!_isWithinDeviation(token, price, deviationBps)) {
            uint8 priceDecimals = AggregatorV3Interface(oracles[token]).decimals();
            int256 expectedPrice = int256(ScalingConstants.scaleBase(priceDecimals)); // $1.00 in price feed decimals
            revert PriceDeviationExceeded(token, price, expectedPrice, deviationBps);
        }
    }

    /**
     * @dev Checks if price is within deviation bounds from $1.00 peg
     * @param token The token address
     * @param price The current price from oracle (in price feed decimals)
     * @param deviationBps Deviation threshold in basis points
     * @return True if price is within bounds
     */
    function _isWithinDeviation(address token, int256 price, uint256 deviationBps) internal view returns (bool) {
        uint8 priceDecimals = AggregatorV3Interface(oracles[token]).decimals();
        int256 expectedPrice = int256(ScalingConstants.scaleBase(priceDecimals)); // $1.00 in price feed decimals

        // Calculate bounds: [expected * (BPS_DENOM - bps) / BPS_DENOM, expected * (BPS_DENOM + bps) / BPS_DENOM]
        // forge-lint: disable-next-line(unsafe-typecast) -- BPS values fit in int256
        int256 lowerBound = (expectedPrice * int256(uint256(ScalingConstants.BPS_DENOMINATOR - deviationBps))) / int256(ScalingConstants.BPS_DENOMINATOR);
        // forge-lint: disable-next-line(unsafe-typecast) -- BPS values fit in int256
        int256 upperBound = (expectedPrice * int256(uint256(ScalingConstants.BPS_DENOMINATOR + deviationBps))) / int256(ScalingConstants.BPS_DENOMINATOR);
        
        return price >= lowerBound && price <= upperBound;
    }

    /**
     * @dev Authorizes an upgrade to a new implementation
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}
