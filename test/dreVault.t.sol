// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {dreVault} from "../contracts/dreVault.sol";
import {IdreVault} from "../contracts/interfaces/IdreVault.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";

/**
 * @title DreVaultTest
 * @dev Test suite for dreVault USDC forwarding vault
 */
contract DreVaultTest is Test {
    MockERC20 public usdc;
    MockERC20 public otherToken;

    address public governance;
    address public hop2Vault;
    address public utilaWallet;
    address public keeper;
    address public recipient;

    dreVault public hop1;
    dreVault public hop2;

    uint256 public constant DEPOSIT_AMOUNT = 100_000e6;
    uint256 public constant OTHER_TOKEN_AMOUNT = 1_000e18;
    uint256 public constant ETH_AMOUNT = 1 ether;

    event UsdcForwarded(address indexed to, uint256 amount);
    event TokenRecovered(address indexed token, address indexed recipient, uint256 amount);
    event EtherRecovered(address indexed recipient, uint256 amount);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        otherToken = new MockERC20("Other", "OTH", 18);
        governance = makeAddr("governance");
        utilaWallet = makeAddr("utilaWallet");
        keeper = makeAddr("chainlinkKeeper");
        recipient = makeAddr("recipient");

        hop2 = new dreVault(address(usdc), utilaWallet, governance);
        hop2Vault = address(hop2);
        hop1 = new dreVault(address(usdc), hop2Vault, governance);
    }

    // ============ Constructor ============

    function test_Constructor_SetsImmutablesAndOwner() public  {
        assertEq(hop1.token(), address(usdc));
        assertEq(hop1.forwardVault(), hop2Vault);
        assertEq(hop1.owner(), governance);
        assertEq(hop2.token(), address(usdc));
        assertEq(hop2.forwardVault(), utilaWallet);
        assertEq(hop2.owner(), governance);
    }

    function test_Constructor_RevertIf_TokenZero() public {
        vm.expectRevert(IdreVault.ZeroAddress.selector);
        new dreVault(address(0), hop2Vault, governance);
    }

    function test_Constructor_RevertIf_ForwardVaultZero() public {
        vm.expectRevert(IdreVault.ZeroAddress.selector);
        new dreVault(address(usdc), address(0), governance);
    }

    function test_Constructor_RevertIf_OwnerZero() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new dreVault(address(usdc), hop2Vault, address(0));
    }

    // ============ checkUpkeep ============

    function test_checkUpkeep_ReturnsFalseWhenEmpty() public  {
        (bool upkeepNeeded, bytes memory performData) = hop1.checkUpkeep("");
        assertFalse(upkeepNeeded);
        assertEq(performData.length, 0);
    }

    function test_checkUpkeep_ReturnsTrueWhenFunded() public {
        usdc.mint(address(hop1), DEPOSIT_AMOUNT);

        (bool upkeepNeeded,) = hop1.checkUpkeep("");
        assertTrue(upkeepNeeded);
    }

    // ============ performUpkeep ============

    function test_performUpkeep_RevertIf_NothingToForward() public {
        vm.expectRevert(IdreVault.NothingToForward.selector);
        hop1.performUpkeep("");
    }

    function test_performUpkeep_ForwardsFullBalanceToForwardVault() public {
        usdc.mint(address(hop1), DEPOSIT_AMOUNT);

        vm.expectEmit(true, false, false, true);
        emit UsdcForwarded(hop2Vault, DEPOSIT_AMOUNT);

        vm.prank(keeper);
        hop1.performUpkeep("");

        assertEq(usdc.balanceOf(address(hop1)), 0);
        assertEq(usdc.balanceOf(hop2Vault), DEPOSIT_AMOUNT);
    }

    function test_performUpkeep_AnyCallerCanTrigger() public {
        usdc.mint(address(hop1), DEPOSIT_AMOUNT);

        address randomCaller = makeAddr("randomCaller");
        vm.prank(randomCaller);
        hop1.performUpkeep("");

        assertEq(usdc.balanceOf(hop2Vault), DEPOSIT_AMOUNT);
    }

    function test_performUpkeep_ForwardsEntireBalanceWhenBalanceIncreases() public {
        usdc.mint(address(hop1), 50_000e6);
        vm.prank(keeper);
        hop1.performUpkeep("");

        usdc.mint(address(hop1), 25_000e6);

        vm.expectEmit(true, false, false, true);
        emit UsdcForwarded(hop2Vault, 25_000e6);

        vm.prank(keeper);
        hop1.performUpkeep("");

        assertEq(usdc.balanceOf(hop2Vault), 75_000e6);
    }

    // ============ Two-hop pipeline ============

    function test_TwoHopPipeline_ManagerToUtila() public {
        // Simulate dreUSDManager routing mint proceeds to hop 1 (custodianVault)
        usdc.mint(address(hop1), DEPOSIT_AMOUNT);

        hop1.performUpkeep("");
        assertEq(usdc.balanceOf(hop2Vault), DEPOSIT_AMOUNT);
        assertEq(usdc.balanceOf(utilaWallet), 0);

        hop2.performUpkeep("");
        assertEq(usdc.balanceOf(hop2Vault), 0);
        assertEq(usdc.balanceOf(utilaWallet), DEPOSIT_AMOUNT);
    }

    function test_TwoHopPipeline_checkUpkeepPerHop() public {
        usdc.mint(address(hop1), DEPOSIT_AMOUNT);

        (bool hop1Needed,) = hop1.checkUpkeep("");
        assertTrue(hop1Needed);

        (bool hop2Needed,) = hop2.checkUpkeep("");
        assertFalse(hop2Needed);

        hop1.performUpkeep("");

        (hop1Needed,) = hop1.checkUpkeep("");
        assertFalse(hop1Needed);

        (hop2Needed,) = hop2.checkUpkeep("");
        assertTrue(hop2Needed);
    }

    // ============ Single-hop ============

    function test_SingleHop_ForwardsToCorporateWallet() public {
        dreVault singleHop = new dreVault(address(usdc), utilaWallet, governance);
        usdc.mint(address(singleHop), DEPOSIT_AMOUNT);

        vm.expectEmit(true, false, false, true);
        emit UsdcForwarded(utilaWallet, DEPOSIT_AMOUNT);

        singleHop.performUpkeep("");
        assertEq(usdc.balanceOf(utilaWallet), DEPOSIT_AMOUNT);
    }

    // ============ recoverToken ============

    function test_recoverToken_SendsOtherErc20ToRecipient() public {
        otherToken.mint(address(hop1), OTHER_TOKEN_AMOUNT);

        vm.expectEmit(true, true, false, true);
        emit TokenRecovered(address(otherToken), recipient, OTHER_TOKEN_AMOUNT);

        vm.prank(governance);
        hop1.recoverToken(address(otherToken), recipient);

        assertEq(otherToken.balanceOf(recipient), OTHER_TOKEN_AMOUNT);
        assertEq(otherToken.balanceOf(address(hop1)), 0);
    }

    function test_recoverToken_RevertIf_ConfiguredToken() public {
        usdc.mint(address(hop1), DEPOSIT_AMOUNT);

        vm.prank(governance);
        vm.expectRevert(IdreVault.ConfiguredTokenNotRecoverable.selector);
        hop1.recoverToken(address(usdc), recipient);
    }

    function test_recoverToken_RevertIf_NotOwner() public {
        otherToken.mint(address(hop1), OTHER_TOKEN_AMOUNT);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        hop1.recoverToken(address(otherToken), recipient);
    }

    function test_recoverToken_RevertIf_RecipientZero() public {
        otherToken.mint(address(hop1), OTHER_TOKEN_AMOUNT);

        vm.prank(governance);
        vm.expectRevert(IdreVault.ZeroAddress.selector);
        hop1.recoverToken(address(otherToken), address(0));
    }

    function test_recoverToken_NoOpWhenZeroBalance() public {
        vm.prank(governance);
        hop1.recoverToken(address(otherToken), recipient);
        assertEq(otherToken.balanceOf(recipient), 0);
    }

    // ============ recoverEther ============

    function test_recoverEther_SendsBalanceToRecipient() public {
        vm.deal(address(hop1), ETH_AMOUNT);

        vm.expectEmit(true, false, false, true);
        emit EtherRecovered(recipient, ETH_AMOUNT);

        vm.prank(governance);
        hop1.recoverEther(recipient);

        assertEq(recipient.balance, ETH_AMOUNT);
        assertEq(address(hop1).balance, 0);
    }

    function test_recoverEther_RevertIf_NotOwner() public {
        vm.deal(address(hop1), ETH_AMOUNT);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        hop1.recoverEther(recipient);
    }

    function test_recoverEther_RevertIf_RecipientZero() public {
        vm.deal(address(hop1), ETH_AMOUNT);

        vm.prank(governance);
        vm.expectRevert(IdreVault.ZeroAddress.selector);
        hop1.recoverEther(address(0));
    }

    function test_recoverEther_NoOpWhenZeroBalance() public {
        vm.prank(governance);
        hop1.recoverEther(recipient);
        assertEq(recipient.balance, 0);
    }

    function test_receive_AcceptsEth() public {
        vm.deal(address(this), ETH_AMOUNT);
        (bool ok,) = address(hop1).call{value: ETH_AMOUNT}("");
        assertTrue(ok);
        assertEq(address(hop1).balance, ETH_AMOUNT);
    }
}
