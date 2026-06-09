// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {DreUSDMock} from "../contracts/mocks/DreUSDMock.sol";
import {dreRewardsDistributorMock} from "../contracts/mocks/dreRewardsDistributorMock.sol";
import {dreUSDs} from "../contracts/dreUSDs.sol";
import {IdreUSDs} from "../contracts/interfaces/IdreUSDs.sol";
import {IdreUSD} from "../contracts/interfaces/IdreUSD.sol";
import {SanctionsListMock} from "../contracts/mocks/SanctionsListMock.sol";

/// @dev Exposes _isBlockedAddress for testing
contract DreUSDsHarness is dreUSDs {
    function isBlockedAddress(address addr) external view returns (bool) {
        return _isBlockedAddress(addr);
    }
}

/**
 * @title dreUSDsTest
 * @dev Comprehensive test suite for dreUSDs ERC4626 vault contract
 */
contract dreUSDsTest is Test {
    dreUSDs public vault;
    dreUSDs public implementation;
    ERC1967Proxy public proxy;
    
    DreUSDMock public dreUSD;
    dreRewardsDistributorMock public rewardsDistributor;
    
    address public defaultAdmin;
    address public upgrader;
    address public user1;
    address public user2;
    address public vaultAddress;
    
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    
    uint256 public constant INITIAL_USER_BALANCE = 10000 ether;
    
    error EnforcedPause();
    uint256 public constant REWARD_VAULT_BALANCE = 1000000 ether;
    
    event RewardsDistributorUpdated(address indexed oldDistributor, address indexed newDistributor);
    event ShareOFTAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);
    event ExcessDreUSDWithdrawn(address indexed to, uint256 amount);
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    
    function setUp() public {
        // Deploy mock dreUSD token implementing IdreUSD interface
        dreUSD = new DreUSDMock();
        // Allow this test contract to mint/burn in the mock
        dreUSD.grantRole(dreUSD.MANAGER_ROLE(), address(this));
        
        // Setup addresses
        defaultAdmin = makeAddr("defaultAdmin");
        upgrader = makeAddr("upgrader");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        vaultAddress = makeAddr("vault");
        
        // Deploy implementation and proxy first so we can pass the vault to the mock
        implementation = new dreUSDs();
        bytes memory initData = abi.encodeWithSelector(
            dreUSDs.initialize.selector,
            IERC20(address(dreUSD)),
            defaultAdmin
        );
        proxy = new ERC1967Proxy(address(implementation), initData);
        vault = dreUSDs(address(proxy));
        
        // Deploy mock rewards distributor (vault receives claimed rewards)
        rewardsDistributor = new dreRewardsDistributorMock(address(dreUSD), address(vault));
        
        // Fund the rewards distributor (mock holds tokens and transfers to vault on claimVested)
        dreUSD.mint(address(rewardsDistributor), REWARD_VAULT_BALANCE);

        // Set rewards distributor
        vm.prank(defaultAdmin);
        vault.setRewardsDistributor(address(rewardsDistributor));
        
        // Setup roles
        vm.startPrank(defaultAdmin);
        vault.grantRole(UPGRADER_ROLE, upgrader);
        vm.stopPrank();
        
        // Fund users with dreUSD
        dreUSD.mint(user1, INITIAL_USER_BALANCE);
        dreUSD.mint(user2, INITIAL_USER_BALANCE);
        
        // Approve vault to spend user tokens
        vm.prank(user1);
        dreUSD.approve(address(vault), type(uint256).max);
        vm.prank(user2);
        dreUSD.approve(address(vault), type(uint256).max);
    }
    
    // ============ Initialization Tests ============
    
    function test_Initialize() public {
        assertEq(vault.name(), "dreUSDs");
        assertEq(vault.symbol(), "dreUSDs");
        assertEq(vault.decimals(), 18);
        assertEq(vault.asset(), address(dreUSD));
        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE, defaultAdmin));
        assertTrue(vault.hasRole(UPGRADER_ROLE, defaultAdmin));
    }
    
    function test_Initialize_RevertIf_AlreadyInitialized() public {
        vm.expectRevert();
        vault.initialize(IERC20(address(dreUSD)), defaultAdmin);
    }

    function test_Initialize_RevertIf_AssetIsZeroAddress() public {
        bytes memory initData = abi.encodeWithSelector(
            dreUSDs.initialize.selector,
            IERC20(address(0)),
            defaultAdmin
        );
        vm.expectRevert(IdreUSDs.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_Initialize_RevertIf_DefaultAdminIsZeroAddress() public {
        bytes memory initData = abi.encodeWithSelector(
            dreUSDs.initialize.selector,
            IERC20(address(dreUSD)),
            address(0)
        );
        vm.expectRevert(IdreUSDs.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }
    
    // ============ setRewardsDistributor Tests ============
    
    function test_SetRewardsDistributor() public {
        dreRewardsDistributorMock newDistributor = new dreRewardsDistributorMock(address(dreUSD), vaultAddress);
        
        vm.prank(defaultAdmin);
        vm.expectEmit(true, true, false, false);
        emit RewardsDistributorUpdated(address(rewardsDistributor), address(newDistributor));
        vault.setRewardsDistributor(address(newDistributor));
        
        assertEq(vault.rewardsDistributor(), address(newDistributor));
    }
    
    function test_SetRewardsDistributor_RevertIf_NotAdmin() public {
        dreRewardsDistributorMock newDistributor = new dreRewardsDistributorMock(address(dreUSD), vaultAddress);
        
        vm.expectRevert();
        vault.setRewardsDistributor(address(newDistributor));
    }
    
    function test_SetRewardsDistributor_RevertIf_ZeroAddress() public {
        vm.prank(defaultAdmin);
        vm.expectRevert(IdreUSDs.ZeroAddress.selector);
        vault.setRewardsDistributor(address(0));
    }

    function test_SetRewardsDistributor_RevertIf_SameValue() public {
        vm.prank(defaultAdmin);
        vm.expectRevert(IdreUSDs.SameRewardsDistributor.selector);
        vault.setRewardsDistributor(address(rewardsDistributor));
    }

    /// @dev Switching distributor claims remaining vested from old and adds to vault so totalAssets does not drop.
    function test_SetRewardsDistributor_ClaimsFromOldDistributorBeforeSwitch() public {
        uint256 depositAmount = 1000 ether;
        uint256 vestedInOld = 50 ether;
        vm.prank(user1);
        vault.deposit(depositAmount, user1);
        rewardsDistributor.setVestedAmount(vestedInOld);
        rewardsDistributor.setClaimAmount(vestedInOld);
        dreUSD.mint(address(rewardsDistributor), vestedInOld);

        uint256 totalAssetsBefore = vault.totalAssets();
        assertEq(totalAssetsBefore, depositAmount + vestedInOld, "totalAssets includes vested");

        dreRewardsDistributorMock newDistributor = new dreRewardsDistributorMock(address(dreUSD), vaultAddress);
        vm.prank(defaultAdmin);
        vault.setRewardsDistributor(address(newDistributor));

        assertEq(vault.rewardsDistributor(), address(newDistributor));
        assertEq(vault.totalAssets(), totalAssetsBefore, "totalAssets unchanged after switch");
        assertEq(dreUSD.balanceOf(address(vault)), depositAmount + vestedInOld, "vault received claimed rewards");
    }

    function test_SetShareOFTAdapter() public {
        address adapter = makeAddr("shareOFTAdapter");
        vm.prank(defaultAdmin);
        vm.expectEmit(true, true, true, true);
        emit ShareOFTAdapterUpdated(address(0), adapter);
        vault.setShareOFTAdapter(adapter);
        assertEq(vault.shareOFTAdapter(), adapter);
        address adapter2 = makeAddr("shareOFTAdapter2");
        vm.prank(defaultAdmin);
        vm.expectEmit(true, true, true, true);
        emit ShareOFTAdapterUpdated(adapter, adapter2);
        vault.setShareOFTAdapter(adapter2);
        assertEq(vault.shareOFTAdapter(), adapter2);
    }

    function test_SetShareOFTAdapter_RevertIf_NotAdmin() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.setShareOFTAdapter(makeAddr("adapter"));
    }

    /// @dev Bridge-in: transfer from shareOFTAdapter to a frozen receiver must not revert so the LayerZero message is not trapped.
    function test_Transfer_FromShareOFTAdapter_ToBlockedReceiver_Succeeds() public {
        address adapter = makeAddr("shareOFTAdapter");
        vm.prank(defaultAdmin);
        vault.setShareOFTAdapter(adapter);

        vm.prank(user1);
        vault.deposit(1000 ether, user1);
        vm.prank(user1);
        vault.transfer(adapter, 500 ether);

        dreUSD.freeze(user2);
        assertTrue(IdreUSD(address(vault.asset())).isBlockedAddress(user2));

        vm.prank(adapter);
        vault.transfer(user2, 500 ether);
        assertEq(vault.balanceOf(user2), 500 ether);
        assertEq(vault.balanceOf(adapter), 0);
    }
    
    // ============ totalAssets Tests ============
    
    function test_TotalAssets_IncludesVestedRewards() public {
        uint256 vaultBalance = 100 ether;
        uint256 vestedRewards = 50 ether;
        
        // Fund vault via deposit so virtual balance is updated
        vm.prank(user1);
        vault.deposit(vaultBalance, user1);
        rewardsDistributor.setVestedAmount(vestedRewards);
        
        uint256 totalAssets = vault.totalAssets();
        assertEq(totalAssets, vaultBalance + vestedRewards);
    }
    
    function test_TotalAssets_OnlyVaultBalance() public {
        uint256 vaultBalance = 100 ether;
        
        // Fund vault via deposit so virtual balance is updated
        vm.prank(user1);
        vault.deposit(vaultBalance, user1);
        rewardsDistributor.setVestedAmount(0);
        
        uint256 totalAssets = vault.totalAssets();
        assertEq(totalAssets, vaultBalance);
    }
    
    function test_TotalAssets_OnlyVestedRewards() public {
        uint256 vestedRewards = 50 ether;
        
        // No vault balance
        // Set vested amount in mock
        rewardsDistributor.setVestedAmount(vestedRewards);
        
        uint256 totalAssets = vault.totalAssets();
        assertEq(totalAssets, vestedRewards);
    }
    
    // ============ Deposit Tests ============
    
    function test_Deposit() public {
        uint256 depositAmount = 1000 ether;
        
        uint256 sharesBefore = vault.balanceOf(user1);
        uint256 assetsBefore = dreUSD.balanceOf(address(vault));
        
        vm.prank(user1);
        uint256 shares = vault.deposit(depositAmount, user1);
        
        assertEq(vault.balanceOf(user1), sharesBefore + shares);
        assertEq(dreUSD.balanceOf(address(vault)), assetsBefore + depositAmount);
        assertEq(dreUSD.balanceOf(user1), INITIAL_USER_BALANCE - depositAmount);
        assertEq(shares, depositAmount); // 1:1 initially
    }
    
    function test_Deposit_ClaimsRewards() public {
        uint256 rewardAmount = 100 ether;
        rewardsDistributor.setClaimAmount(rewardAmount);
        
        uint256 depositAmount = 1000 ether;
        
        uint256 vaultBalanceBefore = dreUSD.balanceOf(address(vault));
        
        vm.prank(user1);
        vault.deposit(depositAmount, user1);
        
        // Vault should have received the reward claim
        assertEq(dreUSD.balanceOf(address(vault)), vaultBalanceBefore + depositAmount + rewardAmount);
    }
    
    function test_Deposit_MultipleUsers() public {
        uint256 deposit1 = 1000 ether;
        uint256 deposit2 = 500 ether;
        
        vm.prank(user1);
        uint256 shares1 = vault.deposit(deposit1, user1);
        
        vm.prank(user2);
        uint256 shares2 = vault.deposit(deposit2, user2);
        
        assertEq(vault.balanceOf(user1), shares1);
        assertEq(vault.balanceOf(user2), shares2);
        assertEq(dreUSD.balanceOf(address(vault)), deposit1 + deposit2);
    }
    
    function test_Deposit_ToDifferentReceiver() public {
        uint256 depositAmount = 1000 ether;
        
        vm.prank(user1);
        uint256 shares = vault.deposit(depositAmount, user2);
        
        assertEq(vault.balanceOf(user2), shares);
        assertEq(vault.balanceOf(user1), 0);
        assertEq(dreUSD.balanceOf(user1), INITIAL_USER_BALANCE - depositAmount);
    }
    
    // ============ Mint Tests ============
    
    function test_Mint() public {
        uint256 sharesToMint = 1000 ether;
        
        uint256 assetsBefore = dreUSD.balanceOf(address(vault));
        
        vm.prank(user1);
        uint256 assets = vault.mint(sharesToMint, user1);
        
        assertEq(vault.balanceOf(user1), sharesToMint);
        assertEq(dreUSD.balanceOf(address(vault)), assetsBefore + assets);
        assertEq(assets, sharesToMint); // 1:1 initially
    }
    
    function test_Mint_ClaimsRewards() public {
        uint256 rewardAmount = 50 ether;
        rewardsDistributor.setClaimAmount(rewardAmount);
        
        uint256 sharesToMint = 1000 ether;
        
        uint256 vaultBalanceBefore = dreUSD.balanceOf(address(vault));
        
        vm.prank(user1);
        vault.mint(sharesToMint, user1);
        
        // Vault should have received the reward claim
        assertGt(dreUSD.balanceOf(address(vault)), vaultBalanceBefore + sharesToMint);
    }
    
    // ============ Withdraw Tests ============
    
    function test_Withdraw() public {
        // First deposit
        uint256 depositAmount = 1000 ether;
        vm.prank(user1);
        vault.deposit(depositAmount, user1);
        
        uint256 withdrawAmount = 500 ether;
        uint256 sharesBefore = vault.balanceOf(user1);
        uint256 userBalanceBefore = dreUSD.balanceOf(user1);
        
        vm.prank(user1);
        uint256 shares = vault.withdraw(withdrawAmount, user1, user1);
        
        assertEq(vault.balanceOf(user1), sharesBefore - shares);
        assertEq(dreUSD.balanceOf(user1), userBalanceBefore + withdrawAmount);
        assertEq(shares, withdrawAmount); // 1:1 initially
    }
    
    function test_Withdraw_ClaimsRewards() public {
        // First deposit
        uint256 depositAmount = 1000 ether;
        vm.prank(user1);
        vault.deposit(depositAmount, user1);
        
        uint256 rewardAmount = 50 ether;
        rewardsDistributor.setClaimAmount(rewardAmount);
        
        uint256 withdrawAmount = 500 ether;
        uint256 vaultBalanceBefore = dreUSD.balanceOf(address(vault));
        
        vm.prank(user1);
        vault.withdraw(withdrawAmount, user1, user1);
        
        // Vault should have received the reward claim
        // Final balance = initial balance + reward - assets withdrawn
        assertEq(dreUSD.balanceOf(address(vault)), vaultBalanceBefore + rewardAmount - withdrawAmount);
    }
    
    function test_Withdraw_WithAllowance() public {
        // First deposit
        uint256 depositAmount = 1000 ether;
        vm.prank(user1);
        vault.deposit(depositAmount, user1);
        
        uint256 withdrawAmount = 500 ether;
        uint256 shares = vault.previewWithdraw(withdrawAmount);
        
        // Approve user2 to withdraw on behalf of user1
        vm.prank(user1);
        vault.approve(user2, shares);
        
        vm.prank(user2);
        vault.withdraw(withdrawAmount, user2, user1);
        
        assertEq(dreUSD.balanceOf(user2), INITIAL_USER_BALANCE + withdrawAmount);
    }
    
    // ============ Redeem Tests ============
    
    function test_Redeem() public {
        // First deposit
        uint256 depositAmount = 1000 ether;
        vm.prank(user1);
        uint256 sharesDeposited = vault.deposit(depositAmount, user1);
        
        uint256 sharesToRedeem = sharesDeposited / 2;
        uint256 userBalanceBefore = dreUSD.balanceOf(user1);
        
        vm.prank(user1);
        uint256 assets = vault.redeem(sharesToRedeem, user1, user1);
        
        assertEq(vault.balanceOf(user1), sharesDeposited - sharesToRedeem);
        assertEq(dreUSD.balanceOf(user1), userBalanceBefore + assets);
        assertEq(assets, sharesToRedeem); // 1:1 initially
    }
    
    function test_Redeem_ClaimsRewards() public {
        // First deposit
        uint256 depositAmount = 1000 ether;
        vm.prank(user1);
        vault.deposit(depositAmount, user1);
        
        uint256 rewardAmount = 50 ether;
        rewardsDistributor.setClaimAmount(rewardAmount);
        
        uint256 sharesToRedeem = 500 ether;
        uint256 assetsToWithdraw = vault.previewRedeem(sharesToRedeem);
        uint256 vaultBalanceBefore = dreUSD.balanceOf(address(vault));
        
        vm.prank(user1);
        vault.redeem(sharesToRedeem, user1, user1);
        
        // Vault should have received the reward claim
        // Final balance = initial balance + reward - assets withdrawn
        assertEq(dreUSD.balanceOf(address(vault)), vaultBalanceBefore + rewardAmount - assetsToWithdraw);
    }
    
    // ============ Preview Functions Tests ============
    
    function test_PreviewDeposit() public {
        uint256 assets = 1000 ether;
        uint256 shares = vault.previewDeposit(assets);
        
        // Initially 1:1
        assertEq(shares, assets);
    }
    
    function test_PreviewMint() public {
        uint256 shares = 1000 ether;
        uint256 assets = vault.previewMint(shares);
        
        // Initially 1:1
        assertEq(assets, shares);
    }
    
    function test_PreviewWithdraw() public {
        // First deposit
        uint256 depositAmount = 1000 ether;
        vm.prank(user1);
        vault.deposit(depositAmount, user1);
        
        uint256 assets = 500 ether;
        uint256 shares = vault.previewWithdraw(assets);
        
        // Initially 1:1
        assertEq(shares, assets);
    }
    
    function test_PreviewRedeem() public {
        // First deposit
        uint256 depositAmount = 1000 ether;
        vm.prank(user1);
        vault.deposit(depositAmount, user1);
        
        uint256 shares = 500 ether;
        uint256 assets = vault.previewRedeem(shares);
        
        // Initially 1:1
        assertEq(assets, shares);
    }
    
    // ============ Max Functions Tests ============
    
    function test_MaxDeposit() public  {
        uint256 maxDeposit = vault.maxDeposit(user1);
        assertEq(maxDeposit, type(uint256).max);
    }
    
    function test_MaxMint() public  {
        uint256 maxMint = vault.maxMint(user1);
        assertEq(maxMint, type(uint256).max);
    }
    
    function test_MaxWithdraw() public {
        // Initially 0
        uint256 maxWithdraw = vault.maxWithdraw(user1);
        assertEq(maxWithdraw, 0);
        
        // After deposit
        uint256 depositAmount = 1000 ether;
        vm.prank(user1);
        vault.deposit(depositAmount, user1);
        
        maxWithdraw = vault.maxWithdraw(user1);
        assertEq(maxWithdraw, depositAmount);
    }
    
    function test_MaxRedeem() public {
        // Initially 0
        uint256 maxRedeem = vault.maxRedeem(user1);
        assertEq(maxRedeem, 0);
        
        // After deposit
        uint256 depositAmount = 1000 ether;
        vm.prank(user1);
        uint256 shares = vault.deposit(depositAmount, user1);
        
        maxRedeem = vault.maxRedeem(user1);
        assertEq(maxRedeem, shares);
    }

    // ============ _isBlockedAddress Tests ============

    /// @dev _isBlockedAddress returns true when the address is frozen in dreUSD (validateAddress reverts).
    function test_IsBlockedAddress_ReturnsTrue_WhenFrozen() public {
        DreUSDsHarness harnessImpl = new DreUSDsHarness();
        bytes memory initData = abi.encodeWithSelector(
            dreUSDs.initialize.selector,
            IERC20(address(dreUSD)),
            defaultAdmin
        );
        ERC1967Proxy harnessProxy = new ERC1967Proxy(address(harnessImpl), initData);
        DreUSDsHarness vaultHarness = DreUSDsHarness(address(harnessProxy));

        assertFalse(vaultHarness.isBlockedAddress(user1), "user1 not blocked");
        assertFalse(vaultHarness.isBlockedAddress(user2), "user2 not blocked before freeze");

        dreUSD.freeze(user2);
        assertTrue(vaultHarness.isBlockedAddress(user2), "_isBlockedAddress must return true when frozen");
        assertFalse(vaultHarness.isBlockedAddress(user1), "user1 still not blocked");
    }

    /// @dev _isBlockedAddress returns true when the address is sanctioned in dreUSD (validateAddress reverts).
    function test_IsBlockedAddress_ReturnsTrue_WhenSanctioned() public {
        SanctionsListMock sanctionsList = new SanctionsListMock();
        vm.prank(defaultAdmin);
        dreUSD.setSanctionsList(address(sanctionsList));
        sanctionsList.setSanctioned(user2, true);

        DreUSDsHarness harnessImpl = new DreUSDsHarness();
        bytes memory initData = abi.encodeWithSelector(
            dreUSDs.initialize.selector,
            IERC20(address(dreUSD)),
            defaultAdmin
        );
        ERC1967Proxy harnessProxy = new ERC1967Proxy(address(harnessImpl), initData);
        DreUSDsHarness vaultHarness = DreUSDsHarness(address(harnessProxy));

        assertTrue(vaultHarness.isBlockedAddress(user2), "_isBlockedAddress must return true when sanctioned");
        assertFalse(vaultHarness.isBlockedAddress(user1), "user1 still not blocked");
    }

    /// @dev When _isBlockedAddress returns true for receiver, maxDeposit and maxMint return 0.
    function test_MaxDeposit_MaxMint_ReturnZero_WhenReceiverBlocked() public {
        assertGt(vault.maxDeposit(user2), 0);
        assertGt(vault.maxMint(user2), 0);
        dreUSD.freeze(user2);
        assertEq(vault.maxDeposit(user2), 0, "maxDeposit must be 0 for blocked receiver");
        assertEq(vault.maxMint(user2), 0, "maxMint must be 0 for blocked receiver");
    }

    /// @dev When _isBlockedAddress returns true for owner, maxWithdraw and maxRedeem return 0.
    function test_MaxWithdraw_MaxRedeem_ReturnZero_WhenOwnerBlocked() public {
        vm.prank(user2);
        vault.deposit(1000 ether, user2);
        assertGt(vault.maxWithdraw(user2), 0);
        assertGt(vault.maxRedeem(user2), 0);
        dreUSD.freeze(user2);
        assertEq(vault.maxWithdraw(user2), 0, "maxWithdraw must be 0 for blocked owner");
        assertEq(vault.maxRedeem(user2), 0, "maxRedeem must be 0 for blocked owner");
    }
    
    // ============ Pause / Unpause Tests ============
    
    function test_Pause() public {
        assertFalse(vault.paused());
        
        vm.prank(defaultAdmin);
        vault.pause();
        
        assertTrue(vault.paused());
    }
    
    function test_Unpause() public {
        vm.prank(defaultAdmin);
        vault.pause();
        assertTrue(vault.paused());
        
        vm.prank(defaultAdmin);
        vault.unpause();
        
        assertFalse(vault.paused());
    }
    
    function test_Pause_RevertIf_NotPauser() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.pause();
    }
    
    function test_Unpause_RevertIf_NotPauser() public {
        vm.prank(defaultAdmin);
        vault.pause();
        
        vm.prank(user1);
        vm.expectRevert();
        vault.unpause();
    }

    /// @dev ERC-4626: when deposits are disabled (paused), maxDeposit/maxMint MUST return 0.
    function test_MaxDeposit_ReturnsZeroWhenPaused() public {
        vm.prank(defaultAdmin);
        vault.pause();
        assertEq(vault.maxDeposit(user1), 0);
        assertEq(vault.maxMint(user1), 0);
    }

    /// @dev ERC-4626: when withdrawals are disabled (paused), maxWithdraw/maxRedeem MUST return 0.
    function test_MaxWithdraw_MaxRedeem_ReturnZeroWhenPaused() public {
        vm.prank(user1);
        vault.deposit(1000 ether, user1);
        vm.prank(defaultAdmin);
        vault.pause();
        assertEq(vault.maxWithdraw(user1), 0);
        assertEq(vault.maxRedeem(user1), 0);
    }
    
    /// @dev When paused, maxDeposit returns 0 so deposit reverts with ERC4626ExceededMaxDeposit (ERC-4626 compliant).
    function test_Deposit_RevertIf_Paused() public {
        vm.prank(defaultAdmin);
        vault.pause();
        uint256 depositAmount = 1000 ether;
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, user1, depositAmount, 0));
        vault.deposit(depositAmount, user1);
    }

    /// @dev When paused, maxWithdraw returns 0 so withdraw reverts with ERC4626ExceededMaxWithdraw.
    function test_Withdraw_RevertIf_Paused() public {
        uint256 depositAmount = 1000 ether;
        vm.prank(user1);
        vault.deposit(depositAmount, user1);
        vm.prank(defaultAdmin);
        vault.pause();
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector, user1, 500 ether, 0));
        vault.withdraw(500 ether, user1, user1);
    }

    /// @dev When paused, maxMint returns 0 so mint reverts with ERC4626ExceededMaxMint.
    function test_Mint_RevertIf_Paused() public {
        vm.prank(defaultAdmin);
        vault.pause();
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxMint.selector, user1, 1000 ether, 0));
        vault.mint(1000 ether, user1);
    }

    /// @dev When paused, maxRedeem returns 0 so redeem reverts with ERC4626ExceededMaxRedeem.
    function test_Redeem_RevertIf_Paused() public {
        uint256 depositAmount = 1000 ether;
        vm.prank(user1);
        uint256 shares = vault.deposit(depositAmount, user1);
        vm.prank(defaultAdmin);
        vault.pause();
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, user1, shares, 0));
        vault.redeem(shares, user1, user1);
    }
    
    // ============ Access Control Tests ============
    
    function test_Roles() public  {
        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE, defaultAdmin));
        assertTrue(vault.hasRole(UPGRADER_ROLE, defaultAdmin));
        assertTrue(vault.hasRole(UPGRADER_ROLE, upgrader));
        assertTrue(vault.hasRole(PAUSER_ROLE, defaultAdmin));
        assertFalse(vault.hasRole(UPGRADER_ROLE, user1));
    }
    
    // ============ Upgrade Tests ============
    
    function test_Upgrade() public {
        // Deploy new implementation
        dreUSDs newImplementation = new dreUSDs();
        
        // Upgrade
        vm.prank(upgrader);
        vault.upgradeToAndCall(address(newImplementation), "");
        
        // Verify vault still works
        assertEq(vault.name(), "dreUSDs");
        assertEq(vault.asset(), address(dreUSD));
        assertEq(vault.rewardsDistributor(), address(rewardsDistributor));
    }
    
    function test_Upgrade_RevertIf_NotUpgrader() public {
        dreUSDs newImplementation = new dreUSDs();
        
        vm.expectRevert();
        vault.upgradeToAndCall(address(newImplementation), "");
    }
    
    // ============ Edge Cases ============
    
    function test_Deposit_ZeroAmount() public {
        vm.prank(user1);
        uint256 shares = vault.deposit(0, user1);
        assertEq(shares, 0);
        assertEq(vault.balanceOf(user1), 0);
    }

    
    function test_Withdraw_ZeroAmount() public {
        // First deposit
        uint256 depositAmount = 1000 ether;
        vm.prank(user1);
        vault.deposit(depositAmount, user1);
        
        vm.prank(user1);
        uint256 shares = vault.withdraw(0, user1, user1);
        
        assertEq(shares, 0);
        assertEq(vault.balanceOf(user1), depositAmount);
    }
    
    function test_TotalAssets_WithRewardsAfterDeposit() public {
        // Deposit first
        uint256 depositAmount = 1000 ether;
        vm.prank(user1);
        vault.deposit(depositAmount, user1);
        
        // Set vested rewards
        uint256 vestedRewards = 100 ether;
        rewardsDistributor.setVestedAmount(vestedRewards);
        
        uint256 totalAssets = vault.totalAssets();
        assertEq(totalAssets, depositAmount + vestedRewards);
    }
    
    function test_Deposit_AfterRewardsAccrued() public {
        // Set some vested rewards
        uint256 vestedRewards = 50 ether;
        rewardsDistributor.setVestedAmount(vestedRewards);
        
        // Deposit
        uint256 depositAmount = 1000 ether;
        vm.prank(user1);
        uint256 shares = vault.deposit(depositAmount, user1);
        
        // Shares should be based on totalAssets (deposit + vested)
        // Since vested rewards increase totalAssets, shares should be less than deposit
        assertLt(shares, depositAmount);
    }
    
    function test_Withdraw_AllShares() public {
        // Deposit
        uint256 depositAmount = 1000 ether;
        vm.prank(user1);
        uint256 shares = vault.deposit(depositAmount, user1);
        
        // Withdraw all
        vm.prank(user1);
        vault.redeem(shares, user1, user1);
        
        assertEq(vault.balanceOf(user1), 0);
        assertEq(dreUSD.balanceOf(user1), INITIAL_USER_BALANCE);
    }
    
    /// @dev Best-effort claim: when distributor reverts (e.g. paused), deposit/withdraw still succeed; claim contributes 0.
    function test_ClaimRewards_DepositWithdrawSucceedWhenClaimFails() public {
        rewardsDistributor.setPaused(true);

        uint256 depositAmount = 1000 ether;
        vm.prank(user1);
        dreUSD.approve(address(vault), depositAmount);

        vm.prank(user1);
        uint256 shares = vault.deposit(depositAmount, user1);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(user1), shares);

        vm.prank(user1);
        uint256 withdrawn = vault.withdraw(depositAmount, user1, user1);
        assertEq(withdrawn, depositAmount);
        assertEq(vault.balanceOf(user1), 0);
    }

    // ============ Excess dreUSD (donation recovery) Tests ============

    function test_ExcessDreUSD_ReturnsZero_WhenNoDonation() public {
        assertEq(vault.excessDreUSD(), 0);
        vm.prank(user1);
        vault.deposit(1000 ether, user1);
        assertEq(vault.excessDreUSD(), 0);
    }

    function test_ExcessDreUSD_ReturnsDonatedAmount() public {
        vm.prank(user1);
        vault.deposit(1000 ether, user1);
        uint256 donation = 100 ether;
        vm.prank(user1);
        dreUSD.transfer(address(vault), donation);
        assertEq(vault.excessDreUSD(), donation);
        assertEq(dreUSD.balanceOf(address(vault)), 1000 ether + donation);
    }

    function test_WithdrawExcessDreUSD_TransfersExcessToRecipient() public {
        vm.prank(user1);
        vault.deposit(1000 ether, user1);
        uint256 donation = 100 ether;
        vm.prank(user1);
        dreUSD.transfer(address(vault), donation);
        address recipient = makeAddr("recipient");
        uint256 totalAssetsBefore = vault.totalAssets();
        vm.prank(defaultAdmin);
        vm.expectEmit(true, true, true, true);
        emit ExcessDreUSDWithdrawn(recipient, donation);
        uint256 amount = vault.withdrawExcessDreUSD(recipient);
        assertEq(amount, donation);
        assertEq(dreUSD.balanceOf(recipient), donation);
        assertEq(dreUSD.balanceOf(address(vault)), 1000 ether);
        assertEq(vault.totalAssets(), totalAssetsBefore, "totalAssets unchanged");
        assertEq(vault.excessDreUSD(), 0);
    }

    function test_WithdrawExcessDreUSD_RevertIf_NotAdmin() public {
        vm.prank(user1);
        vault.deposit(1000 ether, user1);
        vm.prank(user1);
        dreUSD.transfer(address(vault), 100 ether);
        vm.prank(user1);
        vm.expectRevert();
        vault.withdrawExcessDreUSD(user1);
    }

    function test_WithdrawExcessDreUSD_RevertIf_ZeroAddress() public {
        vm.prank(defaultAdmin);
        vm.expectRevert(IdreUSDs.ZeroAddress.selector);
        vault.withdrawExcessDreUSD(address(0));
    }

    function test_WithdrawExcessDreUSD_RevertIf_ZeroExcess() public {
        vm.prank(defaultAdmin);
        vm.expectRevert(IdreUSDs.ZeroExcess.selector);
        vault.withdrawExcessDreUSD(defaultAdmin);
    }
}
