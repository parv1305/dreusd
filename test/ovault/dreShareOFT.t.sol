// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { dreShareOFT } from "../../contracts/ovault/dreShareOFT.sol";
import { SanctionsListMock } from "../../contracts/mocks/SanctionsListMock.sol";
import { EndpointV2Mock } from "../../contracts/mocks/EndpointV2Mock.sol";
import { DreUSDMock } from "../../contracts/mocks/DreUSDMock.sol";
import { IdreUSD } from "../../contracts/interfaces/IdreUSD.sol";

/**
 * @title ShareOFTHarness
 * @dev Exposes internal _mint, _burn, and _credit for testing
 */
contract ShareOFTHarness is dreShareOFT {
    constructor(address _lzEndpoint, address _dreUSDCompliance) dreShareOFT(_lzEndpoint, _dreUSDCompliance) {}
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
    
    function credit(address _to, uint256 _amountLD, uint32 _srcEid) external returns (uint256) {
        return _credit(_to, _amountLD, _srcEid);
    }
}

/**
 * @title dreShareOFTTest
 * @notice Comprehensive test suite for dreShareOFT contract
 */
contract dreShareOFTTest is Test {
    dreShareOFT public shareOFT;
    dreShareOFT public implementation;
    ERC1967Proxy public proxy;
    
    EndpointV2Mock public endpoint;
    DreUSDMock public compliance; // dreUSD-compatible mock for validation

    address public owner;
    address public user1;
    address public user2;
    address public sanctionedUser;
    address public frozenUser;
    
    string constant NAME = "dreUSD Share";
    string constant SYMBOL = "dreUSDs";
    
    uint256 constant INITIAL_SUPPLY = 1000 ether;
    
    /// @dev Helper to create a harness instance with tokens minted to user1
    function _createHarnessWithTokens() internal returns (ShareOFTHarness) {
        ShareOFTHarness harnessImpl = new ShareOFTHarness(address(endpoint), address(compliance));
        bytes memory initData = abi.encodeWithSelector(
            dreShareOFT.initialize.selector,
            NAME,
            SYMBOL,
            owner
        );
        ERC1967Proxy harnessProxy = new ERC1967Proxy(address(harnessImpl), initData);
        ShareOFTHarness harness = ShareOFTHarness(address(harnessProxy));
        harness.mint(user1, INITIAL_SUPPLY);
        return harness;
    }
    
    function setUp() public {
        // Deploy mocks (compliance = dreUSD-compatible mock, same address across chains in prod)
        endpoint = new EndpointV2Mock();
        compliance = new DreUSDMock();

        // Setup addresses
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        sanctionedUser = makeAddr("sanctionedUser");
        frozenUser = makeAddr("frozenUser");

        // Deploy implementation (immutable dreUSDCompliance set in constructor)
        implementation = new dreShareOFT(address(endpoint), address(compliance));
        
        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            dreShareOFT.initialize.selector,
            NAME,
            SYMBOL,
            owner
        );
        
        proxy = new ERC1967Proxy(address(implementation), initData);
        shareOFT = dreShareOFT(address(proxy));
    }
    
    // ============ Initialization Tests ============
    
    function test_Initialize() public  {
        assertEq(shareOFT.name(), NAME);
        assertEq(shareOFT.symbol(), SYMBOL);
        assertEq(shareOFT.decimals(), 18);
        assertEq(shareOFT.owner(), owner);
    }
    
    function test_Initialize_RevertIf_AlreadyInitialized() public {
        vm.expectRevert();
        shareOFT.initialize(NAME, SYMBOL, owner);
    }
    
    function test_Initialize_RevertIf_DelegateIsZeroAddress() public {
        dreShareOFT newImpl = new dreShareOFT(address(endpoint), address(compliance));
        bytes memory initData = abi.encodeWithSelector(
            dreShareOFT.initialize.selector,
            NAME,
            SYMBOL,
            address(0)
        );
        
        vm.expectRevert(dreShareOFT.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }
    
    // ============ Transfer Tests ============
    
    function test_Transfer() public {
        ShareOFTHarness harness = _createHarnessWithTokens();
        
        uint256 amount = 50 ether;
        vm.prank(user1);
        bool success = harness.transfer(user2, amount);
        assertTrue(success);
        
        assertEq(harness.balanceOf(user1), INITIAL_SUPPLY - amount);
        assertEq(harness.balanceOf(user2), amount);
    }
    
    function test_Transfer_RevertIf_FromFrozenAddress() public {
        ShareOFTHarness harness = _createHarnessWithTokens();
        
        vm.prank(address(this));
        compliance.freeze(user1);
        
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.FrozenAddress.selector, user1));
        harness.transfer(user2, 50 ether);
    }
    
    function test_Transfer_RevertIf_ToFrozenAddress() public {
        ShareOFTHarness harness = _createHarnessWithTokens();
        
        vm.prank(address(this));
        compliance.freeze(user2);
        
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.FrozenAddress.selector, user2));
        harness.transfer(user2, 50 ether);
    }
    
    function test_Transfer_RevertIf_FromSanctionedAddress() public {
        ShareOFTHarness harness = _createHarnessWithTokens();

        SanctionsListMock list = new SanctionsListMock();
        compliance.setSanctionsList(address(list));
        vm.prank(address(this));
        list.setSanctioned(user1, true);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.SanctionedAddress.selector, user1));
        harness.transfer(user2, 50 ether);
    }
    
    function test_Transfer_RevertIf_ToSanctionedAddress() public {
        ShareOFTHarness harness = _createHarnessWithTokens();
        
        SanctionsListMock list = new SanctionsListMock();
        compliance.setSanctionsList(address(list));
        vm.prank(address(this));
        list.setSanctioned(user2, true);
        
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.SanctionedAddress.selector, user2));
        harness.transfer(user2, 50 ether);
    }
    
    // ============ TransferFrom Tests ============
    
    function test_TransferFrom() public {
        ShareOFTHarness harness = _createHarnessWithTokens();
        
        uint256 amount = 50 ether;
        vm.prank(user1);
        harness.approve(user2, amount);
        
        vm.prank(user2);
        bool success = harness.transferFrom(user1, user2, amount);
        assertTrue(success);
        
        assertEq(harness.balanceOf(user1), INITIAL_SUPPLY - amount);
        assertEq(harness.balanceOf(user2), amount);
    }
    
    function test_TransferFrom_RevertIf_FromFrozenAddress() public {
        ShareOFTHarness harness = _createHarnessWithTokens();
        
        uint256 amount = 50 ether;
        vm.prank(user1);
        harness.approve(user2, amount);
        
        vm.prank(address(this));
        compliance.freeze(user1);
        
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.FrozenAddress.selector, user1));
        harness.transferFrom(user1, user2, amount);
    }
    
    function test_TransferFrom_RevertIf_ToFrozenAddress() public {
        ShareOFTHarness harness = _createHarnessWithTokens();
        
        uint256 amount = 50 ether;
        vm.prank(user1);
        harness.approve(user2, amount);
        
        vm.prank(address(this));
        compliance.freeze(user2);
        
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.FrozenAddress.selector, user2));
        harness.transferFrom(user1, user2, amount);
    }
    
    // ============ Mint Tests (via OFT _credit) ============
    // Note: dreShareOFT should only mint via OFT._credit() when receiving cross-chain transfers
    // Direct minting should not be exposed, but we test that minting works for address(0) -> to
    
    function test_Mint_AllowsMinting() public {
        // Minting should work (used internally by OFT when receiving cross-chain transfers)
        ShareOFTHarness harnessImpl = new ShareOFTHarness(address(endpoint), address(compliance));
        bytes memory initData = abi.encodeWithSelector(
            dreShareOFT.initialize.selector,
            NAME,
            SYMBOL,
            owner
        );
        ERC1967Proxy harnessProxy = new ERC1967Proxy(address(harnessImpl), initData);
        ShareOFTHarness harness = ShareOFTHarness(address(harnessProxy));
        
        harness.mint(user2, 100 ether);
        
        assertEq(harness.balanceOf(user2), 100 ether);
    }
    
    function test_Mint_RevertIf_ToFrozenAddress() public {
        ShareOFTHarness harnessImpl = new ShareOFTHarness(address(endpoint), address(compliance));
        bytes memory initData = abi.encodeWithSelector(
            dreShareOFT.initialize.selector,
            NAME,
            SYMBOL,
            owner
        );
        ERC1967Proxy harnessProxy = new ERC1967Proxy(address(harnessImpl), initData);
        ShareOFTHarness harness = ShareOFTHarness(address(harnessProxy));
        
        vm.prank(address(this));
        compliance.freeze(user2);
        
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.FrozenAddress.selector, user2));
        harness.mint(user2, 100 ether);
    }
    
    function test_Mint_RevertIf_ToSanctionedAddress() public {
        ShareOFTHarness harnessImpl = new ShareOFTHarness(address(endpoint), address(compliance));
        bytes memory initData = abi.encodeWithSelector(
            dreShareOFT.initialize.selector,
            NAME,
            SYMBOL,
            owner
        );
        ERC1967Proxy harnessProxy = new ERC1967Proxy(address(harnessImpl), initData);
        ShareOFTHarness harness = ShareOFTHarness(address(harnessProxy));
        
        SanctionsListMock list = new SanctionsListMock();
        compliance.setSanctionsList(address(list));
        vm.prank(address(this));
        list.setSanctioned(user2, true);
        
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.SanctionedAddress.selector, user2));
        harness.mint(user2, 100 ether);
    }

    // ============ LZ _credit quarantine (bypass validation to avoid funds in limbo) ============
    // When recipient is frozen/sanctioned between source burn and destination mint, _credit()
    // still mints to them via ERC20Upgradeable._update (bypass), then transfer/send remain blocked.

    function test_Credit_MintsToFrozenAddress_ThenTransferReverts() public {
        ShareOFTHarness harnessImpl = new ShareOFTHarness(address(endpoint), address(compliance));
        bytes memory initData = abi.encodeWithSelector(
            dreShareOFT.initialize.selector,
            NAME,
            SYMBOL,
            owner
        );
        ERC1967Proxy harnessProxy = new ERC1967Proxy(address(harnessImpl), initData);
        ShareOFTHarness harness = ShareOFTHarness(address(harnessProxy));
        harness.mint(user1, INITIAL_SUPPLY);

        vm.prank(address(this));
        compliance.freeze(user2);

        // _credit (LZ path) bypasses _validateAddress: mint succeeds
        uint256 amount = 50 ether;
        uint256 received = harness.credit(user2, amount, 0);
        assertEq(received, amount);
        assertEq(harness.balanceOf(user2), amount);

        // Tokens are quarantined: transfer from user2 reverts
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.FrozenAddress.selector, user2));
        harness.transfer(user1, 1 ether);
    }

    function test_Credit_MintsToSanctionedAddress_ThenTransferReverts() public {
        ShareOFTHarness harnessImpl = new ShareOFTHarness(address(endpoint), address(compliance));
        bytes memory initData = abi.encodeWithSelector(
            dreShareOFT.initialize.selector,
            NAME,
            SYMBOL,
            owner
        );
        ERC1967Proxy harnessProxy = new ERC1967Proxy(address(harnessImpl), initData);
        ShareOFTHarness harness = ShareOFTHarness(address(harnessProxy));
        harness.mint(user1, INITIAL_SUPPLY);

        SanctionsListMock list = new SanctionsListMock();
        compliance.setSanctionsList(address(list));
        vm.prank(address(this));
        list.setSanctioned(user2, true);

        // _credit (LZ path) bypasses _validateAddress: mint succeeds
        uint256 amount = 50 ether;
        uint256 received = harness.credit(user2, amount, 0);
        assertEq(received, amount);
        assertEq(harness.balanceOf(user2), amount);

        // Tokens are quarantined: transfer from user2 reverts
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.SanctionedAddress.selector, user2));
        harness.transfer(user1, 1 ether);
    }
    
    // ============ Burn Tests ============
    
    function test_Burn() public {
        ShareOFTHarness harnessImpl = new ShareOFTHarness(address(endpoint), address(compliance));
        bytes memory initData = abi.encodeWithSelector(
            dreShareOFT.initialize.selector,
            NAME,
            SYMBOL,
            owner
        );
        ERC1967Proxy harnessProxy = new ERC1967Proxy(address(harnessImpl), initData);
        ShareOFTHarness harness = ShareOFTHarness(address(harnessProxy));
        
        harness.mint(user1, INITIAL_SUPPLY);
        
        uint256 burnAmount = 100 ether;
        uint256 initialBalance = harness.balanceOf(user1);
        
        harness.burn(user1, burnAmount);
        
        assertEq(harness.balanceOf(user1), initialBalance - burnAmount);
    }
    
    function test_Burn_RevertIf_FromFrozenAddress() public {
        ShareOFTHarness harnessImpl = new ShareOFTHarness(address(endpoint), address(compliance));
        bytes memory initData = abi.encodeWithSelector(
            dreShareOFT.initialize.selector,
            NAME,
            SYMBOL,
            owner
        );
        ERC1967Proxy harnessProxy = new ERC1967Proxy(address(harnessImpl), initData);
        ShareOFTHarness harness = ShareOFTHarness(address(harnessProxy));
        
        harness.mint(user1, INITIAL_SUPPLY);
        
        vm.prank(address(this));
        compliance.freeze(user1);
        
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.FrozenAddress.selector, user1));
        harness.burn(user1, 100 ether);
    }
    
    function test_Burn_RevertIf_FromSanctionedAddress() public {
        ShareOFTHarness harnessImpl = new ShareOFTHarness(address(endpoint), address(compliance));
        bytes memory initData = abi.encodeWithSelector(
            dreShareOFT.initialize.selector,
            NAME,
            SYMBOL,
            owner
        );
        ERC1967Proxy harnessProxy = new ERC1967Proxy(address(harnessImpl), initData);
        ShareOFTHarness harness = ShareOFTHarness(address(harnessProxy));

        harness.mint(user1, INITIAL_SUPPLY);

        SanctionsListMock list = new SanctionsListMock();
        compliance.setSanctionsList(address(list));
        vm.prank(address(this));
        list.setSanctioned(user1, true);

        vm.expectRevert(abi.encodeWithSelector(IdreUSD.SanctionedAddress.selector, user1));
        harness.burn(user1, 100 ether);
    }
    
    // ============ Upgrade Tests ============
    
    function test_Upgrade() public {
        dreShareOFT newImplementation = new dreShareOFT(address(endpoint), address(compliance));

        // Upgrade
        vm.prank(owner);
        shareOFT.upgradeToAndCall(address(newImplementation), "");
        
        // Verify token still works
        assertEq(shareOFT.name(), NAME);
        assertEq(shareOFT.balanceOf(user1), 0); // No tokens minted in setUp
    }
    
    function test_Upgrade_RevertIf_NotOwner() public {
        dreShareOFT newImplementation = new dreShareOFT(address(endpoint), address(compliance));
        
        vm.expectRevert();
        shareOFT.upgradeToAndCall(address(newImplementation), "");
    }
    
    // ============ Edge Cases ============
    
    function test_ValidateAddress_SkipsZeroAddress() public {
        ShareOFTHarness harnessImpl = new ShareOFTHarness(address(endpoint), address(compliance));
        bytes memory initData = abi.encodeWithSelector(
            dreShareOFT.initialize.selector,
            NAME,
            SYMBOL,
            owner
        );
        ERC1967Proxy harnessProxy = new ERC1967Proxy(address(harnessImpl), initData);
        ShareOFTHarness harness = ShareOFTHarness(address(harnessProxy));
        
        // Minting should work (from address(0))
        harness.mint(user2, 100 ether);
        
        // Burning should work (to address(0))
        harness.burn(user2, 50 ether);
        
        assertEq(harness.balanceOf(user2), 50 ether);
    }
    
    function test_Transfer_WorksAfterUnfreeze() public {
        ShareOFTHarness harness = _createHarnessWithTokens();

        // Freeze user1
        vm.prank(address(this));
        compliance.freeze(user1);

        // Transfer should fail
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.FrozenAddress.selector, user1));
        harness.transfer(user2, 50 ether);

        // Unfreeze user1 (on compliance mock)
        vm.prank(address(this));
        compliance.unfreeze(user1);

        // Transfer should work now
        vm.prank(user1);
        bool success = harness.transfer(user2, 50 ether);
        assertTrue(success);

        assertEq(harness.balanceOf(user2), 50 ether);
    }

}
