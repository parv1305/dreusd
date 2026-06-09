// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";
import {dreUSDOracle} from "../contracts/dreUSDOracle.sol";
import {IDreUSDOracle} from "../contracts/interfaces/IDreUSDOracle.sol";
import {MockAggregatorV3} from "../contracts/mocks/MockAggregatorV3.sol";
import {MockSequencerUptimeFeed} from "../contracts/mocks/MockSequencerUptimeFeed.sol";
import {console} from "forge-std/console.sol";

/// @dev Oracle mock that reverts on decimals() -> setOracle reverts InvalidOracleInterface
contract BadDecimalsFeed {
    function decimals() external pure returns (uint8) {
        revert("BadDecimals");
    }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e8, block.timestamp, block.timestamp, 1);
    }
}

/// @dev Oracle mock that reverts on latestRoundData() -> setOracle reverts InvalidOracleInterface
contract BadLatestRoundDataFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }
    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert("BadLatestRoundData");
    }
}

contract dreUSDOracleTest is Test {
    dreUSDOracle public oracleImpl;
    dreUSDOracle public oracle;
    ERC1967Proxy public proxy;

    MockERC20 public usdc; // 6 decimals
    MockERC20 public dai; // 18 decimals
    MockAggregatorV3 public usdcFeed;
    MockAggregatorV3 public daiFeed;
    MockSequencerUptimeFeed public initSequencerFeed; // sequencer feed used in proxy init (must be non-zero)

    address public admin;
    address public moderator;
    address public upgrader;
    address public unauthorized;
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant MODERATOR_ROLE = keccak256("MODERATOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 public constant STALENESS_THRESHOLD = 1 hours;

    function setUp() public {
        admin = makeAddr("admin");
        moderator = makeAddr("moderator");
        upgrader = makeAddr("upgrader");
        unauthorized = makeAddr("unauthorized");

        // Deploy implementation and proxy (initialize requires non-zero upgrader, moderator, sequencer)
        initSequencerFeed = new MockSequencerUptimeFeed();
        // Sequencer up (answer 0); startedAt 1 so grace period (3600s) is satisfied after warp
        initSequencerFeed.setLatestAnswer(0, 1);
        vm.warp(7200); // past grace period so (block.timestamp - startedAt) >= 3600

        oracleImpl = new dreUSDOracle();
        bytes memory initData = abi.encodeWithSelector(
            dreUSDOracle.initialize.selector,
            admin,
            upgrader,
            moderator,
            address(initSequencerFeed)
        );
        proxy = new ERC1967Proxy(address(oracleImpl), initData);
        oracle = dreUSDOracle(address(proxy));

        // Deploy tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("DAI Stablecoin", "DAI", 18);

        // Deploy feeds (8 decimals typical for USD feeds)
        usdcFeed = new MockAggregatorV3(8, "USDC / USD", 1);
        daiFeed = new MockAggregatorV3(8, "DAI / USD", 1);
    }

    // ============ Initialization ============

    function test_Initialize_SetsRoles() public  {
        assertTrue(oracle.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(oracle.hasRole(UPGRADER_ROLE, upgrader));
        assertTrue(oracle.hasRole(MODERATOR_ROLE, moderator));
    }

    function test_Initialize_SetsSequencerFeed() public  {
        assertEq(oracle.sequencerUptimeFeed(), address(initSequencerFeed));
        assertEq(oracle.gracePeriod(), 3600); // Default grace period
    }

    function test_Initialize_SetsSequencerFeedWithAddress() public {
        dreUSDOracle newOracleImpl = new dreUSDOracle();
        address sequencerFeedAddr = makeAddr("sequencerFeed");
        bytes memory initData = abi.encodeWithSelector(
            dreUSDOracle.initialize.selector,
            admin,
            upgrader,
            moderator,
            sequencerFeedAddr
        );
        ERC1967Proxy newProxy = new ERC1967Proxy(address(newOracleImpl), initData);
        dreUSDOracle newOracle = dreUSDOracle(address(newProxy));

        assertEq(newOracle.sequencerUptimeFeed(), sequencerFeedAddr);
        assertEq(newOracle.gracePeriod(), 3600); // Default grace period
    }

    function test_Initialize_RevertIf_AlreadyInitialized() public {
        vm.expectRevert();
        oracle.initialize(admin, upgrader, moderator, address(initSequencerFeed));
    }

    function test_Initialize_RevertIf_DefaultAdminIsZeroAddress() public {
        dreUSDOracle implementation = new dreUSDOracle();
        bytes memory initData = abi.encodeWithSelector(
            dreUSDOracle.initialize.selector,
            address(0),
            upgrader,
            moderator,
            address(initSequencerFeed)
        );
        vm.expectRevert(IDreUSDOracle.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_Initialize_RevertIf_UpgraderIsZeroAddress() public {
        dreUSDOracle implementation = new dreUSDOracle();
        bytes memory initData = abi.encodeWithSelector(
            dreUSDOracle.initialize.selector,
            admin,
            address(0),
            moderator,
            address(initSequencerFeed)
        );
        vm.expectRevert(IDreUSDOracle.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_Initialize_RevertIf_ModeratorIsZeroAddress() public {
        dreUSDOracle implementation = new dreUSDOracle();
        bytes memory initData = abi.encodeWithSelector(
            dreUSDOracle.initialize.selector,
            admin,
            upgrader,
            address(0),
            address(initSequencerFeed)
        );
        vm.expectRevert(IDreUSDOracle.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_Initialize_RevertIf_SequencerUptimeFeedIsZeroAddress() public {
        dreUSDOracle implementation = new dreUSDOracle();
        bytes memory initData = abi.encodeWithSelector(
            dreUSDOracle.initialize.selector,
            admin,
            upgrader,
            moderator,
            address(0)
        );
        vm.expectRevert(IDreUSDOracle.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    // ============ Oracle Management ============

    function test_SetOracle_Works() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        assertEq(oracle.oracles(address(usdc)), address(usdcFeed));
        assertEq(oracle.stalenessThresholds(address(usdc)), STALENESS_THRESHOLD);
        // Default deviation threshold of 1% (100 bps) should be set
        assertEq(oracle.deviationThresholds(address(usdc)), 100);
    }

    function test_SetOracle_RevertIf_SameOracleAddress() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        vm.prank(moderator);
        vm.expectRevert(IDreUSDOracle.SameOracle.selector);
        oracle.setOracle(address(usdc), address(usdcFeed), 2 hours);
    }

    function test_SetOracle_RevertIf_ZeroAddressesOrThreshold() public {
        vm.startPrank(moderator);

        vm.expectRevert(IDreUSDOracle.ZeroAddress.selector);
        oracle.setOracle(address(0), address(usdcFeed), STALENESS_THRESHOLD);

        vm.expectRevert(IDreUSDOracle.ZeroAddress.selector);
        oracle.setOracle(address(usdc), address(0), STALENESS_THRESHOLD);

        vm.expectRevert(IDreUSDOracle.InvalidStalenessThreshold.selector);
        oracle.setOracle(address(usdc), address(usdcFeed), 0);

        vm.stopPrank();
    }

    function test_SetStalenessThreshold_Works() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        vm.prank(moderator);
        oracle.setStalenessThreshold(address(usdc), 2 hours);

        assertEq(oracle.stalenessThresholds(address(usdc)), 2 hours);
    }

    function test_SetStalenessThreshold_RevertIf_SameValue() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        vm.prank(moderator);
        vm.expectRevert(IDreUSDOracle.SameStalenessThreshold.selector);
        oracle.setStalenessThreshold(address(usdc), STALENESS_THRESHOLD);
    }

    function test_SetStalenessThreshold_RevertIf_OracleNotSet() public {
        vm.prank(moderator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDreUSDOracle.OracleNotSet.selector,
                address(usdc)
            )
        );
        oracle.setStalenessThreshold(address(usdc), STALENESS_THRESHOLD);
    }

    function test_SetStalenessThreshold_RevertIf_ThresholdZero() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        vm.prank(moderator);
        vm.expectRevert(IDreUSDOracle.InvalidStalenessThreshold.selector);
        oracle.setStalenessThreshold(address(usdc), 0);
    }

    function test_SetOracle_RevertIf_StalenessThresholdBelowMin() public {
        vm.prank(moderator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDreUSDOracle.StalenessThresholdOutOfBounds.selector,
                59,
                uint256(60),
                uint256(86400)
            )
        );
        oracle.setOracle(address(usdc), address(usdcFeed), 59);
    }

    function test_SetOracle_RevertIf_StalenessThresholdAboveMax() public {
        vm.prank(moderator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDreUSDOracle.StalenessThresholdOutOfBounds.selector,
                86401,
                uint256(60),
                uint256(86400)
            )
        );
        oracle.setOracle(address(usdc), address(usdcFeed), 86401);
    }

    function test_SetOracle_AcceptsMinAndMaxStalenessThreshold() public {
        vm.startPrank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), 60);
        assertEq(oracle.stalenessThresholds(address(usdc)), 60);

        oracle.setOracle(address(dai), address(daiFeed), 86400);
        assertEq(oracle.stalenessThresholds(address(dai)), 86400);
        vm.stopPrank();
    }

    function test_SetOracle_RevertIf_InvalidOracleInterface_DecimalsFails() public {
        BadDecimalsFeed badFeed = new BadDecimalsFeed();
        vm.prank(moderator);
        vm.expectRevert(abi.encodeWithSelector(IDreUSDOracle.InvalidOracleInterface.selector, address(badFeed)));
        oracle.setOracle(address(usdc), address(badFeed), STALENESS_THRESHOLD);
    }

    function test_SetOracle_RevertIf_InvalidOracleInterface_LatestRoundDataFails() public {
        BadLatestRoundDataFeed badFeed = new BadLatestRoundDataFeed();
        vm.prank(moderator);
        vm.expectRevert(abi.encodeWithSelector(IDreUSDOracle.InvalidOracleInterface.selector, address(badFeed)));
        oracle.setOracle(address(usdc), address(badFeed), STALENESS_THRESHOLD);
    }

    function test_SetOracle_RevertIf_InvalidOracleDecimals() public {
        // Feed with 19 decimals (> 18) must revert
        MockAggregatorV3 feed19 = new MockAggregatorV3(19, "Bad 19 decimals", 1);
        feed19.setLatestAnswer(1e19, block.timestamp); // $1 in 19 decimals so price in bounds
        vm.prank(moderator);
        vm.expectRevert(abi.encodeWithSelector(IDreUSDOracle.InvalidOracleDecimals.selector, address(feed19), uint8(19)));
        oracle.setOracle(address(usdc), address(feed19), STALENESS_THRESHOLD);
    }

    function test_SetOracle_RevertIf_InvalidOraclePrice_BelowThreshold() public {
        // Price must be >= 0.5 in feed decimals (for 8 decimals: >= 0.5e8)
        usdcFeed.setLatestAnswer(0.4e8, block.timestamp); // Below $0.50
        vm.prank(moderator);
        vm.expectRevert(abi.encodeWithSelector(IDreUSDOracle.InvalidOraclePrice.selector, address(usdcFeed), int256(0.4e8)));
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);
    }

    function test_SetOracle_RevertIf_InvalidOraclePrice_AboveThreshold() public {
        // Price must be <= 2.0 in feed decimals (for 8 decimals: <= 2e8)
        usdcFeed.setLatestAnswer(2.5e8, block.timestamp); // Above $2.00
        vm.prank(moderator);
        vm.expectRevert(abi.encodeWithSelector(IDreUSDOracle.InvalidOraclePrice.selector, address(usdcFeed), int256(2.5e8)));
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);
    }

    function test_SetOracle_RevertIf_InvalidOraclePrice_ZeroOrNegative() public {
        usdcFeed.setLatestAnswer(0, block.timestamp);
        vm.prank(moderator);
        vm.expectRevert(abi.encodeWithSelector(IDreUSDOracle.InvalidOraclePrice.selector, address(usdcFeed), int256(0)));
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);
    }

    function test_SetStalenessThreshold_RevertIf_BelowMinOrAboveMax() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        vm.startPrank(moderator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDreUSDOracle.StalenessThresholdOutOfBounds.selector,
                30,
                uint256(60),
                uint256(86400)
            )
        );
        oracle.setStalenessThreshold(address(usdc), 30);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDreUSDOracle.StalenessThresholdOutOfBounds.selector,
                type(uint256).max,
                uint256(60),
                uint256(86400)
            )
        );
        oracle.setStalenessThreshold(address(usdc), type(uint256).max);
        vm.stopPrank();
    }

    function test_RemoveOracle_Works() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        vm.prank(moderator);
        oracle.removeOracle(address(usdc));

        assertEq(oracle.oracles(address(usdc)), address(0));
        assertEq(oracle.stalenessThresholds(address(usdc)), 0);
    }

    function test_RemoveOracle_RevertIf_NotSet() public {
        vm.prank(moderator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDreUSDOracle.OracleNotSet.selector,
                address(usdc)
            )
        );
        oracle.removeOracle(address(usdc));
    }

    // ============ getUsdValue ============

    function test_GetUsdValue_RevertIf_OracleNotSet() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IDreUSDOracle.OracleNotSet.selector,
                address(usdc)
            )
        );
        oracle.getUsdValue(address(usdc), 1e6);
    }

    /// @dev getUsdValue calls _checkSequencerStatus() before using price; when sequencer is down it reverts SequencerDown.
    function test_GetUsdValue_CallsCheckSequencerStatus_BeforePrice() public {
        setUpSequencerFeed();
        vm.prank(moderator);
        oracle.setSequencerUptimeFeed(address(sequencerFeed));
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);
        sequencerFeed.setLatestAnswer(1, block.timestamp); // Sequencer down
        usdcFeed.setLatestAnswer(1e8, block.timestamp);

        vm.expectRevert(IDreUSDOracle.SequencerDown.selector);
        oracle.getUsdValue(address(usdc), 1e6);
    }

    function test_GetUsdValue_RevertIf_Stale() public {
        MockSequencerUptimeFeed priceFeed = new MockSequencerUptimeFeed();
        vm.warp(block.timestamp + 30 days);
        priceFeed.setLatestAnswer(1e8, block.timestamp); // valid so setOracle passes
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(priceFeed), STALENESS_THRESHOLD);

        // Set price updated 2 hours ago, threshold is 1 hour -> stale
        uint256 staleUpdatedAt = block.timestamp - 2 hours;
        priceFeed.setLatestAnswer(1e8, staleUpdatedAt);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDreUSDOracle.StaleOracleData.selector,
                address(usdc),
                staleUpdatedAt,
                STALENESS_THRESHOLD
            )
        );
        oracle.getUsdValue(address(usdc), 1e6);
    }

    function test_GetUsdValue_RevertIf_PriceNonPositive() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        usdcFeed.setLatestAnswer(0, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDreUSDOracle.InvalidPrice.selector,
                address(usdc),
                int256(0)
            )
        );
        oracle.getUsdValue(address(usdc), 1e6);
    }

    function test_GetUsdValue_Usdc6Decimals_Price8Decimals() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        // 1 USDC = 1 USD, price = 1e8
        usdcFeed.setLatestAnswer(1e8, block.timestamp);

        // 10 USDC (6 decimals)
        uint256 amount = 10e6;
        uint256 usdValue = oracle.getUsdValue(address(usdc), amount);

        // usdValue should be 10 * 1e8 = 1e9
        assertEq(usdValue, 10 * 1e8);
    }

    function test_GetUsdValue_Dai18Decimals_Price8Decimals() public {
        vm.prank(moderator);
        oracle.setOracle(address(dai), address(daiFeed), STALENESS_THRESHOLD);

        daiFeed.setLatestAnswer(1e8, block.timestamp);

        uint256 amount = 5e18; // 5 DAI
        uint256 usdValue = oracle.getUsdValue(address(dai), amount);

        // usdValue = amount * price / 1e18 = 5 * 1e8
        assertEq(usdValue, 5 * 1e8);
    }

    function test_GetUsdValue_USDC_LowerThan1() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        // 1 USDC = 0.99 USD, price = 0.99e8
        usdcFeed.setLatestAnswer(0.99e8, block.timestamp);

        // 10 USDC (6 decimals)
        uint256 amount = 10e6;
        uint256 usdValue = oracle.getUsdValue(address(usdc), amount);

        assertEq(usdValue, 9.9 * 1e8); // 9.9 USD = in price decimals (8)
    }

        function test_GetUsdValue_USDC_GreaterThan1() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);
        
        // Set higher deviation threshold to allow 10% deviation for this test
        vm.prank(moderator);
        oracle.setDeviationThreshold(address(usdc), 1000); // 10%

        // 1 USDC = 1.1 USD, price = 1.1e8
        usdcFeed.setLatestAnswer(1.1e8, block.timestamp);

        // 10 USDC (6 decimals)
        uint256 amount = 10e6;
        uint256 usdValue = oracle.getUsdValue(address(usdc), amount);

        assertEq(usdValue, 10 * 1.1 * 1e8); // 9.9 USD = in price decimals (8)
    }

    // ============ getTokenAmount ============

    function test_GetTokenAmount_RevertIf_OracleNotSet() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IDreUSDOracle.OracleNotSet.selector,
                address(usdc)
            )
        );
        oracle.getTokenAmount(address(usdc), 1e18);
    }

    function test_GetTokenAmount_RevertIf_Stale() public {
        MockSequencerUptimeFeed priceFeed = new MockSequencerUptimeFeed();
        vm.warp(block.timestamp + 30 days);
        priceFeed.setLatestAnswer(1e8, block.timestamp); // valid so setOracle passes
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(priceFeed), STALENESS_THRESHOLD);

        uint256 staleUpdatedAt = block.timestamp - 2 hours;
        priceFeed.setLatestAnswer(1e8, staleUpdatedAt);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDreUSDOracle.StaleOracleData.selector,
                address(usdc),
                staleUpdatedAt,
                STALENESS_THRESHOLD
            )
        );
        oracle.getTokenAmount(address(usdc), 1e18);
    }

    function test_GetTokenAmount_RevertIf_PriceNonPositive() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        usdcFeed.setLatestAnswer(0, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDreUSDOracle.InvalidPrice.selector,
                address(usdc),
                int256(0)
            )
        );
        oracle.getTokenAmount(address(usdc), 1e18);
    }

    function test_GetTokenAmount_Usdc6Decimals_Price8Decimals() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        // 1 USDC = 1 USD, price = 1e8
        usdcFeed.setLatestAnswer(1e8, block.timestamp);

        // usdAmount is 10 USD (dreUSD) with 18 decimals
        uint256 usdAmount = 10e18;

        uint256 tokenAmount = oracle.getTokenAmount(address(usdc), usdAmount);

        // priceDecimals = 8, dreUsdDecimals = 18
        // usdAmountInPriceDecimals = usdAmount / 1e10 = 10e18 / 1e10 = 10e8
        // tokenAmount = 10e8 * 1e6 / 1e8 = 10e6
        assertEq(tokenAmount, 10e6);
    }

    function test_GetTokenAmount_Dai18Decimals_Price8Decimals() public {
        vm.prank(moderator);
        oracle.setOracle(address(dai), address(daiFeed), STALENESS_THRESHOLD);

        daiFeed.setLatestAnswer(1e8, block.timestamp);

        uint256 usdAmount = 3e18; // 3 USD
        uint256 tokenAmount = oracle.getTokenAmount(address(dai), usdAmount);

        // Token has 18 decimals, price 1e8 -> should be 3e18
        assertEq(tokenAmount, 3e18);
    }

    function test_GetTokenAmount_USDC_LowerThan1() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        // 0.99 USDC = 1 USD, price = 0.99e8
        usdcFeed.setLatestAnswer(0.99e8, block.timestamp);
        uint256 dreUSDAmount = 10e18;
        uint256 tokenAmount = oracle.getTokenAmount(address(usdc), dreUSDAmount);

        // usdc amount should be greater than 10 in USDC decimals
        assertEq(tokenAmount, 10_101_010); // 10.101010 USDC = 1/0.99
    }

    function test_GetTokenAmount_USDC_GreaterThan1() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);
        
        // Set higher deviation threshold to allow 10% deviation for this test
        vm.prank(moderator);
        oracle.setDeviationThreshold(address(usdc), 1000); // 10%

        // 1.1 USDC = 1 USD, price = 1.1e8
        usdcFeed.setLatestAnswer(1.1e8, block.timestamp);
        uint256 dreUSDAmount = 10e18;
        uint256 tokenAmount = oracle.getTokenAmount(address(usdc), dreUSDAmount);

        assertEq(tokenAmount, 9.090909e6); // USDC = 10/1.1
    }

    function test_GetTokenAmount_Usdc6Decimals_Price18Decimals() public {
        // Create a feed with 18 decimals
        MockAggregatorV3 usdcFeed18 = new MockAggregatorV3(18, "USDC / USD", 1);
        
        // Set price before calling setOracle (required by defensive check)
        // 1 USDC = 1 USD, price = 1e18 (18 decimals)
        usdcFeed18.setLatestAnswer(1e18, block.timestamp);
        
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed18), STALENESS_THRESHOLD);

        // 10 USD (dreUSD) with 18 decimals
        uint256 dreUSDAmount = 10e18;

        uint256 tokenAmount = oracle.getTokenAmount(address(usdc), dreUSDAmount);

        // priceDecimals = 18, dreUsdDecimals = 18
        // usdAmountInPriceDecimals = dreUSDAmount * (10 ** (18 - 18)) = dreUSDAmount * 1 = 10e18
        // tokenAmount = 10e18 * 1e6 / 1e18 = 10e6
        assertEq(tokenAmount, 10e6);
    }

    function test_GetTokenAmount_Dai18Decimals_Price18Decimals() public {
        // Create a feed with 18 decimals
        MockAggregatorV3 daiFeed18 = new MockAggregatorV3(18, "DAI / USD", 1);
        
        // Set price before calling setOracle (required by defensive check)
        // 1 DAI = 1 USD, price = 1e18 (18 decimals)
        daiFeed18.setLatestAnswer(1e18, block.timestamp);
        
        vm.prank(moderator);
        oracle.setOracle(address(dai), address(daiFeed18), STALENESS_THRESHOLD);

        // 5 USD (dreUSD) with 18 decimals
        uint256 dreUSDAmount = 5e18;

        uint256 tokenAmount = oracle.getTokenAmount(address(dai), dreUSDAmount);

        // priceDecimals = 18, dreUsdDecimals = 18
        // usdAmountInPriceDecimals = dreUSDAmount * (10 ** (18 - 18)) = dreUSDAmount * 1 = 5e18
        // tokenAmount = 5e18 * 1e18 / 1e18 = 5e18
        assertEq(tokenAmount, 5e18);
    }

    function test_GetTokenAmount_USDC_Price18Decimals_LowerThan1() public {
        // Create a feed with 18 decimals
        MockAggregatorV3 usdcFeed18 = new MockAggregatorV3(18, "USDC / USD", 1);
        
        // Set price before calling setOracle (required by defensive check)
        // 0.99 USDC = 1 USD, price = 0.99e18 (18 decimals)
        usdcFeed18.setLatestAnswer(0.99e18, block.timestamp);
        
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed18), STALENESS_THRESHOLD);

        // 10 USD (dreUSD) with 18 decimals
        uint256 dreUSDAmount = 10e18;

        uint256 tokenAmount = oracle.getTokenAmount(address(usdc), dreUSDAmount);

        // priceDecimals = 18, dreUsdDecimals = 18
        // usdAmountInPriceDecimals = dreUSDAmount * (10 ** (18 - 18)) = 10e18
        // tokenAmount = 10e18 * 1e6 / 0.99e18 = 10e6 / 0.99 = 10.101010...e6
        // Expected: 10_101_010 (rounded)
        console.log("tokenAmount", tokenAmount);
        assertEq(tokenAmount, 10_101_010);
    }

    function test_GetTokenAmount_USDC_Price18Decimals_GreaterThan1() public {
        // Create a feed with 18 decimals
        MockAggregatorV3 usdcFeed18 = new MockAggregatorV3(18, "USDC / USD", 1);
        
        // Set price before calling setOracle (required by defensive check)
        // 1.1 USDC = 1 USD, price = 1.1e18 (18 decimals)
        usdcFeed18.setLatestAnswer(1.1e18, block.timestamp);
        
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed18), STALENESS_THRESHOLD);
        
        // Set higher deviation threshold to allow 10% deviation for this test
        vm.prank(moderator);
        oracle.setDeviationThreshold(address(usdc), 1000); // 10%

        // 10 USD (dreUSD) with 18 decimals
        uint256 dreUSDAmount = 10e18;

        uint256 tokenAmount = oracle.getTokenAmount(address(usdc), dreUSDAmount);

        // priceDecimals = 18, dreUsdDecimals = 18
        // usdAmountInPriceDecimals = dreUSDAmount * (10 ** (18 - 18)) = 10e18
        // tokenAmount = 10e18 * 1e6 / 1.1e18 = 10e6 / 1.1 = 9.090909...e6
        assertEq(tokenAmount, 9_090_909);
    }


    // ============ validatePrice & getLatestPrice & getPriceDecimals ============

    function test_ValidatePrice_FalseIf_NoOracle() public  {
        bool valid = oracle.validatePrice(address(usdc));
        assertFalse(valid);
    }

    function test_ValidatePrice_FalseIf_Stale() public {
        MockSequencerUptimeFeed priceFeed = new MockSequencerUptimeFeed();
        vm.warp(block.timestamp + 30 days);
        priceFeed.setLatestAnswer(1e8, block.timestamp); // valid so setOracle passes
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(priceFeed), STALENESS_THRESHOLD);

        priceFeed.setLatestAnswer(1e8, block.timestamp - 2 hours);

        bool valid = oracle.validatePrice(address(usdc));
        assertFalse(valid);
    }

    function test_ValidatePrice_FalseIf_PriceNonPositive() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        usdcFeed.setLatestAnswer(0, block.timestamp);

        bool valid = oracle.validatePrice(address(usdc));
        assertFalse(valid);
    }

    function test_ValidatePrice_TrueIf_Valid() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        usdcFeed.setLatestAnswer(1e8, block.timestamp);

        bool valid = oracle.validatePrice(address(usdc));
        assertTrue(valid);
    }

    function testFuzz_ValidatePrice_MatchesSpec(
        uint256 ageSecondsRaw,
        uint256 priceAbsRaw,
        bool isNegative
    ) public {
        // Use a feed that returns the configured updatedAt (MockAggregatorV3 ignores it)
        MockSequencerUptimeFeed priceFeed = new MockSequencerUptimeFeed();
        vm.warp(1_000_000);
        priceFeed.setLatestAnswer(1e8, block.timestamp); // valid price so setOracle passes
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(priceFeed), STALENESS_THRESHOLD);

        vm.prank(moderator);
        oracle.setDeviationThreshold(address(usdc), 0);

        uint256 ageSeconds = bound(ageSecondsRaw, 0, (2 * STALENESS_THRESHOLD) + 1);
        uint256 updatedAt = block.timestamp - ageSeconds;

        uint256 absBounded = bound(priceAbsRaw, 0, uint256(type(int256).max));
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 price = int256(absBounded);
        if (isNegative) {
            price = -price;
        }

        priceFeed.setLatestAnswer(price, updatedAt);

        bool valid = oracle.validatePrice(address(usdc));
        bool expected = (price > 0) && (ageSeconds <= STALENESS_THRESHOLD);
        assertEq(valid, expected);
    }

    function test_GetLatestPrice_Works() public {
        // Use a feed that returns the configured updatedAt (MockAggregatorV3 ignores it)
        MockSequencerUptimeFeed priceFeed = new MockSequencerUptimeFeed();
        priceFeed.setLatestAnswer(2e8, 1234); // set before setOracle (oracle validates price at registration)
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(priceFeed), STALENESS_THRESHOLD);

        (int256 answer, uint256 updatedAt) = oracle.getLatestPrice(address(usdc));
        assertEq(answer, 2e8);
        assertEq(updatedAt, 1234);
    }

    function test_GetLatestPrice_RevertIf_OracleNotSet() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IDreUSDOracle.OracleNotSet.selector,
                address(usdc)
            )
        );
        oracle.getLatestPrice(address(usdc));
    }

    function test_GetPriceDecimals_Works() public {
        // Using view here because MockAggregatorV3.decimals is immutable
        dreUSDOracle viewOracle = oracle;
        vm.expectRevert(
            abi.encodeWithSelector(
                IDreUSDOracle.OracleNotSet.selector,
                address(usdc)
            )
        );
        viewOracle.getPriceDecimals(address(usdc));
    }

    function test_GetPriceDecimals_AfterSetOracle() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        uint8 priceDecimals = oracle.getPriceDecimals(address(usdc));
        assertEq(priceDecimals, 8);
    }

    // ============ Upgrade Tests (_authorizeUpgrade) ============

    function test_Upgrade_Success() public {
        dreUSDOracle newImplementation = new dreUSDOracle();

        vm.prank(upgrader);
        oracle.upgradeToAndCall(address(newImplementation), "");

        // Proxy still works; verify oracle state is preserved (e.g. roles)
        assertTrue(oracle.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(oracle.hasRole(UPGRADER_ROLE, upgrader));
    }

    function test_Upgrade_RevertIf_NotUpgrader() public {
        dreUSDOracle newImplementation = new dreUSDOracle();

        vm.prank(unauthorized);
        vm.expectRevert();
        oracle.upgradeToAndCall(address(newImplementation), "");
    }

    function test_Upgrade_RevertIf_ModeratorWithoutUpgraderRole() public {
        dreUSDOracle newImplementation = new dreUSDOracle();

        // Moderator has MODERATOR_ROLE but not UPGRADER_ROLE
        vm.prank(moderator);
        vm.expectRevert();
        oracle.upgradeToAndCall(address(newImplementation), "");
    }

    // ============ Deviation Threshold Tests ============

    function test_SetDeviationThreshold_Works() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        vm.prank(moderator);
        oracle.setDeviationThreshold(address(usdc), 200); // 2%

        assertEq(oracle.deviationThresholds(address(usdc)), 200);
    }

    function test_SetDeviationThreshold_RevertIf_SameValue() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);
        assertEq(oracle.deviationThresholds(address(usdc)), 100); // default

        vm.prank(moderator);
        vm.expectRevert(IDreUSDOracle.SameDeviationThreshold.selector);
        oracle.setDeviationThreshold(address(usdc), 100);
    }

    function test_SetDeviationThreshold_RevertIf_OracleNotSet() public {
        vm.prank(moderator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDreUSDOracle.OracleNotSet.selector,
                address(usdc)
            )
        );
        oracle.setDeviationThreshold(address(usdc), 200);
    }

    function test_SetDeviationThreshold_RevertIf_ExceedsMax() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        vm.prank(moderator);
        vm.expectRevert(IDreUSDOracle.InvalidDeviationThreshold.selector);
        oracle.setDeviationThreshold(address(usdc), 10_001); // > 100%
    }

    function test_GetUsdValue_RevertIf_PriceAboveDeviation() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        vm.prank(moderator);
        oracle.setDeviationThreshold(address(usdc), 200); // 2% deviation

        // Price = 1.03 USD (3% deviation, exceeds 2% threshold)
        usdcFeed.setLatestAnswer(1.03e8, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDreUSDOracle.PriceDeviationExceeded.selector,
                address(usdc),
                int256(1.03e8),
                int256(1e8),
                200
            )
        );
        oracle.getUsdValue(address(usdc), 1e6);
    }

    function test_GetUsdValue_RevertIf_PriceBelowDeviation() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        vm.prank(moderator);
        oracle.setDeviationThreshold(address(usdc), 200); // 2% deviation

        // Price = 0.97 USD (3% deviation, exceeds 2% threshold)
        usdcFeed.setLatestAnswer(0.97e8, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDreUSDOracle.PriceDeviationExceeded.selector,
                address(usdc),
                int256(0.97e8),
                int256(1e8),
                200
            )
        );
        oracle.getUsdValue(address(usdc), 1e6);
    }

    function test_GetUsdValue_PassesIf_PriceWithinDeviation() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        vm.prank(moderator);
        oracle.setDeviationThreshold(address(usdc), 200); // 2% deviation

        // Price = 1.01 USD (1% deviation, within 2% threshold)
        usdcFeed.setLatestAnswer(1.01e8, block.timestamp);

        uint256 usdValue = oracle.getUsdValue(address(usdc), 10e6);
        assertEq(usdValue, 10 * 1.01 * 1e8);
    }

    function test_GetUsdValue_PassesIf_DeviationThresholdNotSet() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);
        
        // Explicitly disable deviation threshold (set to 0) to test backward compatibility
        vm.prank(moderator);
        oracle.setDeviationThreshold(address(usdc), 0);

        // Price = 1.1 USD (10% deviation, but no threshold check)
        usdcFeed.setLatestAnswer(1.1e8, block.timestamp);

        uint256 usdValue = oracle.getUsdValue(address(usdc), 10e6);
        assertEq(usdValue, 10 * 1.1 * 1e8);
    }

    function test_GetTokenAmount_RevertIf_PriceAboveDeviation() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        vm.prank(moderator);
        oracle.setDeviationThreshold(address(usdc), 200); // 2% deviation

        // Price = 1.03 USD (3% deviation, exceeds 2% threshold)
        usdcFeed.setLatestAnswer(1.03e8, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDreUSDOracle.PriceDeviationExceeded.selector,
                address(usdc),
                int256(1.03e8),
                int256(1e8),
                200
            )
        );
        oracle.getTokenAmount(address(usdc), 10e18);
    }

    function test_GetTokenAmount_RevertIf_PriceBelowDeviation() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        vm.prank(moderator);
        oracle.setDeviationThreshold(address(usdc), 200); // 2% deviation

        // Price = 0.97 USD (3% deviation, exceeds 2% threshold)
        usdcFeed.setLatestAnswer(0.97e8, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDreUSDOracle.PriceDeviationExceeded.selector,
                address(usdc),
                int256(0.97e8),
                int256(1e8),
                200
            )
        );
        oracle.getTokenAmount(address(usdc), 10e18);
    }

    function test_ValidatePrice_FalseIf_PriceExceedsDeviation() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        vm.prank(moderator);
        oracle.setDeviationThreshold(address(usdc), 200); // 2% deviation

        // Price = 1.03 USD (3% deviation, exceeds 2% threshold)
        usdcFeed.setLatestAnswer(1.03e8, block.timestamp);

        bool valid = oracle.validatePrice(address(usdc));
        assertFalse(valid);
    }

    function test_ValidatePrice_TrueIf_PriceWithinDeviation() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        vm.prank(moderator);
        oracle.setDeviationThreshold(address(usdc), 200); // 2% deviation

        // Price = 1.01 USD (1% deviation, within 2% threshold)
        usdcFeed.setLatestAnswer(1.01e8, block.timestamp);

        bool valid = oracle.validatePrice(address(usdc));
        assertTrue(valid);
    }

    function test_RemoveOracle_ClearsDeviationThreshold() public {
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        vm.prank(moderator);
        oracle.setDeviationThreshold(address(usdc), 200);

        vm.prank(moderator);
        oracle.removeOracle(address(usdc));

        assertEq(oracle.deviationThresholds(address(usdc)), 0);
    }

    // ============ Sequencer Uptime Feed ============

    MockSequencerUptimeFeed public sequencerFeed;

    function setUpSequencerFeed() internal {
        sequencerFeed = new MockSequencerUptimeFeed();
    }

    function test_SetSequencerUptimeFeed_Works() public {
        setUpSequencerFeed();
        
        vm.prank(moderator);
        oracle.setSequencerUptimeFeed(address(sequencerFeed));

        assertEq(oracle.sequencerUptimeFeed(), address(sequencerFeed));
    }

    function test_SetSequencerUptimeFeed_RevertIf_SameValue() public {
        vm.prank(moderator);
        vm.expectRevert(IDreUSDOracle.SameSequencerUptimeFeed.selector);
        oracle.setSequencerUptimeFeed(address(initSequencerFeed));
    }

    function test_SetSequencerUptimeFeed_EmitsEvent() public {
        setUpSequencerFeed();
        
        vm.prank(moderator);
        vm.expectEmit(true, true, false, false);
        emit IDreUSDOracle.SequencerUptimeFeedSet(address(initSequencerFeed), address(sequencerFeed));
        oracle.setSequencerUptimeFeed(address(sequencerFeed));
    }

    function test_SetGracePeriod_Works() public {
        vm.prank(moderator);
        oracle.setGracePeriod(7200); // 2 hours

        assertEq(oracle.gracePeriod(), 7200);
    }

    function test_SetGracePeriod_RevertIf_SameValue() public {
        vm.prank(moderator);
        vm.expectRevert(IDreUSDOracle.SameGracePeriod.selector);
        oracle.setGracePeriod(3600); // current default
    }

    function test_SetGracePeriod_RevertIf_BelowMin() public {
        vm.prank(moderator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDreUSDOracle.GracePeriodOutOfBounds.selector,
                59,
                uint256(60),
                uint256(86400)
            )
        );
        oracle.setGracePeriod(59);
    }

    function test_SetGracePeriod_RevertIf_AboveMax() public {
        vm.prank(moderator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDreUSDOracle.GracePeriodOutOfBounds.selector,
                86401,
                uint256(60),
                uint256(86400)
            )
        );
        oracle.setGracePeriod(86401);
    }

    function test_SetGracePeriod_EmitsEvent() public {
        vm.prank(moderator);
        vm.expectEmit(false, false, false, false);
        emit IDreUSDOracle.GracePeriodUpdated(3600, 7200);
        oracle.setGracePeriod(7200);
    }

    function test_GetUsdValue_WorksWhenSequencerNotSet() public {
        // Sequencer is set in init and is "up"; getUsdValue works normally
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        usdcFeed.setLatestAnswer(1e8, block.timestamp);
        uint256 usdValue = oracle.getUsdValue(address(usdc), 10e6);
        assertEq(usdValue, 10 * 1e8);
    }

    function test_GetUsdValue_RevertIf_SequencerDown() public {
        setUpSequencerFeed();
        
        vm.prank(moderator);
        oracle.setSequencerUptimeFeed(address(sequencerFeed));
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        // Sequencer is down (answer = 1)
        sequencerFeed.setLatestAnswer(1, block.timestamp);
        usdcFeed.setLatestAnswer(1e8, block.timestamp);

        vm.expectRevert(IDreUSDOracle.SequencerDown.selector);
        oracle.getUsdValue(address(usdc), 10e6);
    }

    function test_GetUsdValue_RevertIf_GracePeriodNotOver() public {
        setUpSequencerFeed();
        
        vm.prank(moderator);
        oracle.setSequencerUptimeFeed(address(sequencerFeed));
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        // Advance time to ensure we have enough timestamp to work with
        vm.warp(block.timestamp + 2 hours);
        
        // Sequencer is up (answer = 0), but just recovered (startedAt = now - 30 minutes)
        // Grace period is 1 hour by default
        uint256 recoveryTime = block.timestamp - 30 minutes;
        sequencerFeed.setLatestAnswer(0, recoveryTime);
        usdcFeed.setLatestAnswer(1e8, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDreUSDOracle.SequencerDown.selector,
                30 minutes,
                3600
            )
        );
        oracle.getUsdValue(address(usdc), 10e6);
    }

    function test_GetUsdValue_WorksAfterGracePeriod() public {
        setUpSequencerFeed();
        
        vm.prank(moderator);
        oracle.setSequencerUptimeFeed(address(sequencerFeed));
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        // Advance time to ensure we have enough timestamp to work with
        vm.warp(block.timestamp + 3 hours);
        
        // Sequencer is up and grace period has passed (startedAt = now - 2 hours)
        uint256 recoveryTime = block.timestamp - 2 hours;
        sequencerFeed.setLatestAnswer(0, recoveryTime);
        usdcFeed.setLatestAnswer(1e8, block.timestamp);

        uint256 usdValue = oracle.getUsdValue(address(usdc), 10e6);
        assertEq(usdValue, 10 * 1e8);
    }

    function test_GetTokenAmount_RevertIf_SequencerDown() public {
        setUpSequencerFeed();
        
        vm.prank(moderator);
        oracle.setSequencerUptimeFeed(address(sequencerFeed));
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        sequencerFeed.setLatestAnswer(1, block.timestamp);
        usdcFeed.setLatestAnswer(1e8, block.timestamp);

        vm.expectRevert(IDreUSDOracle.SequencerDown.selector);
        oracle.getTokenAmount(address(usdc), 10e18);
    }

    function test_GetTokenAmount_RevertIf_GracePeriodNotOver() public {
        setUpSequencerFeed();
        
        vm.prank(moderator);
        oracle.setSequencerUptimeFeed(address(sequencerFeed));
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        vm.warp(block.timestamp + 2 hours);
        
        uint256 recoveryTime = block.timestamp - 30 minutes;
        sequencerFeed.setLatestAnswer(0, recoveryTime);
        usdcFeed.setLatestAnswer(1e8, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDreUSDOracle.SequencerDown.selector,
                30 minutes,
                3600
            )
        );
        oracle.getTokenAmount(address(usdc), 10e18);
    }

    function test_GetTokenAmount_WorksAfterGracePeriod() public {
        setUpSequencerFeed();
        
        vm.prank(moderator);
        oracle.setSequencerUptimeFeed(address(sequencerFeed));
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        vm.warp(block.timestamp + 3 hours);
        
        uint256 recoveryTime = block.timestamp - 2 hours;
        sequencerFeed.setLatestAnswer(0, recoveryTime);
        usdcFeed.setLatestAnswer(1e8, block.timestamp);

        uint256 tokenAmount = oracle.getTokenAmount(address(usdc), 10e18);
        assertEq(tokenAmount, 10e6); // 10 USDC
    }

    function test_ValidatePrice_FalseIf_SequencerDown() public {
        setUpSequencerFeed();
        
        vm.prank(moderator);
        oracle.setSequencerUptimeFeed(address(sequencerFeed));
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        sequencerFeed.setLatestAnswer(1, block.timestamp);
        usdcFeed.setLatestAnswer(1e8, block.timestamp);

        bool valid = oracle.validatePrice(address(usdc));
        assertFalse(valid);
    }

    function test_ValidatePrice_FalseIf_GracePeriodNotOver() public {
        setUpSequencerFeed();
        
        vm.prank(moderator);
        oracle.setSequencerUptimeFeed(address(sequencerFeed));
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        vm.warp(block.timestamp + 2 hours);
        
        uint256 recoveryTime = block.timestamp - 30 minutes;
        sequencerFeed.setLatestAnswer(0, recoveryTime);
        usdcFeed.setLatestAnswer(1e8, block.timestamp);

        bool valid = oracle.validatePrice(address(usdc));
        assertFalse(valid);
    }

    function test_ValidatePrice_TrueAfterGracePeriod() public {
        setUpSequencerFeed();
        
        vm.prank(moderator);
        oracle.setSequencerUptimeFeed(address(sequencerFeed));
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        vm.warp(block.timestamp + 3 hours);
        
        uint256 recoveryTime = block.timestamp - 2 hours;
        sequencerFeed.setLatestAnswer(0, recoveryTime);
        usdcFeed.setLatestAnswer(1e8, block.timestamp);

        bool valid = oracle.validatePrice(address(usdc));
        assertTrue(valid);
    }

    function test_SequencerCheck_WorksWithCustomGracePeriod() public {
        setUpSequencerFeed();
        
        vm.prank(moderator);
        oracle.setSequencerUptimeFeed(address(sequencerFeed));
        vm.prank(moderator);
        oracle.setGracePeriod(30 minutes); // Custom grace period
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        vm.warp(block.timestamp + 1 hours);
        
        // Sequencer recovered 35 minutes ago, custom grace period is 30 minutes
        uint256 recoveryTime = block.timestamp - 35 minutes;
        sequencerFeed.setLatestAnswer(0, recoveryTime);
        usdcFeed.setLatestAnswer(1e8, block.timestamp);

        // Should work since grace period has passed
        uint256 usdValue = oracle.getUsdValue(address(usdc), 10e6);
        assertEq(usdValue, 10 * 1e8);
    }

    function test_SequencerCheck_HandlesStartedAtZero() public {
        setUpSequencerFeed();
        
        vm.prank(moderator);
        oracle.setSequencerUptimeFeed(address(sequencerFeed));
        vm.prank(moderator);
        oracle.setOracle(address(usdc), address(usdcFeed), STALENESS_THRESHOLD);

        // On Arbitrum, startedAt can be 0 when feed is not initialized
        // For Base/OP chains, startedAt is never 0 after initialization
        // But we test the edge case anyway
        sequencerFeed.setLatestAnswer(0, 0); // startedAt = 0
        usdcFeed.setLatestAnswer(1e8, block.timestamp);

        // Should work when startedAt is 0 (skip grace period check)
        uint256 usdValue = oracle.getUsdValue(address(usdc), 10e6);
        assertEq(usdValue, 10 * 1e8);
    }
}

