// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";
import {dreRewardsDistributor} from "../contracts/dreRewardsDistributor.sol";
import {IdreRewardsDistributor} from "../contracts/interfaces/IdreRewardsDistributor.sol";
import {IdreUSDs} from "../contracts/interfaces/IdreUSDs.sol";

/**
 * @title NoOpVault
 * @dev Vault that implements claimVestedRewards() and returns 0. Used as default vault so addRewards() does not revert when calling vault.claimVestedRewards().
 */
contract NoOpVault is IdreUSDs {
    function rewardsDistributor() external pure returns (address) {
        return address(0);
    }

    function claimVestedRewards() external pure returns (uint256) {
        return 0;
    }

    function excessDreUSD() external pure returns (uint256) {
        return 0;
    }

    function withdrawExcessDreUSD(address) external pure returns (uint256) {
        return 0;
    }
}

/**
 * @title MockVaultForAddRewardsTest
 * @dev Minimal vault that implements claimVestedRewards and tracks virtual balance for testing addRewards flow.
 */
contract MockVaultForAddRewardsTest is IdreUSDs {
    IdreRewardsDistributor public distributor;
    uint256 public virtualBalance;

    function rewardsDistributor() external view returns (address) {
        return address(distributor);
    }

    function setDistributor(address _distributor) external {
        distributor = IdreRewardsDistributor(_distributor);
    }

    function claimVestedRewards() external returns (uint256 claimed) {
        claimed = distributor.claimVested();
        virtualBalance += claimed;
        return claimed;
    }

    function excessDreUSD() external pure returns (uint256) {
        return 0;
    }

    function withdrawExcessDreUSD(address) external pure returns (uint256) {
        return 0;
    }
}

/**
 * @title dreRewardsDistributorTest
 * @dev Comprehensive test suite for dreRewardsDistributor contract
 */
contract dreRewardsDistributorTest is Test {
    dreRewardsDistributor public distributor;
    dreRewardsDistributor public implementation;
    ERC1967Proxy public proxy;

    MockERC20 public dreUSD;
    address public vault;
    address public defaultAdmin;
    address public upgrader;
    address public pauser;
    address public moderator;
    address public user1;

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MODERATOR_ROLE = keccak256("MODERATOR_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    error EnforcedPause();

    uint256 public constant INITIAL_DISTRIBUTOR_BALANCE = 1000000 ether;

    event RewardsClaimed(uint256 amount);
    event RewardsScheduleUpdated(uint256 newRewards, uint256 totalRewards, uint256 startTimestamp, uint256 endTimestamp);

    function setUp() public {
        dreUSD = new MockERC20("dreUSD", "dreUSD", 18);
        defaultAdmin = makeAddr("defaultAdmin");
        upgrader = makeAddr("upgrader");
        pauser = makeAddr("pauser");
        moderator = makeAddr("moderator");
        user1 = makeAddr("user1");
        NoOpVault noOpVault = new NoOpVault();
        vault = address(noOpVault);

        implementation = new dreRewardsDistributor(address(dreUSD), vault);
        bytes memory initData = abi.encodeWithSelector(
            dreRewardsDistributor.initialize.selector,
            defaultAdmin,
            upgrader,
            pauser
        );
        proxy = new ERC1967Proxy(address(implementation), initData);
        distributor = dreRewardsDistributor(address(proxy));

        // MODERATOR_ROLE is granted after deployment (to manager)
        vm.startPrank(defaultAdmin);
        distributor.grantRole(MODERATOR_ROLE, moderator);
        vm.stopPrank();

        dreUSD.mint(address(distributor), INITIAL_DISTRIBUTOR_BALANCE);
    }

    function test_Initialize() public {
        assertEq(distributor.dreUSD(), address(dreUSD));
        assertEq(distributor.vault(), vault);
        assertEq(distributor.VEST_PERIOD(), 7 days);
        assertEq(distributor.cTs(), block.timestamp);
        assertEq(distributor.eTs(), block.timestamp);
        assertEq(distributor.rewards(), 0);
        assertTrue(distributor.hasRole(DEFAULT_ADMIN_ROLE, defaultAdmin));
        assertTrue(distributor.hasRole(UPGRADER_ROLE, upgrader));
        assertTrue(distributor.hasRole(PAUSER_ROLE, pauser));
    }

    function test_Constructor_RevertIf_ZeroDreUSD() public {
        vm.expectRevert(IdreRewardsDistributor.ZeroAddress.selector);
        new dreRewardsDistributor(address(0), vault);
    }

    function test_Constructor_RevertIf_ZeroVault() public {
        vm.expectRevert(IdreRewardsDistributor.ZeroAddress.selector);
        new dreRewardsDistributor(address(dreUSD), address(0));
    }

    function test_Initialize_RevertIf_AlreadyInitialized() public {
        vm.expectRevert();
        distributor.initialize(defaultAdmin, upgrader, pauser);
    }

    function test_Initialize_RevertIf_DefaultAdminIsZeroAddress() public {
        bytes memory initData = abi.encodeWithSelector(
            dreRewardsDistributor.initialize.selector,
            address(0),
            upgrader,
            pauser
        );
        vm.expectRevert(IdreRewardsDistributor.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_Initialize_RevertIf_UpgraderIsZeroAddress() public {
        bytes memory initData = abi.encodeWithSelector(
            dreRewardsDistributor.initialize.selector,
            defaultAdmin,
            address(0),
            pauser
        );
        vm.expectRevert(IdreRewardsDistributor.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_Initialize_RevertIf_PauserIsZeroAddress() public {
        bytes memory initData = abi.encodeWithSelector(
            dreRewardsDistributor.initialize.selector,
            defaultAdmin,
            upgrader,
            address(0)
        );
        vm.expectRevert(IdreRewardsDistributor.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_AddRewards_FirstTime() public {
        uint256 expectedCTs = block.timestamp;
        uint256 expectedETs = block.timestamp + 7 days;
        
        vm.expectEmit(false, false, false, true);
        emit RewardsScheduleUpdated(INITIAL_DISTRIBUTOR_BALANCE, INITIAL_DISTRIBUTOR_BALANCE, expectedCTs, expectedETs);
        
        vm.prank(moderator);
        distributor.addRewards();
        assertEq(distributor.rewards(), INITIAL_DISTRIBUTOR_BALANCE);
        assertEq(distributor.eTs(), expectedETs);
        assertEq(distributor.cTs(), expectedCTs);
    }

    /// @dev addRewards() calls vault.claimVestedRewards() first; when some rewards were already vested, vault virtual balance increases.
    function test_AddRewards_UpdatesVaultVirtualBalance_WhenRewardsAlreadyVested() public {
        MockVaultForAddRewardsTest mockVault = new MockVaultForAddRewardsTest();
        dreRewardsDistributor impl = new dreRewardsDistributor(address(dreUSD), address(mockVault));
        bytes memory initData = abi.encodeWithSelector(
            dreRewardsDistributor.initialize.selector,
            defaultAdmin,
            upgrader,
            pauser
        );
        ERC1967Proxy distProxy = new ERC1967Proxy(address(impl), initData);
        dreRewardsDistributor dist = dreRewardsDistributor(address(distProxy));
        vm.prank(defaultAdmin);
        dist.grantRole(MODERATOR_ROLE, moderator);
        mockVault.setDistributor(address(dist));

        uint256 amount = 1000 ether;
        dreUSD.mint(address(dist), amount);

        vm.prank(moderator);
        dist.addRewards();
        assertEq(dist.rewards(), amount);

        vm.warp(block.timestamp + 1 days);
        uint256 vestedBefore = dist.vestedAmount();
        assertGt(vestedBefore, 0, "some rewards should be vested after 1 day");
        uint256 vbBefore = mockVault.virtualBalance();
        uint256 vaultBalanceBefore = dreUSD.balanceOf(address(mockVault));

        vm.prank(moderator);
        dist.addRewards();

        assertEq(mockVault.virtualBalance(), vbBefore + vestedBefore, "vault virtual balance should increase by vested amount");
        assertEq(dreUSD.balanceOf(address(mockVault)), vaultBalanceBefore + vestedBefore, "vault should receive vested dreUSD");
    }

    /// @dev Audit finding: when there are no in-progress rewards (rewards == 0) and new rewards are added,
    ///      addRewards() must reset cTs to block.timestamp so the new stream vests over vestPeriod from now.
    ///      Otherwise cTs stays in the past and nearly all new rewards vest immediately.
    function test_AddRewards_WhenIdle_ResetsCTs_SoVestingStartsFromNow() public {
        uint256 idlePeriod = 365 days;

        // Contract has been idle since init: never called addRewards, so rewards == 0
        vm.warp(block.timestamp + idlePeriod);
        uint256 now_ = block.timestamp;
        uint256 expectedETs = now_ + 7 days;

        vm.expectEmit(false, false, false, true);
        emit RewardsScheduleUpdated(INITIAL_DISTRIBUTOR_BALANCE, INITIAL_DISTRIBUTOR_BALANCE, now_, expectedETs);

        vm.prank(moderator);
        distributor.addRewards();

        // Required fix: cTs must be set to current time when starting a new stream (rewards was 0)
        assertEq(distributor.cTs(), now_, "cTs must be reset to current time when adding rewards after idle");
        assertEq(distributor.eTs(), expectedETs, "eTs must be now + vestPeriod");

        // With cTs reset: at call time vested should be 0 (we're at start of window)
        uint256 vested = distributor.vestedAmount();
        assertEq(vested, 0, "no rewards should be vested yet when stream starts from now");

        // After 1 day, only ~1/7 of rewards should be vested (not ~98% as with stale cTs)
        vm.warp(now_ + 1 days);
        vested = distributor.vestedAmount();
        uint256 totalRewards = distributor.rewards();
        uint256 expectedVestedAfter1Day = totalRewards * (1 days) / (7 days);
        assertEq(vested, expectedVestedAfter1Day, "vesting should follow 7-day schedule from addRewards time");
    }

    function test_AddRewards_RevertIf_NotModerator() public {
        vm.prank(user1);
        vm.expectRevert();
        distributor.addRewards();
    }

    /// @dev addRewards when no new tokens have been transferred: newRewards = balance - rewards = 0. Should not revert; schedule unchanged.
    function test_AddRewards_WhenNewRewardsIsZero() public {
        vm.prank(moderator);
        distributor.addRewards();

        uint256 rewardsAfterFirst = distributor.rewards();
        uint256 cTsAfterFirst = distributor.cTs();
        uint256 eTsAfterFirst = distributor.eTs();

        vm.prank(moderator);
        distributor.addRewards();

        assertEq(distributor.rewards(), rewardsAfterFirst, "rewards unchanged when newRewards is 0");
        assertEq(distributor.cTs(), cTsAfterFirst, "cTs unchanged when newRewards is 0");
        assertEq(distributor.eTs(), eTsAfterFirst, "eTs unchanged when newRewards is 0");
    }

    /// @dev When newRewards = 0 and currentVestPeriod < (VEST_PERIOD - 1 day), addRewards resets cTs/eTs to re-vest remainder over 7 days.
    ///      Uses a vault that calls claimVested() so cTs/rewards are updated before the reset check.
    function test_AddRewards_WhenNewRewardsIsZero_ResetsSchedule_IfVestPeriodBelowThreshold() public {
        MockVaultForAddRewardsTest mockVault = new MockVaultForAddRewardsTest();
        dreRewardsDistributor impl = new dreRewardsDistributor(address(dreUSD), address(mockVault));
        bytes memory initData = abi.encodeWithSelector(
            dreRewardsDistributor.initialize.selector,
            defaultAdmin,
            upgrader,
            pauser
        );
        ERC1967Proxy distProxy = new ERC1967Proxy(address(impl), initData);
        dreRewardsDistributor dist = dreRewardsDistributor(address(distProxy));
        vm.prank(defaultAdmin);
        dist.grantRole(MODERATOR_ROLE, moderator);
        mockVault.setDistributor(address(dist));

        uint256 amount = 1000 ether;
        dreUSD.mint(address(dist), amount);

        vm.prank(moderator);
        dist.addRewards();

        uint256 rewardsBefore = dist.rewards();

        // Warp 2 days into the 7-day window. After _claimVested(), cTs moves to now, so currentVestPeriod = eTs - cTs = 5 days < 6 days.
        vm.warp(block.timestamp + 2 days);

        vm.prank(moderator);
        dist.addRewards();

        // Reset condition: cTs = now, eTs = now + 7 days. rewards unchanged (no new rewards added, only claimed portion was sent to vault).
        uint256 now_ = block.timestamp;
        assertEq(dist.cTs(), now_, "cTs reset to now when newRewards=0 and vest period < 6 days");
        assertEq(dist.eTs(), now_ + 7 days, "eTs reset to now + VEST_PERIOD");
        assertLt(dist.rewards(), rewardsBefore, "rewards decreased by claimed amount");
        assertEq(dist.rewards(), dreUSD.balanceOf(address(dist)), "rewards equals balance (newRewards was 0)");
    }

    /// @dev When extending an active schedule, if newRewards * (eTs - cTs) / rewards rounds to 0 (dust),
    ///      eTs is unchanged and rewards increase; rate increases slowly (intended: dust absorbed, slightly higher APY).
    function test_AddRewards_DustIncreasesRate_WhenRtsRoundsToZero() public {
        vm.prank(moderator);
        distributor.addRewards();
        uint256 eTsBefore = distributor.eTs();
        uint256 rewardsBefore = distributor.rewards();
        // rewards = 1_000_000 ether, window = 7 days. Add 1 ether so rTs = 1e18 * 7 days / 1_000_000e18 = 0 (truncated)
        dreUSD.mint(address(distributor), 1 ether);
        
        uint256 newRewards = 1 ether;
        uint256 expectedTotalRewards = rewardsBefore + newRewards;
        
        vm.expectEmit(false, false, false, true);
        emit RewardsScheduleUpdated(newRewards, expectedTotalRewards, distributor.cTs(), eTsBefore);
        
        vm.prank(moderator);
        distributor.addRewards();
        assertEq(distributor.eTs(), eTsBefore, "eTs unchanged when rTs rounds to 0");
        assertEq(distributor.rewards(), expectedTotalRewards, "dust added to rewards");
        // Rate = rewards / (eTs - cTs): increased slightly (intended)
        assertGt(distributor.rewards(), rewardsBefore);
    }

    function test_ClaimVested() public {
        vm.prank(moderator);
        distributor.addRewards();
        vm.warp(block.timestamp + 100);
        uint256 period = distributor.eTs() - distributor.cTs();
        uint256 expectedVested = 100 * distributor.rewards() / period;
        uint256 vaultBalanceBefore = dreUSD.balanceOf(vault);
        vm.prank(vault);
        vm.expectEmit(true, false, false, false);
        emit RewardsClaimed(expectedVested);
        distributor.claimVested();
        assertEq(dreUSD.balanceOf(vault), vaultBalanceBefore + expectedVested);
    }

    function test_ClaimVested_MultipleClaims() public {
        vm.prank(moderator);
        distributor.addRewards();
        uint256 period = distributor.eTs() - distributor.cTs();
        vm.warp(block.timestamp + 100);
        uint256 firstClaimExpected = 100 * distributor.rewards() / period;
        vm.prank(vault);
        distributor.claimVested();
        assertEq(dreUSD.balanceOf(vault), firstClaimExpected);
        vm.warp(block.timestamp + 50);
        uint256 secondClaimExpected = 50 * distributor.rewards() / (distributor.eTs() - distributor.cTs());
        vm.prank(vault);
        distributor.claimVested();
        assertEq(dreUSD.balanceOf(vault), firstClaimExpected + secondClaimExpected);
    }

    function test_ClaimVested_NoVestedRewards() public {
        vm.prank(vault);
        distributor.claimVested();
        assertEq(dreUSD.balanceOf(vault), 0);
    }

    function test_ClaimVested_RevertIf_CallerNotVault() public {
        vm.prank(moderator);
        distributor.addRewards();
        vm.warp(block.timestamp + 100);
        vm.prank(user1);
        vm.expectRevert(IdreRewardsDistributor.CallerNotVault.selector);
        distributor.claimVested();
    }

    function test_ClaimVested_VaultCanCall() public {
        vm.prank(moderator);
        distributor.addRewards();
        vm.warp(block.timestamp + 100);
        uint256 expectedVested = 100 * distributor.rewards() / (distributor.eTs() - distributor.cTs());
        vm.prank(vault);
        distributor.claimVested();
        assertEq(dreUSD.balanceOf(vault), expectedVested);
    }

    function test_ClaimVested_CappedAtDistributorBalance() public {
        uint256 limitedBalance = 50 ether;
        vm.prank(address(distributor));
        dreUSD.transfer(user1, INITIAL_DISTRIBUTOR_BALANCE - limitedBalance);
        vm.prank(moderator);
        distributor.addRewards();
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(vault);
        distributor.claimVested();
        assertEq(dreUSD.balanceOf(vault), limitedBalance);
    }

    function test_VestedAmount() public {
        vm.prank(moderator);
        distributor.addRewards();
        vm.warp(block.timestamp + 100);
        uint256 period = distributor.eTs() - distributor.cTs();
        uint256 expected = 100 * distributor.rewards() / period;
        assertEq(distributor.vestedAmount(), expected);
    }

    function test_VestedAmount_BeforeAddRewards() public  {
        assertEq(distributor.vestedAmount(), 0);
    }

    function test_VestedAmount_CappedAtDistributorBalance() public {
        vm.prank(moderator);
        distributor.addRewards();
        vm.warp(block.timestamp + 365 days);
        uint256 vested = distributor.vestedAmount();
        assertEq(vested, INITIAL_DISTRIBUTOR_BALANCE);
    }

    function test_VestedAmount_AfterClaim() public {
        vm.prank(moderator);
        distributor.addRewards();
        vm.warp(block.timestamp + 100);
        vm.prank(vault);
        distributor.claimVested();
        vm.warp(block.timestamp + 50);
        uint256 period = distributor.eTs() - distributor.cTs();
        uint256 expected = 50 * distributor.rewards() / period;
        assertEq(distributor.vestedAmount(), expected);
    }

    function test_VestedAmount_NotInitialized() public  {
        assertEq(distributor.vestedAmount(), 0);
    }

    function testFuzz_VestedAmount(uint256 elapsedSeconds) public {
        elapsedSeconds = bound(elapsedSeconds, 0, 7 days);
        vm.prank(moderator);
        distributor.addRewards();
        vm.warp(block.timestamp + elapsedSeconds);
        uint256 period = distributor.eTs() - distributor.cTs();
        uint256 expected = elapsedSeconds * distributor.rewards() / period;
        assertEq(distributor.vestedAmount(), expected);
    }

    function test_DistributorBalance() public  {
        assertEq(dreUSD.balanceOf(address(distributor)), INITIAL_DISTRIBUTOR_BALANCE);
    }

    function test_VaultBalance() public  {
        assertEq(dreUSD.balanceOf(vault), 0);
    }

    function test_VaultBalance_AfterClaim() public {
        vm.prank(moderator);
        distributor.addRewards();
        vm.warp(block.timestamp + 100);
        uint256 expectedVested = 100 * distributor.rewards() / (distributor.eTs() - distributor.cTs());
        vm.prank(vault);
        distributor.claimVested();
        assertEq(dreUSD.balanceOf(vault), expectedVested);
    }

    function test_Roles()  public {
        assertTrue(distributor.hasRole(DEFAULT_ADMIN_ROLE, defaultAdmin));
        assertTrue(distributor.hasRole(UPGRADER_ROLE, upgrader));
        assertTrue(distributor.hasRole(PAUSER_ROLE, pauser));
        assertTrue(distributor.hasRole(MODERATOR_ROLE, moderator));
        assertFalse(distributor.hasRole(MODERATOR_ROLE, user1));
        assertFalse(distributor.hasRole(UPGRADER_ROLE, defaultAdmin));
        assertFalse(distributor.hasRole(PAUSER_ROLE, defaultAdmin));
    }

    function test_Upgrade() public {
        dreRewardsDistributor newImplementation = new dreRewardsDistributor(address(dreUSD), vault);
        vm.prank(upgrader);
        distributor.upgradeToAndCall(address(newImplementation), "");
        assertEq(distributor.dreUSD(), address(dreUSD));
        assertEq(distributor.vault(), vault);
    }

    function test_Upgrade_RevertIf_NotUpgrader() public {
        dreRewardsDistributor newImplementation = new dreRewardsDistributor(address(dreUSD), vault);
        vm.expectRevert();
        distributor.upgradeToAndCall(address(newImplementation), "");
    }

    function test_Pause() public {
        assertFalse(distributor.paused());
        vm.prank(pauser);
        distributor.pause();
        assertTrue(distributor.paused());
    }

    function test_Unpause() public {
        vm.prank(pauser);
        distributor.pause();
        assertTrue(distributor.paused());
        vm.prank(pauser);
        distributor.unpause();
        assertFalse(distributor.paused());
    }

    function test_Pause_RevertIf_NotPauser() public {
        vm.prank(user1);
        vm.expectRevert();
        distributor.pause();
    }

    function test_Unpause_RevertIf_NotPauser() public {
        vm.prank(pauser);
        distributor.pause();
        vm.prank(user1);
        vm.expectRevert();
        distributor.unpause();
    }

    function test_ClaimVested_RevertIf_Paused() public {
        vm.prank(moderator);
        distributor.addRewards();
        vm.warp(block.timestamp + 100);
        vm.prank(pauser);
        distributor.pause();
        vm.prank(vault);
        vm.expectRevert(EnforcedPause.selector);
        distributor.claimVested();
    }

    function test_ClaimVested_WhenVaultHasNoBalance() public {
        vm.prank(moderator);
        distributor.addRewards();
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(vault);
        distributor.claimVested();
        vm.warp(block.timestamp + 100);
        vm.prank(vault);
        uint256 claimed = distributor.claimVested();
        assertEq(claimed, 0);
    }

    function test_ClaimVested_WithPartialDistributorBalance() public {
        uint256 partialBalance = 30 ether;
        vm.prank(address(distributor));
        dreUSD.transfer(user1, INITIAL_DISTRIBUTOR_BALANCE - partialBalance);
        vm.prank(moderator);
        distributor.addRewards();
        vm.warp(block.timestamp + 100);
        uint256 expectedVested = 100 * distributor.rewards() / (distributor.eTs() - distributor.cTs());
        vm.prank(vault);
        distributor.claimVested();
        assertEq(dreUSD.balanceOf(vault), expectedVested);
    }

    function test_ClaimVested_MultipleTimesInSameBlock() public {
        vm.prank(moderator);
        distributor.addRewards();
        vm.warp(block.timestamp + 100);
        uint256 expectedFirst = 100 * distributor.rewards() / (distributor.eTs() - distributor.cTs());
        vm.prank(vault);
        distributor.claimVested();
        assertEq(dreUSD.balanceOf(vault), expectedFirst);
        vm.prank(vault);
        distributor.claimVested();
        assertEq(dreUSD.balanceOf(vault), expectedFirst);
    }

    function test_VestedAmount_WithVeryLargeTime() public {
        vm.prank(moderator);
        distributor.addRewards();
        vm.warp(block.timestamp + 365 days);
        uint256 vested = distributor.vestedAmount();
        assertEq(vested, INITIAL_DISTRIBUTOR_BALANCE);
    }

    // ============ Fuzz tests for addRewards ============

    /// @dev Fuzz: first addRewards with arbitrary initial balance (bounded to distributor balance).
    function testFuzz_AddRewards_FirstTime(uint256 initialBalance) public {
        initialBalance = bound(initialBalance, 1 ether, INITIAL_DISTRIBUTOR_BALANCE);
        // Drain distributor to user1 (must prank so distributor is msg.sender for transfer)
        vm.startPrank(address(distributor));
        dreUSD.transfer(user1, dreUSD.balanceOf(address(distributor)));
        vm.stopPrank();
        dreUSD.mint(address(this), initialBalance);
        dreUSD.transfer(address(distributor), initialBalance);

        vm.prank(moderator);
        distributor.addRewards();

        assertEq(distributor.rewards(), initialBalance);
        assertEq(distributor.eTs(), block.timestamp + 7 days);
        assertEq(distributor.cTs(), block.timestamp);
        assertEq(dreUSD.balanceOf(address(distributor)), initialBalance);
    }

    /// @dev Fuzz: addRewards then add more rewards after some time; invariants hold.
    function testFuzz_AddRewards_SecondAddition(
        uint256 initialBalance,
        uint256 elapsedSeconds,
        uint256 extraRewards
    ) public {
        initialBalance = bound(initialBalance, 1 ether, INITIAL_DISTRIBUTOR_BALANCE);
        elapsedSeconds = bound(elapsedSeconds, 0, 6 days);
        // Avoid rTs rounding to zero: need extraRewards * window >= rewards => extraRewards >= initialBalance / 7 days
        extraRewards = bound(extraRewards, initialBalance / (7 days) + 1, 10_000 ether);

        vm.startPrank(address(distributor));
        dreUSD.transfer(user1, dreUSD.balanceOf(address(distributor)));
        vm.stopPrank();
        dreUSD.mint(address(this), initialBalance);
        dreUSD.transfer(address(distributor), initialBalance);

        vm.prank(moderator);
        distributor.addRewards();

        vm.warp(block.timestamp + elapsedSeconds);
        dreUSD.mint(address(distributor), extraRewards);

        vm.prank(moderator);
        distributor.addRewards();

        uint256 balance = dreUSD.balanceOf(address(distributor));
        assertGe(balance, distributor.rewards(), "balance must be >= rewards");
        assertGe(distributor.eTs(), distributor.cTs(), "eTs must be >= cTs");
        assertEq(distributor.rewards(), initialBalance + extraRewards - dreUSD.balanceOf(vault));
    }

    /// @dev Fuzz: after addRewards, distributor balance >= rewards (vested sent to vault).
    function testFuzz_AddRewards_Invariant_BalanceGeRewards(
        uint256 initialBalance,
        uint256 elapsedSeconds,
        uint256 extraRewards
    ) public {
        initialBalance = bound(initialBalance, 1 ether, INITIAL_DISTRIBUTOR_BALANCE);
        elapsedSeconds = bound(elapsedSeconds, 0, 7 days);
        // When adding a second time, avoid rTs rounding to zero
        extraRewards = bound(extraRewards, 0, 10_000 ether);
        if (extraRewards > 0 && extraRewards < initialBalance / (7 days) + 1) {
            extraRewards = initialBalance / (7 days) + 1;
        }

        vm.startPrank(address(distributor));
        dreUSD.transfer(user1, dreUSD.balanceOf(address(distributor)));
        vm.stopPrank();
        dreUSD.mint(address(this), initialBalance);
        dreUSD.transfer(address(distributor), initialBalance);

        vm.prank(moderator);
        distributor.addRewards();

        if (extraRewards > 0) {
            vm.warp(block.timestamp + elapsedSeconds);
            dreUSD.mint(address(distributor), extraRewards);
            vm.prank(moderator);
            distributor.addRewards();
        }

        assertGe(
            dreUSD.balanceOf(address(distributor)),
            distributor.rewards(),
            "distributor balance must be >= rewards still vesting"
        );
    }

    /// @dev Fuzz: after addRewards, eTs >= cTs and vest window within expected bounds on reset.
    function testFuzz_AddRewards_Invariant_ETsGteCTs(uint256 initialBalance) public {
        initialBalance = bound(initialBalance, 1 ether, INITIAL_DISTRIBUTOR_BALANCE);
        vm.startPrank(address(distributor));
        dreUSD.transfer(user1, dreUSD.balanceOf(address(distributor)));
        vm.stopPrank();
        dreUSD.mint(address(this), initialBalance);
        dreUSD.transfer(address(distributor), initialBalance);

        vm.prank(moderator);
        distributor.addRewards();

        assertGe(distributor.eTs(), distributor.cTs(), "eTs >= cTs");
        uint256 window = distributor.eTs() - distributor.cTs();
        assertLe(window, distributor.VEST_PERIOD(), "window <= vestPeriod");
    }

    /// @dev Fuzz: multiple addRewards rounds; state stays consistent.
    function testFuzz_AddRewards_MultipleRounds(
        uint256 round1Balance,
        uint256 warp1,
        uint256 round2Extra,
        uint256 warp2,
        uint256 round3Extra
    ) public {
        round1Balance = bound(round1Balance, 1 ether, INITIAL_DISTRIBUTOR_BALANCE);
        warp1 = bound(warp1, 0, 6 days);
        // Avoid rTs rounding to zero in extend branch: newRewards * window >= rewards
        round2Extra = bound(round2Extra, round1Balance / (7 days) + 1, 10_000 ether);
        warp2 = bound(warp2, 0, 6 days);
        round3Extra = bound(round3Extra, (round1Balance + round2Extra) / (7 days) + 1, 10_000 ether);

        vm.startPrank(address(distributor));
        dreUSD.transfer(user1, dreUSD.balanceOf(address(distributor)));
        vm.stopPrank();
        dreUSD.mint(address(this), round1Balance);
        dreUSD.transfer(address(distributor), round1Balance);

        vm.prank(moderator);
        distributor.addRewards();

        vm.warp(block.timestamp + warp1);
        dreUSD.mint(address(distributor), round2Extra);
        vm.prank(moderator);
        distributor.addRewards();

        vm.warp(block.timestamp + warp2);
        dreUSD.mint(address(distributor), round3Extra);
        vm.prank(moderator);
        distributor.addRewards();

        assertGe(dreUSD.balanceOf(address(distributor)), distributor.rewards());
        assertGe(distributor.eTs(), distributor.cTs());
        uint256 totalVestedToVault = dreUSD.balanceOf(vault);
        uint256 totalEverInDistributor = round1Balance + round2Extra + round3Extra;
        assertEq(
            dreUSD.balanceOf(address(distributor)) + totalVestedToVault,
            totalEverInDistributor
        );
    }

    /// @dev Fuzz: addRewards then claimVested; total accounting (distributor + vault) equals input.
    function testFuzz_AddRewards_ThenClaim_Accounting(
        uint256 initialBalance,
        uint256 extraRewards,
        uint256 claimAfterSeconds
    ) public {
        initialBalance = bound(initialBalance, 1 ether, INITIAL_DISTRIBUTOR_BALANCE);
        extraRewards = bound(extraRewards, 0, 10_000 ether);
        if (extraRewards > 0 && extraRewards < initialBalance / (7 days) + 1) {
            extraRewards = initialBalance / (7 days) + 1;
        }
        claimAfterSeconds = bound(claimAfterSeconds, 0, 14 days);

        vm.startPrank(address(distributor));
        dreUSD.transfer(user1, dreUSD.balanceOf(address(distributor)));
        vm.stopPrank();
        dreUSD.mint(address(this), initialBalance);
        dreUSD.transfer(address(distributor), initialBalance);

        vm.prank(moderator);
        distributor.addRewards();

        if (extraRewards > 0) {
            dreUSD.mint(address(distributor), extraRewards);
            vm.prank(moderator);
            distributor.addRewards();
        }

        vm.warp(block.timestamp + claimAfterSeconds);
        vm.prank(vault);
        distributor.claimVested();

        uint256 total = initialBalance + extraRewards;
        assertEq(
            dreUSD.balanceOf(address(distributor)) + dreUSD.balanceOf(vault),
            total,
            "distributor + vault must equal total rewards"
        );
    }

    // ============ Fuzz: vest cap and two-add scenarios ============

    /// @dev Fuzz two adds with arbitrary gap and second amount; vest window never exceeds vestPeriod.
    function testFuzz_AddRewards_TwoAdds_VestWindowAlwaysLeVestPeriod(
        uint256 firstAmount,
        uint256 gapSeconds,
        uint256 secondAmount
    ) public {
        firstAmount = bound(firstAmount, 1 ether, INITIAL_DISTRIBUTOR_BALANCE);
        gapSeconds = bound(gapSeconds, 0, 7 days);
        secondAmount = bound(secondAmount, firstAmount / (7 days) + 1, 50_000 ether);

        vm.startPrank(address(distributor));
        dreUSD.transfer(user1, dreUSD.balanceOf(address(distributor)));
        vm.stopPrank();
        dreUSD.mint(address(this), firstAmount);
        dreUSD.transfer(address(distributor), firstAmount);

        vm.prank(moderator);
        distributor.addRewards();
        vm.warp(block.timestamp + gapSeconds);
        dreUSD.mint(address(distributor), secondAmount);
        vm.prank(moderator);
        distributor.addRewards();

        uint256 window = distributor.eTs() - distributor.cTs();
        assertLe(window, distributor.VEST_PERIOD(), "vest window <= vestPeriod");
        assertGe(dreUSD.balanceOf(address(distributor)), distributor.rewards(), "balance >= rewards");
    }

    /// @dev Fuzz two adds; total accounting: distributor balance + vault = first + second.
    function testFuzz_AddRewards_TwoAdds_Accounting(
        uint256 firstAmount,
        uint256 gapSeconds,
        uint256 secondAmount
    ) public {
        firstAmount = bound(firstAmount, 1 ether, INITIAL_DISTRIBUTOR_BALANCE);
        gapSeconds = bound(gapSeconds, 0, 7 days);
        secondAmount = bound(secondAmount, 0, 50_000 ether);
        if (secondAmount > 0 && secondAmount < firstAmount / (7 days) + 1) {
            secondAmount = firstAmount / (7 days) + 1;
        }

        vm.startPrank(address(distributor));
        dreUSD.transfer(user1, dreUSD.balanceOf(address(distributor)));
        vm.stopPrank();
        dreUSD.mint(address(this), firstAmount);
        dreUSD.transfer(address(distributor), firstAmount);

        vm.prank(moderator);
        distributor.addRewards();
        if (secondAmount > 0) {
            vm.warp(block.timestamp + gapSeconds);
            dreUSD.mint(address(distributor), secondAmount);
            vm.prank(moderator);
            distributor.addRewards();
        }

        uint256 total = firstAmount + secondAmount;
        assertEq(
            dreUSD.balanceOf(address(distributor)) + dreUSD.balanceOf(vault),
            total,
            "distributor + vault = total added"
        );
    }

    /// @dev Fuzz: after first add, warp, second add; then warp and claim. vestedAmount matches linear formula.
    function testFuzz_VestedAmount_LinearFormula(
        uint256 firstAmount,
        uint256 gapBeforeSecond,
        uint256 secondAmount,
        uint256 claimAtSeconds
    ) public {
        firstAmount = bound(firstAmount, 1 ether, INITIAL_DISTRIBUTOR_BALANCE);
        gapBeforeSecond = bound(gapBeforeSecond, 0, 6 days);
        secondAmount = bound(secondAmount, firstAmount / (7 days) + 1, 20_000 ether);
        claimAtSeconds = bound(claimAtSeconds, 0, 14 days);

        vm.startPrank(address(distributor));
        dreUSD.transfer(user1, dreUSD.balanceOf(address(distributor)));
        vm.stopPrank();
        dreUSD.mint(address(this), firstAmount);
        dreUSD.transfer(address(distributor), firstAmount);

        vm.prank(moderator);
        distributor.addRewards();
        vm.warp(block.timestamp + gapBeforeSecond);
        dreUSD.mint(address(distributor), secondAmount);
        vm.prank(moderator);
        distributor.addRewards();

        vm.warp(block.timestamp + claimAtSeconds);
        uint256 rewards = distributor.rewards();
        uint256 cTs = distributor.cTs();
        uint256 eTs = distributor.eTs();
        if (eTs > cTs && block.timestamp > cTs) {
            uint256 end = block.timestamp > eTs ? eTs : block.timestamp;
            uint256 timePassed = end - cTs;
            uint256 expectedVested = timePassed * rewards / (eTs - cTs);
            assertEq(distributor.vestedAmount(), expectedVested, "vestedAmount matches linear formula");
        }
    }

    /// @dev Fuzz "late" second add: warp 4–6 days, second = first/7; should reset to 7 days, rate <= initial rate.
    ///      Uses a vault that calls claimVested() so vested rewards are flushed before second add (remainder 1–3/7 of first).
    function testFuzz_AddRewards_AfterLateWarp_SecondSmall_ResetTo7Days_LowerRate(
        uint256 firstAmount,
        uint256 warpDays
    ) public {
        firstAmount = bound(firstAmount, 7 ether, INITIAL_DISTRIBUTOR_BALANCE);
        warpDays = bound(warpDays, 4, 6); // 4–6 days so remainder is 1–3 days
        uint256 secondAmount = firstAmount / 7;

        MockVaultForAddRewardsTest mockVault = new MockVaultForAddRewardsTest();
        dreRewardsDistributor impl = new dreRewardsDistributor(address(dreUSD), address(mockVault));
        bytes memory initData = abi.encodeWithSelector(
            dreRewardsDistributor.initialize.selector,
            defaultAdmin,
            upgrader,
            pauser
        );
        ERC1967Proxy distProxy = new ERC1967Proxy(address(impl), initData);
        dreRewardsDistributor dist = dreRewardsDistributor(address(distProxy));
        vm.prank(defaultAdmin);
        dist.grantRole(MODERATOR_ROLE, moderator);
        mockVault.setDistributor(address(dist));

        dreUSD.mint(address(this), firstAmount + secondAmount);
        dreUSD.transfer(address(dist), firstAmount);

        vm.prank(moderator);
        dist.addRewards();
        uint256 rateAfterFirst = firstAmount / (7 days);

        vm.warp(block.timestamp + warpDays * 1 days);
        dreUSD.transfer(address(dist), secondAmount);
        vm.prank(moderator);
        dist.addRewards();

        assertEq(dist.eTs() - dist.cTs(), 7 days, "window reset to 7 days");
        uint256 rateAfterSecond = dist.rewards() / (7 days);
        assertLe(rateAfterSecond, rateAfterFirst, "rate per second decreased or same");
    }

    /// @dev Fuzz two consecutive adds with small gap (0–2h); second add often triggers stretch; rate after >= rate before.
    function testFuzz_AddRewards_TwoConsecutive_SmallGap_StretchTo7Days_HigherOrSameRate(
        uint256 amount,
        uint256 gapSeconds
    ) public {
        amount = bound(amount, 1 ether, INITIAL_DISTRIBUTOR_BALANCE / 2);
        gapSeconds = bound(gapSeconds, 0, 2 hours);

        vm.startPrank(address(distributor));
        dreUSD.transfer(user1, dreUSD.balanceOf(address(distributor)));
        vm.stopPrank();
        dreUSD.mint(address(this), amount);
        dreUSD.transfer(address(distributor), amount);

        vm.prank(moderator);
        distributor.addRewards();
        uint256 rateAfterFirst = amount / (7 days);

        vm.warp(block.timestamp + gapSeconds);
        dreUSD.mint(address(distributor), amount);
        vm.prank(moderator);
        distributor.addRewards();

        assertEq(distributor.eTs() - distributor.cTs(), 7 days, "stretched to 7 days");
        uint256 rateAfterSecond = distributor.rewards() / (7 days);
        assertGe(rateAfterSecond, rateAfterFirst, "rate per second higher or same");
    }

    /// @dev Fuzz multiple addRewards rounds (2–4) with random warps and amounts; invariants and accounting.
    /// Bounds are tightened so (eTs - cTs) + rTs cannot overflow (avoids extend with window > vestPeriod).
    function testFuzz_AddRewards_MultipleRounds_VestCapAndAccounting(
        uint256 a1,
        uint256 w1,
        uint256 a2,
        uint256 w2,
        uint256 a3,
        uint256 w3,
        uint256 a4
    ) public {
        uint256 vestPeriodSecs = distributor.VEST_PERIOD();
        // Safe bounds: first amount at least 7 ether so remainder is >= 1 ether after 6 days;
        // later amounts and warps capped so rTs stays bounded and newVestPeriod cannot overflow.
        // Avoid rTs rounding to zero: when non-zero, each extra amount >= (prior total) / 7 days + 1.
        uint256[4] memory amounts;
        amounts[0] = bound(a1, 7 ether, INITIAL_DISTRIBUTOR_BALANCE / 4);
        amounts[1] = bound(a2, 0, 20_000 ether);
        if (amounts[1] > 0 && amounts[1] < amounts[0] / (7 days) + 1) amounts[1] = amounts[0] / (7 days) + 1;
        amounts[2] = bound(a3, 0, 20_000 ether);
        if (amounts[2] > 0 && amounts[2] < (amounts[0] + amounts[1]) / (7 days) + 1) amounts[2] = (amounts[0] + amounts[1]) / (7 days) + 1;
        amounts[3] = bound(a4, 0, 20_000 ether);
        if (amounts[3] > 0 && amounts[3] < (amounts[0] + amounts[1] + amounts[2]) / (7 days) + 1) amounts[3] = (amounts[0] + amounts[1] + amounts[2]) / (7 days) + 1;
        uint256[3] memory warps = [
            bound(w1, 0, 5 days),
            bound(w2, 0, 5 days),
            bound(w3, 0, 5 days)
        ];

        vm.startPrank(address(distributor));
        dreUSD.transfer(user1, dreUSD.balanceOf(address(distributor)));
        vm.stopPrank();

        uint256 totalAdded = 0;
        for (uint256 i = 0; i < 4; i++) {
            if (amounts[i] == 0 && i > 0) break;
            if (i > 0) vm.warp(block.timestamp + warps[i - 1]);
            dreUSD.mint(address(this), amounts[i]);
            dreUSD.transfer(address(distributor), amounts[i]);
            totalAdded += amounts[i];
            vm.prank(moderator);
            distributor.addRewards();
        }

        uint256 window = distributor.eTs() - distributor.cTs();
        assertLe(window, vestPeriodSecs, "window <= vestPeriod");
        assertGe(dreUSD.balanceOf(address(distributor)), distributor.rewards(), "balance >= rewards");
        assertEq(
            dreUSD.balanceOf(address(distributor)) + dreUSD.balanceOf(vault),
            totalAdded,
            "distributor + vault = total added"
        );
    }

    // ============ 7-day vest cap: two adds 1h apart vs add after 6 days ============

    /// @dev When 0 rewards: add first reward, then 1h later add second (same size).
    ///      Second add stretches to max 7 days again with higher reward rate per second.
    function test_AddRewards_TwoConsecutiveAt1h_StretchTo7Days_HigherRate() public {
        uint256 amount = 700 ether; // same amount for first and second add

        vm.startPrank(address(distributor));
        dreUSD.transfer(user1, INITIAL_DISTRIBUTOR_BALANCE - amount);
        vm.stopPrank();

        uint256 t0 = block.timestamp;

        // First add: vest over 7 days
        vm.prank(moderator);
        distributor.addRewards();
        assertEq(distributor.rewards(), amount);
        assertEq(distributor.eTs(), t0 + 7 days);
        uint256 rateAfterFirst = amount / (7 days);

        // 1h later: add same amount again
        vm.warp(t0 + 1 hours);
        uint256 t1h = block.timestamp;
        dreUSD.mint(address(distributor), amount);
        vm.prank(moderator);
        distributor.addRewards();

        // newVestPeriod > 7 days → reset to now + 7 days; total = remaining + amount → higher rate
        assertEq(distributor.cTs(), t1h, "cTs should be set to current time (t1h)");
        // eTs should be t1h + 7 days after addRewards() completes
        // The contract correctly sets eTs to block.timestamp + 7 days after _claimVested() updates cTs to current time
        // After _claimVested() runs, cTs is updated to t1h, then eTs is set to block.timestamp + 7 days = t1h + 7 days
        // Verify the relationship: eTs should be cTs + 7 days (which equals t1h + 7 days)
        assertEq(distributor.eTs() - distributor.cTs(), 7 days, "eTs should be cTs + 7 days");
        // Verify eTs is greater than the first eTs (t0 + 7 days) by exactly 1 hour
        assertEq(distributor.eTs(), distributor.cTs() + 7 days, "stretched to max 7 days again");
        uint256 rateAfterSecond = distributor.rewards() / (7 days);
        assertGt(rateAfterSecond, rateAfterFirst, "reward rate per second increased");
    }

    /// @dev Add reward, wait 6 days, then add second reward = first/7 (same as the 1 day remainder).
    ///      Instead of adding 1 day to vesting end, remainder + new is stretched again over 7 days; rate per second decreases.
    ///      Uses a vault that calls claimVested() so the 6/7 vested is flushed before the second add.
    function test_AddRewards_After6Days_SecondSmall_StretchTo7Days_LowerRate() public {
        uint256 firstAmount = 700 ether;
        uint256 secondAmount = firstAmount / 7; // 1/7 of first (= remainder after 6 days)

        MockVaultForAddRewardsTest mockVault = new MockVaultForAddRewardsTest();
        dreRewardsDistributor impl = new dreRewardsDistributor(address(dreUSD), address(mockVault));
        bytes memory initData = abi.encodeWithSelector(
            dreRewardsDistributor.initialize.selector,
            defaultAdmin,
            upgrader,
            pauser
        );
        ERC1967Proxy distProxy = new ERC1967Proxy(address(impl), initData);
        dreRewardsDistributor dist = dreRewardsDistributor(address(distProxy));
        vm.prank(defaultAdmin);
        dist.grantRole(MODERATOR_ROLE, moderator);
        mockVault.setDistributor(address(dist));

        dreUSD.mint(address(this), firstAmount + secondAmount);
        dreUSD.transfer(address(dist), firstAmount);

        uint256 t0 = block.timestamp;

        // First add: vest over 7 days
        vm.prank(moderator);
        dist.addRewards();
        assertEq(dist.rewards(), firstAmount);
        uint256 rateAfterFirst = firstAmount / (7 days);

        // 6 days pass: 6/7 vested, 1 day left, remainder = firstAmount/7
        vm.warp(t0 + 6 days);
        uint256 t6d = block.timestamp;
        dreUSD.transfer(address(dist), secondAmount);
        vm.prank(moderator);
        dist.addRewards();

        // rTs = secondAmount * (1 day) / (firstAmount/7) = 1 day → newVestPeriod = 2 days < (7 - 1) days → reset
        // Remainder + new stretched over 7 days → lower rate per second
        assertEq(dist.cTs(), t6d);
        assertEq(dist.eTs(), t6d + 7 days, "remainder + new stretched to 7 days again");
        assertEq(dist.rewards(), firstAmount / 7 + secondAmount, "rewards = 1 day remainder + second");
        uint256 rateAfterSecond = dist.rewards() / (7 days);
        assertLt(rateAfterSecond, rateAfterFirst, "reward rate per second decreased");
    }
}
