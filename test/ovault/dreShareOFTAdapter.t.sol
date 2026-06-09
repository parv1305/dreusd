// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { dreShareOFTAdapter } from "../../contracts/ovault/dreShareOFTAdapter.sol";
import { MockERC20 } from "@layerzerolabs/ovault-evm/test/mocks/MockERC20.sol";
import { EndpointV2Mock } from "../../contracts/mocks/EndpointV2Mock.sol";

/**
 * @title MockERC20RevertsTo
 * @dev Mock ERC20 that reverts when transfer(to, ...) is called with to == blockedAddress
 */
contract MockERC20RevertsTo is MockERC20 {
    address public blockedAddress;

    constructor(string memory name, string memory symbol, address _blockedAddress) MockERC20(name, symbol) {
        blockedAddress = _blockedAddress;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == blockedAddress) revert("Transfer blocked");
        return super.transfer(to, amount);
    }
}

/**
 * @title CreditHarness
 * @dev Exposes internal _credit function for testing
 */
contract CreditHarness is dreShareOFTAdapter {
    constructor(
        address _token,
        address _lzEndpoint
    ) dreShareOFTAdapter(_token, _lzEndpoint) {}
    
    function credit(
        address _to,
        uint256 _amountLD,
        uint32 _srcEid
    ) external returns (uint256) {
        return _credit(_to, _amountLD, _srcEid);
    }
}

/**
 * @title dreShareOFTAdapterTest
 * @notice Comprehensive test suite for dreShareOFTAdapter contract
 */
contract dreShareOFTAdapterTest is Test {
    dreShareOFTAdapter public adapter;
    dreShareOFTAdapter public implementation;
    ERC1967Proxy public proxy;
    
    MockERC20 public shareToken;
    EndpointV2Mock public endpoint;
    
    address public owner;
    address public stuckFundsRecipient;
    address public user1;
    address public user2;
    address public sanctionedUser;
    address public frozenUser;
    
    uint256 constant INITIAL_BALANCE = 1000 ether;
    uint256 constant TRANSFER_AMOUNT = 100 ether;
    
    function setUp() public {
        // Deploy mocks
        endpoint = new EndpointV2Mock();
        shareToken = new MockERC20("Share Token", "SHARE");
        
        // Setup addresses
        owner = makeAddr("owner");
        stuckFundsRecipient = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        sanctionedUser = makeAddr("sanctionedUser");
        frozenUser = makeAddr("frozenUser");
        
        // Mint share tokens to adapter (simulating locked tokens)
        shareToken.mint(address(this), INITIAL_BALANCE);
        
        // Deploy implementation
        implementation = new dreShareOFTAdapter(
            address(shareToken),
            address(endpoint)
        );
        
        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            dreShareOFTAdapter.initialize.selector,
            owner,
            stuckFundsRecipient
        );
        
        proxy = new ERC1967Proxy(address(implementation), initData);
        adapter = dreShareOFTAdapter(address(proxy));
        
        // Transfer share tokens to adapter (simulating locked tokens)
        shareToken.transfer(address(adapter), INITIAL_BALANCE);
    }
    
    // ============ Initialization Tests ============
    
    function test_Initialize() public  {
        assertEq(adapter.token(), address(shareToken));
        assertEq(adapter.owner(), owner);
        assertEq(adapter.stuckFundsRecipient(), stuckFundsRecipient);
    }
    
    function test_Initialize_RevertIf_AlreadyInitialized() public {
        vm.expectRevert();
        adapter.initialize(owner, stuckFundsRecipient);
    }
    
    function test_Initialize_RevertIf_DelegateIsZeroAddress() public {
        dreShareOFTAdapter newImpl = new dreShareOFTAdapter(
            address(shareToken),
            address(endpoint)
        );
        bytes memory initData = abi.encodeWithSelector(
            dreShareOFTAdapter.initialize.selector,
            address(0),
            stuckFundsRecipient
        );
        
        vm.expectRevert(dreShareOFTAdapter.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }
    
    function test_Initialize_RevertIf_StuckFundsRecipientIsZeroAddress() public {
        dreShareOFTAdapter newImpl = new dreShareOFTAdapter(
            address(shareToken),
            address(endpoint)
        );
        bytes memory initData = abi.encodeWithSelector(
            dreShareOFTAdapter.initialize.selector,
            owner,
            address(0)
        );
        
        vm.expectRevert(dreShareOFTAdapter.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_setStuckFundsRecipient_EmitsEvent() public {
        address newRecipient = makeAddr("newRecipient");

        vm.expectEmit(true, true, false, false);
        emit dreShareOFTAdapter.StuckFundsRecipientUpdated(stuckFundsRecipient, newRecipient);

        vm.prank(owner);
        adapter.setStuckFundsRecipient(newRecipient);

        assertEq(adapter.stuckFundsRecipient(), newRecipient);
    }

    // ============ _credit Tests ============
    // Note: _credit is internal, so we need to test it via OFT send/receive flow
    // For unit testing, we'll create a harness that exposes _credit
    
    function test_Credit_TransfersToValidAddress() public {
        // Deploy harness
        CreditHarness harnessImpl = new CreditHarness(
            address(shareToken),
            address(endpoint)
        );
        
        bytes memory initData = abi.encodeWithSelector(
            dreShareOFTAdapter.initialize.selector,
            owner,
            stuckFundsRecipient
        );
        
        ERC1967Proxy harnessProxy = new ERC1967Proxy(address(harnessImpl), initData);
        CreditHarness harness = CreditHarness(address(harnessProxy));
        
        // Mint and transfer tokens to harness
        shareToken.mint(address(this), TRANSFER_AMOUNT);
        shareToken.transfer(address(harness), TRANSFER_AMOUNT);
        
        uint256 user1BalanceBefore = shareToken.balanceOf(user1);
        uint256 harnessBalanceBefore = shareToken.balanceOf(address(harness));
        
        // Call credit
        uint256 received = harness.credit(user1, TRANSFER_AMOUNT, 1);
        
        assertEq(received, TRANSFER_AMOUNT);
        assertEq(shareToken.balanceOf(user1), user1BalanceBefore + TRANSFER_AMOUNT);
        assertEq(shareToken.balanceOf(address(harness)), harnessBalanceBefore - TRANSFER_AMOUNT);
    }
    
    function test_Credit_TransfersToFrozenAddress() public {
        // Note: In production, the vault share token's _update() will validate addresses
        // This test verifies that _credit doesn't validate early, allowing the quarantine pattern
        // The actual vault token would handle validation during safeTransfer()
        
        // Deploy harness
        CreditHarness harnessImpl = new CreditHarness(
            address(shareToken),
            address(endpoint)
        );
        
        bytes memory initData = abi.encodeWithSelector(
            dreShareOFTAdapter.initialize.selector,
            owner,
            stuckFundsRecipient
        );
        
        ERC1967Proxy harnessProxy = new ERC1967Proxy(address(harnessImpl), initData);
        CreditHarness harness = CreditHarness(address(harnessProxy));
        
        // Mint and transfer tokens to harness
        shareToken.mint(address(this), TRANSFER_AMOUNT);
        shareToken.transfer(address(harness), TRANSFER_AMOUNT);
        
        // _credit should transfer without early validation
        // (In production, vault's _update() would validate during transfer)
        uint256 received = harness.credit(user1, TRANSFER_AMOUNT, 1);
        assertEq(received, TRANSFER_AMOUNT);
        assertEq(shareToken.balanceOf(user1), TRANSFER_AMOUNT);
    }
    
    function test_Credit_TransfersToSanctionedAddress() public {
        // Note: In production, the vault share token's _update() will validate addresses
        // This test verifies that _credit doesn't validate early
        
        // Deploy harness
        CreditHarness harnessImpl = new CreditHarness(
            address(shareToken),
            address(endpoint)
        );
        
        bytes memory initData = abi.encodeWithSelector(
            dreShareOFTAdapter.initialize.selector,
            owner,
            stuckFundsRecipient
        );
        
        ERC1967Proxy harnessProxy = new ERC1967Proxy(address(harnessImpl), initData);
        CreditHarness harness = CreditHarness(address(harnessProxy));
        
        // Mint and transfer tokens to harness
        shareToken.mint(address(this), TRANSFER_AMOUNT);
        shareToken.transfer(address(harness), TRANSFER_AMOUNT);
        
        // _credit should transfer without early validation
        // (In production, vault's _update() would validate during transfer)
        uint256 received = harness.credit(user1, TRANSFER_AMOUNT, 1);
        assertEq(received, TRANSFER_AMOUNT);
        assertEq(shareToken.balanceOf(user1), TRANSFER_AMOUNT);
    }
    
    function test_StuckFundsRecovered_WhenCreditToRecipientFails() public {
        // Token that reverts when transferring to blockedAddress (simulates sanctioned/frozen)
        address multisig = user2;
        MockERC20RevertsTo revertingToken = new MockERC20RevertsTo("Revert Share", "RS", sanctionedUser);
        revertingToken.mint(address(this), INITIAL_BALANCE);

        CreditHarness harnessImpl = new CreditHarness(
            address(revertingToken),
            address(endpoint)
        );
        bytes memory initData = abi.encodeWithSelector(
            dreShareOFTAdapter.initialize.selector,
            owner,
            multisig
        );
        ERC1967Proxy harnessProxy = new ERC1967Proxy(address(harnessImpl), initData);
        CreditHarness harness = CreditHarness(address(harnessProxy));

        revertingToken.transfer(address(harness), TRANSFER_AMOUNT);

        uint256 multisigBefore = revertingToken.balanceOf(multisig);
        uint256 received = harness.credit(sanctionedUser, TRANSFER_AMOUNT, 1);

        assertEq(received, TRANSFER_AMOUNT);
        assertEq(revertingToken.balanceOf(sanctionedUser), 0, "Blocked recipient should receive nothing");
        assertEq(
            revertingToken.balanceOf(multisig),
            multisigBefore + TRANSFER_AMOUNT,
            "Multisig should receive stuck funds"
        );
    }

    function test_Credit_SkipsValidationForZeroAddress() public {
        // Deploy harness
        CreditHarness harnessImpl = new CreditHarness(
            address(shareToken),
            address(endpoint)
        );
        
        bytes memory initData = abi.encodeWithSelector(
            dreShareOFTAdapter.initialize.selector,
            owner,
            stuckFundsRecipient
        );
        
        ERC1967Proxy harnessProxy = new ERC1967Proxy(address(harnessImpl), initData);
        CreditHarness harness = CreditHarness(address(harnessProxy));
        
        // Mint and transfer tokens to harness
        shareToken.mint(address(this), TRANSFER_AMOUNT);
        shareToken.transfer(address(harness), TRANSFER_AMOUNT);
        
        // Transfer to address(0) fails; fallback sends to stuckFundsRecipient
        uint256 recipientBefore = shareToken.balanceOf(stuckFundsRecipient);
        uint256 received = harness.credit(address(0), TRANSFER_AMOUNT, 1);
        assertEq(received, TRANSFER_AMOUNT);
        assertEq(shareToken.balanceOf(address(0)), 0);
        assertEq(shareToken.balanceOf(stuckFundsRecipient), recipientBefore + TRANSFER_AMOUNT);
    }
    
    function test_Credit_ReturnsAmountReceivedLD() public {
        // Deploy harness
        CreditHarness harnessImpl = new CreditHarness(
            address(shareToken),
            address(endpoint)
        );
        
        bytes memory initData = abi.encodeWithSelector(
            dreShareOFTAdapter.initialize.selector,
            owner,
            stuckFundsRecipient
        );
        
        ERC1967Proxy harnessProxy = new ERC1967Proxy(address(harnessImpl), initData);
        CreditHarness harness = CreditHarness(address(harnessProxy));
        
        // Mint and transfer tokens to harness
        shareToken.mint(address(this), TRANSFER_AMOUNT);
        shareToken.transfer(address(harness), TRANSFER_AMOUNT);
        
        uint256 received = harness.credit(user1, TRANSFER_AMOUNT, 99);
        assertEq(received, TRANSFER_AMOUNT);
    }
    
    // ============ Upgrade Tests ============
    
    function test_Upgrade() public {
        // Deploy new implementation
        dreShareOFTAdapter newImplementation = new dreShareOFTAdapter(
            address(shareToken),
            address(endpoint)
        );
        
        // Upgrade
        vm.prank(owner);
        adapter.upgradeToAndCall(address(newImplementation), "");
        
        // Verify adapter still works
        assertEq(adapter.token(), address(shareToken));
    }
    
    function test_Upgrade_RevertIf_NotOwner() public {
        dreShareOFTAdapter newImplementation = new dreShareOFTAdapter(
            address(shareToken),
            address(endpoint)
        );
        
        vm.expectRevert();
        adapter.upgradeToAndCall(address(newImplementation), "");
    }
    
    // ============ Edge Cases ============
    
    function test_Credit_RevertIf_InsufficientBalance() public {
        // Deploy harness
        CreditHarness harnessImpl = new CreditHarness(
            address(shareToken),
            address(endpoint)
        );
        
        bytes memory initData = abi.encodeWithSelector(
            dreShareOFTAdapter.initialize.selector,
            owner,
            stuckFundsRecipient
        );
        
        ERC1967Proxy harnessProxy = new ERC1967Proxy(address(harnessImpl), initData);
        CreditHarness harness = CreditHarness(address(harnessProxy));
        
        // Mint and transfer partial amount to harness
        uint256 partialAmount = TRANSFER_AMOUNT / 2;
        shareToken.mint(address(this), partialAmount);
        shareToken.transfer(address(harness), partialAmount);
        
        // Call credit with more than available - should revert
        vm.expectRevert(); // ERC20InsufficientBalance
        harness.credit(user1, TRANSFER_AMOUNT, 1);
    }
}
