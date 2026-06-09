// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {dreAaveAdapter} from "../contracts/dreAaveAdapter.sol";
import {IAaveV3Adapter} from "../contracts/interfaces/IAaveV3Adapter.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";
import {AaveV3PoolMock} from "../contracts/mocks/AaveV3PoolMock.sol";
import {AaveV3PoolMockWithConfigurableAToken} from "../contracts/mocks/AaveV3PoolMockWithConfigurableAToken.sol";

/**
 * @title DreAaveAdapterTest
 * @dev Test suite for dreAaveAdapter contract
 */
contract DreAaveAdapterTest is Test {
    dreAaveAdapter public adapter;
    dreAaveAdapter public implementation;
    ERC1967Proxy public proxy;
    
    MockERC20 public usdc;
    MockERC20 public aUsdc;
    AaveV3PoolMock public aavePool;
    address public vault;
    address public admin;
    address public withdrawer;
    address public upgrader;
    address public manager;
    address public unauthorized;
    address public recipient;
    
    bytes32 public constant WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    
    uint256 public constant INITIAL_VAULT_BALANCE = 1_000_000e6; // 1M USDC worth of aUSDC
    uint256 public constant WITHDRAW_AMOUNT = 100_000e6; // 100k USDC
    
    event Withdrawn(address indexed to, uint256 amount);
    event VaultUpdated(address indexed oldVault, address indexed newVault);
    event TokenRecovered(address indexed token, address indexed recipient, uint256 amount);
    
    function setUp() public {
        _setupAddresses();
        _deployTokens();
        _deployAavePool();
        _deployAdapter();
        _setupRoles();
        _fundVault();
    }
    
    function _setupAddresses() internal {
        admin = makeAddr("admin");
        withdrawer = makeAddr("withdrawer");
        upgrader = makeAddr("upgrader");
        manager = makeAddr("manager");
        unauthorized = makeAddr("unauthorized");
        vault = makeAddr("vault");
        recipient = makeAddr("recipient");
    }
    
    function _deployTokens() internal {
        usdc = new MockERC20("USDC", "USDC", 6);
        aUsdc = new MockERC20("aUSDC", "aUSDC", 6);
    }
    
    function _deployAavePool() internal {
        aavePool = new AaveV3PoolMock(address(usdc), address(aUsdc));
    }
    
    function _deployAdapter() internal {
        implementation = new dreAaveAdapter();
        bytes memory initData = abi.encodeWithSelector(
            dreAaveAdapter.initialize.selector,
            address(aavePool),
            address(usdc),
            vault,
            admin,
            upgrader,
            manager
        );
        proxy = new ERC1967Proxy(address(implementation), initData);
        adapter = dreAaveAdapter(address(proxy));
    }
    
    function _setupRoles() internal {
        vm.startPrank(admin);
        // Only dreUSDManager may call withdraw(); set to withdrawer for tests
        adapter.setDreUSDManager(withdrawer);
        vm.stopPrank();
    }

    function test_setDreUSDManager_EmitsEvent() public {
        address newManager = makeAddr("newManager");

        vm.expectEmit(true, true, false, false);
        emit dreAaveAdapter.DreUSDManagerUpdated(withdrawer, newManager);

        vm.prank(admin);
        adapter.setDreUSDManager(newManager);

        assertEq(adapter.dreUSDManager(), newManager);
    }

    function _fundVault() internal {
        // Mint aUSDC to vault
        aUsdc.mint(vault, INITIAL_VAULT_BALANCE);
        
        // Give adapter allowance to spend vault's aUSDC
        vm.prank(vault);
        aUsdc.approve(address(adapter), type(uint256).max);
        
        // Fund Aave pool mock with USDC (pool holds USDC for withdrawals)
        usdc.mint(address(aavePool), INITIAL_VAULT_BALANCE);
        
        // Also fund aToken with USDC (adapter checks aToken's USDC balance for liquidity)
        // In real Aave, the aToken contract holds the underlying USDC
        usdc.mint(address(aUsdc), INITIAL_VAULT_BALANCE);
    }
    
    // ============ Withdraw Tests ============
    
    function test_Withdraw_Success() public {
        uint256 amount = WITHDRAW_AMOUNT;
        uint256 initialRecipientBalance = usdc.balanceOf(recipient);
        uint256 initialVaultBalance = aUsdc.balanceOf(vault);
        
        vm.expectEmit(true, false, false, true);
        emit Withdrawn(recipient, amount);
        
        vm.prank(withdrawer);
        uint256 withdrawn = adapter.withdraw(amount, recipient);
        
        assertEq(withdrawn, amount);
        assertEq(usdc.balanceOf(recipient), initialRecipientBalance + amount);
        assertEq(aUsdc.balanceOf(vault), initialVaultBalance - amount);
    }
    
    function test_Withdraw_RevertIf_ZeroAmount() public {
        vm.prank(withdrawer);
        vm.expectRevert(IAaveV3Adapter.ZeroAmount.selector);
        adapter.withdraw(0, recipient);
    }
    
    function test_Withdraw_RevertIf_MaxSentinel() public {
        vm.prank(withdrawer);
        vm.expectRevert(IAaveV3Adapter.MaxSentinelNotSupported.selector);
        adapter.withdraw(type(uint256).max, recipient);
    }
    
    function test_Withdraw_RevertIf_ZeroAddress() public {
        vm.prank(withdrawer);
        vm.expectRevert(IAaveV3Adapter.ZeroAddress.selector);
        adapter.withdraw(WITHDRAW_AMOUNT, address(0));
    }
    
    function test_Withdraw_RevertIf_InvalidCaller() public {
        vm.prank(unauthorized);
        vm.expectRevert(IAaveV3Adapter.InvalidCaller.selector);
        adapter.withdraw(WITHDRAW_AMOUNT, recipient);
    }
    
    function test_Withdraw_RevertIf_InsufficientBalance() public {
        uint256 excessiveAmount = INITIAL_VAULT_BALANCE + 1;
        
        vm.prank(withdrawer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAaveV3Adapter.InsufficientBalance.selector,
                INITIAL_VAULT_BALANCE,
                excessiveAmount
            )
        );
        adapter.withdraw(excessiveAmount, recipient);
    }
    
    function test_Withdraw_RevertIf_InsufficientAllowance() public {
        // Remove allowance
        vm.prank(vault);
        aUsdc.approve(address(adapter), 0);
        
        vm.prank(withdrawer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAaveV3Adapter.InsufficientBalance.selector,
                0,
                WITHDRAW_AMOUNT
            )
        );
        adapter.withdraw(WITHDRAW_AMOUNT, recipient);
    }
    
    function test_Withdraw_WithPartialAllowance() public {
        uint256 partialAllowance = WITHDRAW_AMOUNT / 2;
        
        // Set partial allowance
        vm.prank(vault);
        aUsdc.approve(address(adapter), partialAllowance);
        
        // Should fail because allowance is less than requested amount
        vm.prank(withdrawer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAaveV3Adapter.InsufficientBalance.selector,
                partialAllowance,
                WITHDRAW_AMOUNT
            )
        );
        adapter.withdraw(WITHDRAW_AMOUNT, recipient);
        
        // But should succeed with the partial amount
        uint256 initialRecipientBalance = usdc.balanceOf(recipient);
        
        vm.prank(withdrawer);
        uint256 withdrawn = adapter.withdraw(partialAllowance, recipient);
        
        assertEq(withdrawn, partialAllowance);
        assertEq(usdc.balanceOf(recipient), initialRecipientBalance + partialAllowance);
    }
    
    function test_Withdraw_WithPartialVaultBalance() public {
        uint256 partialBalance = WITHDRAW_AMOUNT / 2;
        
        // Burn some aUSDC from vault to reduce balance
        aUsdc.burn(vault, INITIAL_VAULT_BALANCE - partialBalance);
        
        // Should fail because vault balance is less than requested amount
        vm.prank(withdrawer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAaveV3Adapter.InsufficientBalance.selector,
                partialBalance,
                WITHDRAW_AMOUNT
            )
        );
        adapter.withdraw(WITHDRAW_AMOUNT, recipient);
        
        // But should succeed with the partial amount
        uint256 initialRecipientBalance = usdc.balanceOf(recipient);
        
        vm.prank(withdrawer);
        uint256 withdrawn = adapter.withdraw(partialBalance, recipient);
        
        assertEq(withdrawn, partialBalance);
        assertEq(usdc.balanceOf(recipient), initialRecipientBalance + partialBalance);
    }
    
    function test_Withdraw_MultipleWithdrawals() public {
        uint256 amount1 = 50_000e6;
        uint256 amount2 = 30_000e6;
        uint256 amount3 = 20_000e6;
        
        uint256 initialRecipientBalance = usdc.balanceOf(recipient);
        
        // First withdrawal
        vm.prank(withdrawer);
        uint256 withdrawn1 = adapter.withdraw(amount1, recipient);
        assertEq(withdrawn1, amount1);
        
        // Second withdrawal
        vm.prank(withdrawer);
        uint256 withdrawn2 = adapter.withdraw(amount2, recipient);
        assertEq(withdrawn2, amount2);
        
        // Third withdrawal
        vm.prank(withdrawer);
        uint256 withdrawn3 = adapter.withdraw(amount3, recipient);
        assertEq(withdrawn3, amount3);
        
        uint256 totalWithdrawn = amount1 + amount2 + amount3;
        assertEq(usdc.balanceOf(recipient), initialRecipientBalance + totalWithdrawn, "Recipient should receive all USDC");
    }
    
    function test_Withdraw_RevertIf_WithdrawalFailed() public {
        // Make Aave pool return less than requested (simulating withdrawal failure)
        aavePool.setWithdrawAmount(WITHDRAW_AMOUNT - 1);
        
        vm.prank(withdrawer);
        vm.expectRevert(IAaveV3Adapter.WithdrawalFailed.selector);
        adapter.withdraw(WITHDRAW_AMOUNT, recipient);
    }

    /// @dev Withdrawal is strictly amount-bound: residual aUSDC on adapter is not withdrawn with the fill
    function test_Withdraw_ResidualAUsdcNotWithdrawn() public {
        uint256 residual = 50_000e6;
        aUsdc.mint(address(adapter), residual); // donate residual aUSDC to adapter

        uint256 requestAmount = WITHDRAW_AMOUNT; // 100k
        uint256 vaultBefore = aUsdc.balanceOf(vault);
        uint256 recipientBefore = usdc.balanceOf(recipient);

        vm.prank(withdrawer);
        uint256 withdrawn = adapter.withdraw(requestAmount, recipient);

        assertEq(withdrawn, requestAmount, "Only requested amount withdrawn");
        assertEq(usdc.balanceOf(recipient), recipientBefore + requestAmount, "Recipient gets only requested USDC");
        assertEq(aUsdc.balanceOf(vault), vaultBefore - requestAmount, "Vault debited only requested aUSDC");
        assertEq(aUsdc.balanceOf(address(adapter)), residual, "Residual aUSDC remains on adapter");
    }

    // ============ GetAvailableBalance Tests ============
    
    function test_GetAvailableBalance() public  {
        uint256 available = adapter.getAvailableBalance();
        assertEq(available, INITIAL_VAULT_BALANCE);
    }
    
    function test_GetAvailableBalance_WithPartialAllowance() public {
        uint256 partialAllowance = WITHDRAW_AMOUNT;
        
        vm.prank(vault);
        aUsdc.approve(address(adapter), partialAllowance);
        
        uint256 available = adapter.getAvailableBalance();
        assertEq(available, partialAllowance);
    }
    
    function test_GetAvailableBalance_WithPartialVaultBalance() public {
        uint256 partialBalance = WITHDRAW_AMOUNT;
        
        // Burn some aUSDC from vault
        aUsdc.burn(vault, INITIAL_VAULT_BALANCE - partialBalance);
        
        uint256 available = adapter.getAvailableBalance();
        assertEq(available, partialBalance);
    }
    
    function test_GetAvailableBalance_WithLimitedPoolLiquidity() public {
        uint256 limitedLiquidity = 50_000e6;
        
        // Reduce aToken's USDC balance to simulate limited liquidity
        // The adapter checks USDC balance of aToken for available liquidity
        usdc.burn(address(aUsdc), INITIAL_VAULT_BALANCE - limitedLiquidity);
        
        uint256 available = adapter.getAvailableBalance();
        // Should return minimum of (vault available, pool liquidity)
        // Vault has INITIAL_VAULT_BALANCE available, but pool only has limitedLiquidity
        assertEq(available, limitedLiquidity);
    }
    
    function test_GetAvailableBalance_WhenLiquidityExceedsAvailable() public {
        uint256 partialBalance = 50_000e6;
        uint256 lowLiquidity = 30_000e6;
        
        // Reduce vault balance to create a smaller available amount
        aUsdc.burn(vault, INITIAL_VAULT_BALANCE - partialBalance);
        
        // Set pool liquidity lower than available (vault balance)
        usdc.burn(address(aUsdc), INITIAL_VAULT_BALANCE - lowLiquidity);
        
        uint256 available = adapter.getAvailableBalance();
        // When balance >= availableLiquidity, returns availableLiquidity (else branch)
        assertEq(available, lowLiquidity, "Should return availableLiquidity when available exceeds it");
    }
    
    function test_GetAvailableBalance_WhenAllowanceExceedsBalance() public {
        uint256 partialBalance = 50_000e6;
        uint256 partialAllowance = 30_000e6;
        
        // Set vault balance higher than allowance
        aUsdc.burn(vault, INITIAL_VAULT_BALANCE - partialBalance);
        
        // Set allowance lower than balance
        vm.prank(vault);
        aUsdc.approve(address(adapter), partialAllowance);
        
        uint256 available = adapter.getAvailableBalance();
        // When vaultBalance >= allowance, returns allowance
        assertEq(available, partialAllowance, "Should return allowance when it's less than balance");
    }
    
    function test_GetAvailableBalance_CombinedElseBranches() public {
        uint256 partialBalance = 100_000e6;
        uint256 partialAllowance = 80_000e6;
        uint256 lowLiquidity = 50_000e6;
        
        // Set vault balance higher than allowance
        aUsdc.burn(vault, INITIAL_VAULT_BALANCE - partialBalance);
        
        // Set allowance lower than balance
        vm.prank(vault);
        aUsdc.approve(address(adapter), partialAllowance);
        
        // Set liquidity lower than available (which is allowance = 80k)
        // This triggers: available (80k) >= availableLiquidity (50k) -> returns availableLiquidity (50k)
        usdc.burn(address(aUsdc), INITIAL_VAULT_BALANCE - lowLiquidity);
        
        uint256 available = adapter.getAvailableBalance();
        // First ternary: vaultBalance (100k) >= allowance (80k) -> returns allowance (80k)
        // Second ternary: available (80k) >= availableLiquidity (50k)? Yes -> returns availableLiquidity (50k)
        assertEq(available, lowLiquidity, "Should return availableLiquidity when both else branches taken");
    }

    /**
     * @dev Fuzz test: withdraw(amount, recipient) succeeds and recipient receives amount when amount in [1, getAvailableBalance()]
     */
    function testFuzz_Withdraw(uint256 amount) public {
        uint256 available = adapter.getAvailableBalance();
        amount = bound(amount, 1, available);

        uint256 recipientBalanceBefore = usdc.balanceOf(recipient);

        vm.prank(withdrawer);
        uint256 withdrawn = adapter.withdraw(amount, recipient);

        assertEq(withdrawn, amount);
        assertEq(usdc.balanceOf(recipient), recipientBalanceBefore + amount);
    }

    /**
     * @dev Fuzz test: getAvailableBalance() always equals min(vaultBalance, allowance, poolLiquidity)
     */
    function testFuzz_GetAvailableBalance(uint256 vaultBal, uint256 allowanceVal, uint256 liquidity) public {
        vaultBal = bound(vaultBal, 0, INITIAL_VAULT_BALANCE);
        allowanceVal = bound(allowanceVal, 0, INITIAL_VAULT_BALANCE);
        liquidity = bound(liquidity, 0, INITIAL_VAULT_BALANCE);

        // Set vault's aUSDC balance
        uint256 currentVaultBal = aUsdc.balanceOf(vault);
        if (vaultBal > currentVaultBal) {
            aUsdc.mint(vault, vaultBal - currentVaultBal);
        } else if (vaultBal < currentVaultBal) {
            aUsdc.burn(vault, currentVaultBal - vaultBal);
        }

        vm.prank(vault);
        aUsdc.approve(address(adapter), allowanceVal);

        // Set pool liquidity (USDC balance of aToken)
        uint256 currentLiq = usdc.balanceOf(address(aUsdc));
        if (liquidity > currentLiq) {
            usdc.mint(address(aUsdc), liquidity - currentLiq);
        } else if (liquidity < currentLiq) {
            usdc.burn(address(aUsdc), currentLiq - liquidity);
        }

        uint256 expected = vaultBal < allowanceVal ? vaultBal : allowanceVal;
        expected = expected < liquidity ? expected : liquidity;

        assertEq(adapter.getAvailableBalance(), expected);
    }

    // ============ Initialize Tests ============
    
    function test_Initialize_RevertIf_ZeroAavePool() public {
        dreAaveAdapter newImpl = new dreAaveAdapter();
        bytes memory initData = abi.encodeWithSelector(
            dreAaveAdapter.initialize.selector,
            address(0), // Zero address for aavePool
            address(usdc),
            vault,
            admin,
            upgrader,
            manager
        );
        
        vm.expectRevert(IAaveV3Adapter.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }
    
    function test_Initialize_RevertIf_ZeroUsdc() public {
        dreAaveAdapter newImpl = new dreAaveAdapter();
        bytes memory initData = abi.encodeWithSelector(
            dreAaveAdapter.initialize.selector,
            address(aavePool),
            address(0), // Zero address for usdc
            vault,
            admin,
            upgrader,
            manager
        );
        
        vm.expectRevert(IAaveV3Adapter.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }
    
    function test_Initialize_RevertIf_ZeroVault() public {
        dreAaveAdapter newImpl = new dreAaveAdapter();
        bytes memory initData = abi.encodeWithSelector(
            dreAaveAdapter.initialize.selector,
            address(aavePool),
            address(usdc),
            address(0), // Zero address for vault
            admin,
            upgrader,
            manager
        );
        
        vm.expectRevert(IAaveV3Adapter.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }
    
    function test_Initialize_RevertIf_ZeroAdmin() public {
        dreAaveAdapter newImpl = new dreAaveAdapter();
        bytes memory initData = abi.encodeWithSelector(
            dreAaveAdapter.initialize.selector,
            address(aavePool),
            address(usdc),
            vault,
            address(0), // Zero address for admin
            upgrader,
            manager
        );
        
        vm.expectRevert(IAaveV3Adapter.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialize_RevertIf_ZeroUpgrader() public {
        dreAaveAdapter newImpl = new dreAaveAdapter();
        bytes memory initData = abi.encodeWithSelector(
            dreAaveAdapter.initialize.selector,
            address(aavePool),
            address(usdc),
            vault,
            admin,
            address(0), // Zero address for upgrader
            manager
        );
        
        vm.expectRevert(IAaveV3Adapter.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialize_RevertIf_ZeroManager() public {
        dreAaveAdapter newImpl = new dreAaveAdapter();
        bytes memory initData = abi.encodeWithSelector(
            dreAaveAdapter.initialize.selector,
            address(aavePool),
            address(usdc),
            vault,
            admin,
            upgrader,
            address(0) // Zero address for manager
        );
        
        vm.expectRevert(IAaveV3Adapter.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }
    
    function test_Initialize_RevertIf_ZeroATokenAddress() public {
        // Create a mock pool that returns zero address for aTokenAddress
        AaveV3PoolMockWithConfigurableAToken mockPool = new AaveV3PoolMockWithConfigurableAToken(address(usdc));
        mockPool.setATokenAddress(address(0));
        
        dreAaveAdapter newImpl = new dreAaveAdapter();
        bytes memory initData = abi.encodeWithSelector(
            dreAaveAdapter.initialize.selector,
            address(mockPool),
            address(usdc),
            vault,
            admin,
            upgrader,
            manager
        );
        
        vm.expectRevert(IAaveV3Adapter.InvalidATokenAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }
    
    function test_Initialize_RevertIf_ATokenAddressHasNoCode() public {
        // Create a mock pool that returns an EOA (address with no code) for aTokenAddress
        address eoaAddress = makeAddr("eoaAddress");
        AaveV3PoolMockWithConfigurableAToken mockPool = new AaveV3PoolMockWithConfigurableAToken(address(usdc));
        mockPool.setATokenAddress(eoaAddress);
        
        // Verify the EOA has no code
        assertEq(eoaAddress.code.length, 0, "EOA should have no code");
        
        dreAaveAdapter newImpl = new dreAaveAdapter();
        bytes memory initData = abi.encodeWithSelector(
            dreAaveAdapter.initialize.selector,
            address(mockPool),
            address(usdc),
            vault,
            admin,
            upgrader,
            manager
        );
        
        vm.expectRevert(IAaveV3Adapter.InvalidATokenAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }
    
    // ============ View Function Tests ============
    
    function test_GetAavePool() public {
        assertEq(adapter.getAavePool(), address(aavePool));
    }
    
    function test_GetAToken() public  {
        assertEq(adapter.getAToken(), address(aUsdc));
    }
    
    function test_GetUsdc() public  {
        assertEq(adapter.getUsdc(), address(usdc));
    }
    
    function test_GetVault() public {
        assertEq(adapter.getVault(), vault);
    }
    
    // ============ Admin Function Tests ============
    
    function test_SetVault() public {
        address newVault = makeAddr("newVault");
        
        // Grant allowance to new vault (required by defensive check)
        vm.prank(newVault);
        aUsdc.approve(address(adapter), type(uint256).max);
        
        vm.expectEmit(true, true, false, true);
        emit VaultUpdated(vault, newVault);
        
        vm.prank(admin);
        adapter.setVault(newVault);
        
        assertEq(adapter.getVault(), newVault, "Vault should be updated");
    }
    
    function test_SetVault_RevertIf_NotAdmin() public {
        address newVault = makeAddr("newVault");
        
        vm.prank(withdrawer);
        vm.expectRevert();
        adapter.setVault(newVault);
    }
    
    function test_SetVault_RevertIf_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IAaveV3Adapter.ZeroAddress.selector);
        adapter.setVault(address(0));
    }
    
    function test_SetVault_RevertIf_InsufficientAllowance() public {
        address newVault = makeAddr("newVault");
        
        // Don't grant allowance - should revert
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAaveV3Adapter.InsufficientAllowance.selector,
                newVault,
                0
            )
        );
        adapter.setVault(newVault);
    }
    
    // ============ RecoverToken Tests ============
    
    function test_RecoverToken_Success() public {
        address recoveryRecipient = makeAddr("recoveryRecipient");
        uint256 recoveryAmount = 10_000e6;
        
        // Send some USDC to the adapter (simulating accidental transfer)
        usdc.mint(address(adapter), recoveryAmount);
        
        uint256 initialRecipientBalance = usdc.balanceOf(recoveryRecipient);
        uint256 adapterBalance = usdc.balanceOf(address(adapter));
        
        assertEq(adapterBalance, recoveryAmount, "Adapter should have tokens");
        
        vm.expectEmit(true, true, false, true);
        emit TokenRecovered(address(usdc), recoveryRecipient, recoveryAmount);
        
        vm.prank(admin);
        adapter.recoverToken(address(usdc), recoveryRecipient);
        
        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have no tokens");
        assertEq(
            usdc.balanceOf(recoveryRecipient), 
            initialRecipientBalance + recoveryAmount,
            "Recipient should receive tokens"
        );
    }
    
    function test_RecoverToken_RecoverAUsdc() public {
        address recoveryRecipient = makeAddr("recoveryRecipient");
        uint256 recoveryAmount = 5_000e6;
        
        // Send some aUSDC to the adapter (simulating accidental transfer)
        aUsdc.mint(address(adapter), recoveryAmount);
        
        uint256 initialRecipientBalance = aUsdc.balanceOf(recoveryRecipient);
        
        vm.expectEmit(true, true, false, true);
        emit TokenRecovered(address(aUsdc), recoveryRecipient, recoveryAmount);
        
        vm.prank(admin);
        adapter.recoverToken(address(aUsdc), recoveryRecipient);
        
        assertEq(aUsdc.balanceOf(address(adapter)), 0, "Adapter should have no aUSDC");
        assertEq(
            aUsdc.balanceOf(recoveryRecipient), 
            initialRecipientBalance + recoveryAmount,
            "Recipient should receive aUSDC"
        );
    }
    
    function test_RecoverToken_RecoverOtherToken() public {
        address recoveryRecipient = makeAddr("recoveryRecipient");
        MockERC20 otherToken = new MockERC20("Other Token", "OTHER", 18);
        uint256 recoveryAmount = 1000e18;
        
        // Send some other token to the adapter
        otherToken.mint(address(adapter), recoveryAmount);
        
        uint256 initialRecipientBalance = otherToken.balanceOf(recoveryRecipient);
        
        vm.expectEmit(true, true, false, true);
        emit TokenRecovered(address(otherToken), recoveryRecipient, recoveryAmount);
        
        vm.prank(admin);
        adapter.recoverToken(address(otherToken), recoveryRecipient);
        
        assertEq(otherToken.balanceOf(address(adapter)), 0, "Adapter should have no tokens");
        assertEq(
            otherToken.balanceOf(recoveryRecipient), 
            initialRecipientBalance + recoveryAmount,
            "Recipient should receive tokens"
        );
    }
    
    function test_RecoverToken_ZeroBalance() public {
        address recoveryRecipient = makeAddr("recoveryRecipient");
        
        // Adapter has no tokens - should not revert, just do nothing
        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should have no tokens initially");
        
        uint256 initialRecipientBalance = usdc.balanceOf(recoveryRecipient);
        
        vm.prank(admin);
        adapter.recoverToken(address(usdc), recoveryRecipient);
        
        // Should succeed without reverting
        assertEq(usdc.balanceOf(address(adapter)), 0, "Adapter should still have no tokens");
        assertEq(
            usdc.balanceOf(recoveryRecipient), 
            initialRecipientBalance,
            "Recipient balance should be unchanged"
        );
    }
    
    function test_RecoverToken_RevertIf_NotAdmin() public {
        address recoveryRecipient = makeAddr("recoveryRecipient");
        uint256 recoveryAmount = 10_000e6;
        
        // Send some USDC to the adapter
        usdc.mint(address(adapter), recoveryAmount);
        
        // Try to recover as non-admin (withdrawer)
        vm.prank(withdrawer);
        vm.expectRevert();
        adapter.recoverToken(address(usdc), recoveryRecipient);
        
        // Tokens should still be in adapter
        assertEq(usdc.balanceOf(address(adapter)), recoveryAmount, "Tokens should remain in adapter");
    }
    
    function test_RecoverToken_RevertIf_ZeroRecipient() public {
        uint256 recoveryAmount = 10_000e6;
        
        // Send some USDC to the adapter
        usdc.mint(address(adapter), recoveryAmount);
        
        vm.prank(admin);
        vm.expectRevert(IAaveV3Adapter.ZeroAddress.selector);
        adapter.recoverToken(address(usdc), address(0));
        
        // Tokens should still be in adapter
        assertEq(usdc.balanceOf(address(adapter)), recoveryAmount, "Tokens should remain in adapter");
    }
    
    function test_RecoverToken_MultipleTokens() public {
        address recoveryRecipient = makeAddr("recoveryRecipient");
        uint256 usdcAmount = 10_000e6;
        uint256 aUsdcAmount = 5_000e6;
        MockERC20 otherToken = new MockERC20("Other Token", "OTHER", 18);
        uint256 otherAmount = 1000e18;
        
        // Send multiple tokens to adapter
        usdc.mint(address(adapter), usdcAmount);
        aUsdc.mint(address(adapter), aUsdcAmount);
        otherToken.mint(address(adapter), otherAmount);
        
        // Recover USDC
        vm.expectEmit(true, true, false, true);
        emit TokenRecovered(address(usdc), recoveryRecipient, usdcAmount);
        vm.prank(admin);
        adapter.recoverToken(address(usdc), recoveryRecipient);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(recoveryRecipient), usdcAmount);
        
        // Recover aUSDC
        vm.expectEmit(true, true, false, true);
        emit TokenRecovered(address(aUsdc), recoveryRecipient, aUsdcAmount);
        vm.prank(admin);
        adapter.recoverToken(address(aUsdc), recoveryRecipient);
        assertEq(aUsdc.balanceOf(address(adapter)), 0);
        assertEq(aUsdc.balanceOf(recoveryRecipient), aUsdcAmount);
        
        // Recover other token
        vm.expectEmit(true, true, false, true);
        emit TokenRecovered(address(otherToken), recoveryRecipient, otherAmount);
        vm.prank(admin);
        adapter.recoverToken(address(otherToken), recoveryRecipient);
        assertEq(otherToken.balanceOf(address(adapter)), 0);
        assertEq(otherToken.balanceOf(recoveryRecipient), otherAmount);
    }

    // ============ Upgrade Tests (_authorizeUpgrade) ============

    function test_Upgrade_Success() public {
        dreAaveAdapter newImplementation = new dreAaveAdapter();

        vm.prank(upgrader);
        adapter.upgradeToAndCall(address(newImplementation), "");

        // Proxy still works; verify adapter state is preserved
        assertEq(adapter.getAavePool(), address(aavePool));
        assertEq(adapter.getUsdc(), address(usdc));
        assertEq(adapter.getVault(), vault);
        assertTrue(adapter.hasRole(UPGRADER_ROLE, upgrader));
        assertEq(adapter.dreUSDManager(), withdrawer); // set in _setupRoles
    }

    function test_Upgrade_RevertIf_NotUpgrader() public {
        dreAaveAdapter newImplementation = new dreAaveAdapter();

        vm.prank(unauthorized);
        vm.expectRevert();
        adapter.upgradeToAndCall(address(newImplementation), "");
    }

    function test_Upgrade_RevertIf_WithdrawerWithoutUpgraderRole() public {
        dreAaveAdapter newImplementation = new dreAaveAdapter();

        // Withdrawer is dreUSDManager (can withdraw) but does not have UPGRADER_ROLE
        vm.prank(withdrawer);
        vm.expectRevert();
        adapter.upgradeToAndCall(address(newImplementation), "");
    }
}
