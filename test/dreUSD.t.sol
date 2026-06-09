// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {dreUSD} from "../contracts/dreUSD.sol";
import {IdreUSD} from "../contracts/interfaces/IdreUSD.sol";
import {SanctionsListMock} from "../contracts/mocks/SanctionsListMock.sol";
import {ManagerMock} from "../contracts/mocks/ManagerMock.sol";
import {EndpointV2Mock} from "../contracts/mocks/EndpointV2Mock.sol";

/**
 * @title DreUSDCreditHarness
 * @dev Exposes internal _credit for testing (LZ cross-chain receive path).
 */
contract DreUSDCreditHarness is dreUSD {
    constructor(address _lzEndpoint) dreUSD(_lzEndpoint) {}

    function credit(address _to, uint256 _amountLD, uint32 _srcEid) external returns (uint256 amountReceivedLD) {
        return _credit(_to, _amountLD, _srcEid);
    }
}

/**
 * @title dreUSDTest
 * @dev Comprehensive test suite for dreUSD token contract
 */
contract dreUSDTest is Test {
    dreUSD public token;
    dreUSD public implementation;
    ERC1967Proxy public proxy;

    /// @dev Same as token but exposes _credit for LZ crediting tests
    DreUSDCreditHarness public tokenHarness;
    ERC1967Proxy public proxyHarness;

    EndpointV2Mock public endpoint;
    ManagerMock public manager;
    SanctionsListMock public sanctionsList;
    
    address public defaultAdmin;
    address public guardian;
    address public upgrader;
    address public user1;
    address public user2;
    address public sanctionedUser;
    address public frozenUser;
    
    // Private keys for signing permits (derived deterministically)
    uint256 public user1PrivateKey;
    uint256 public user2PrivateKey;
    
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    
    uint256 constant INITIAL_SUPPLY = 1000 ether;
    
    event SanctionsListUpdated(address indexed oldSanctionsList, address indexed newSanctionsList);
    event AddressFrozen(address indexed account);
    event AddressUnfrozen(address indexed account);
    
    function setUp() public {
        // Deploy mocks
        endpoint = new EndpointV2Mock();
        manager = new ManagerMock();
        sanctionsList = new SanctionsListMock();

        // Setup addresses and private keys
        defaultAdmin = makeAddr("defaultAdmin");
        guardian = makeAddr("guardian");
        upgrader = makeAddr("upgrader");
        user1PrivateKey = 0x1;
        user1 = vm.addr(user1PrivateKey);
        user2PrivateKey = 0x2;
        user2 = vm.addr(user2PrivateKey);
        sanctionedUser = makeAddr("sanctionedUser");
        frozenUser = makeAddr("frozenUser");
        
        // Deploy implementation
        implementation = new dreUSD(address(endpoint));

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            dreUSD.initialize.selector,
            defaultAdmin,
            upgrader,
            guardian
        );

        proxy = new ERC1967Proxy(address(implementation), initData);
        token = dreUSD(address(proxy));

        vm.startPrank(defaultAdmin);
        token.setDreUSDManager(address(manager));
        vm.stopPrank();
        
        // Mint initial tokens to user1
        vm.prank(address(manager));
        token.mint(user1, INITIAL_SUPPLY);

        // Deploy harness for _credit tests (same setup as token)
        DreUSDCreditHarness implHarness = new DreUSDCreditHarness(address(endpoint));
        proxyHarness = new ERC1967Proxy(address(implHarness), initData);
        tokenHarness = DreUSDCreditHarness(address(proxyHarness));
        vm.startPrank(defaultAdmin);
        tokenHarness.setDreUSDManager(address(manager));
        vm.stopPrank();
        vm.prank(address(manager));
        tokenHarness.mint(user1, INITIAL_SUPPLY);
    }

    // ============ Initialization Tests ============
    
    function test_Initialize()  public {
        assertEq(token.name(), "dreUSD");
        assertEq(token.symbol(), "dreUSD");
        assertEq(token.decimals(), 18);
        assertEq(token.dreUSDManager(), address(manager));
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, defaultAdmin));
        assertTrue(token.hasRole(UPGRADER_ROLE, upgrader));
        assertTrue(token.hasRole(GUARDIAN_ROLE, guardian));
    }

    function test_Initialize_RevertIf_AlreadyInitialized() public {
        vm.expectRevert();
        token.initialize(defaultAdmin, upgrader, guardian);
    }

    function test_Initialize_RevertIf_DefaultAdminIsZeroAddress() public {
        bytes memory initData = abi.encodeWithSelector(
            dreUSD.initialize.selector,
            address(0),
            upgrader,
            guardian
        );
        vm.expectRevert(IdreUSD.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_Initialize_RevertIf_UpgraderIsZeroAddress() public {
        bytes memory initData = abi.encodeWithSelector(
            dreUSD.initialize.selector,
            defaultAdmin,
            address(0),
            guardian
        );
        vm.expectRevert(IdreUSD.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_Initialize_RevertIf_GuardianIsZeroAddress() public {
        bytes memory initData = abi.encodeWithSelector(
            dreUSD.initialize.selector,
            defaultAdmin,
            upgrader,
            address(0)
        );
        vm.expectRevert(IdreUSD.ZeroAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }
    
    // ============ Mint Tests ============
    
    function test_Mint() public {
        uint256 amount = 100 ether;
        vm.prank(address(manager));
        token.mint(user2, amount);
        
        assertEq(token.balanceOf(user2), amount);
        assertEq(token.totalSupply(), INITIAL_SUPPLY + amount);
    }
    
    function test_Mint_RevertIf_NotManager() public {
        vm.expectRevert(IdreUSD.InvalidCaller.selector);
        vm.prank(user2);
        token.mint(user2, 100 ether);
    }
    
    function test_Mint_RevertIf_ToFrozenAddress() public {
        vm.prank(guardian);
        token.freeze(user2);
        
        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.FrozenAddress.selector, user2));
        token.mint(user2, 100 ether);
    }
    
    function test_Mint_RevertIf_ToSanctionedAddress() public {
        vm.prank(defaultAdmin);
        token.setSanctionsList(address(sanctionsList));
        
        vm.prank(address(this));
        sanctionsList.setSanctioned(user2, true);
        
        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.SanctionedAddress.selector, user2));
        token.mint(user2, 100 ether);
    }
    
    // ============ Burn Tests ============
    
    function test_Burn() public {
        uint256 burnAmount = 100 ether;
        uint256 initialBalance = token.balanceOf(user1);
        
        vm.prank(address(manager));
        token.burn(user1, burnAmount);
        
        assertEq(token.balanceOf(user1), initialBalance - burnAmount);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - burnAmount);
    }
    
    function test_Burn_RevertIf_NotManager() public {
        vm.expectRevert(IdreUSD.InvalidCaller.selector);
        vm.prank(user2);
        token.burn(user1, 100 ether);
    }
    
    function test_Burn_RevertIf_FromFrozenAddress() public {
        vm.prank(guardian);
        token.freeze(user1);
        
        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.FrozenAddress.selector, user1));
        token.burn(user1, 100 ether);
    }
    
    function test_Burn_RevertIf_FromSanctionedAddress() public {
        vm.prank(defaultAdmin);
        token.setSanctionsList(address(sanctionsList));
        
        vm.prank(address(this));
        sanctionsList.setSanctioned(user1, true);
        
        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.SanctionedAddress.selector, user1));
        token.burn(user1, 100 ether);
    }
    
    // ============ Transfer Tests ============
    
    function test_Transfer() public {
        uint256 amount = 50 ether;
        vm.prank(user1);
        bool success = token.transfer(user2, amount);
        assertTrue(success);
        
        assertEq(token.balanceOf(user1), INITIAL_SUPPLY - amount);
        assertEq(token.balanceOf(user2), amount);
    }
    
    function test_Transfer_RevertIf_FromFrozenAddress() public {
        vm.prank(guardian);
        token.freeze(user1);
        
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.FrozenAddress.selector, user1));
        token.transfer(user2, 50 ether);
    }
    
    function test_Transfer_RevertIf_ToFrozenAddress() public {
        vm.prank(guardian);
        token.freeze(user2);
        
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.FrozenAddress.selector, user2));
        token.transfer(user2, 50 ether);
    }
    
    function test_Transfer_RevertIf_FromSanctionedAddress() public {
        vm.prank(defaultAdmin);
        token.setSanctionsList(address(sanctionsList));
        
        vm.prank(address(this));
        sanctionsList.setSanctioned(user1, true);
        
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.SanctionedAddress.selector, user1));
        token.transfer(user2, 50 ether);
    }
    
    function test_Transfer_RevertIf_ToSanctionedAddress() public {
        vm.prank(defaultAdmin);
        token.setSanctionsList(address(sanctionsList));
        
        vm.prank(address(this));
        sanctionsList.setSanctioned(user2, true);
        
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.SanctionedAddress.selector, user2));
        token.transfer(user2, 50 ether);
    }
    
    // ============ TransferFrom Tests ============
    
    function test_TransferFrom() public {
        uint256 amount = 50 ether;
        vm.prank(user1);
        token.approve(user2, amount);
        
        vm.prank(user2);
        bool success = token.transferFrom(user1, user2, amount);
        assertTrue(success);
        
        assertEq(token.balanceOf(user1), INITIAL_SUPPLY - amount);
        assertEq(token.balanceOf(user2), amount);
    }
    
    function test_TransferFrom_RevertIf_FromFrozenAddress() public {
        uint256 amount = 50 ether;
        vm.prank(user1);
        token.approve(user2, amount);
        
        vm.prank(guardian);
        token.freeze(user1);
        
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.FrozenAddress.selector, user1));
        token.transferFrom(user1, user2, amount);
    }
    
    function test_TransferFrom_RevertIf_ToFrozenAddress() public {
        uint256 amount = 50 ether;
        vm.prank(user1);
        token.approve(user2, amount);
        
        vm.prank(guardian);
        token.freeze(user2);
        
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.FrozenAddress.selector, user2));
        token.transferFrom(user1, user2, amount);
    }
    
    // ============ Permit Tests ============
    
    function test_Permit() public {
        uint256 amount = 50 ether;
        uint256 deadline = block.timestamp + 1 days;
        uint256 nonce = token.nonces(user1);
        
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("dreUSD")),
                keccak256(bytes("1")),
                block.chainid,
                address(token)
            )
        );
        
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                user1,
                user2,
                amount,
                nonce,
                deadline
            )
        );
        
        bytes32 hash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1PrivateKey, hash);
        
        token.permit(user1, user2, amount, deadline, v, r, s);
        
        assertEq(token.allowance(user1, user2), amount);
        assertEq(token.nonces(user1), nonce + 1);
    }
    
    // ============ Freeze Tests ============
    
    function test_Freeze() public {
        vm.prank(guardian);
        vm.expectEmit(true, false, false, false);
        emit AddressFrozen(user1);
        token.freeze(user1);
        
        assertTrue(token.frozen(user1));
    }
    
    function test_Freeze_RevertIf_NotGuardian() public {
        vm.expectRevert();
        token.freeze(user1);
    }
    
    function test_Freeze_RevertIf_ZeroAddress() public {
        vm.prank(guardian);
        vm.expectRevert(IdreUSD.ZeroAddress.selector);
        token.freeze(address(0));
    }

    function test_Freeze_RevertIf_AlreadyFrozen() public {
        vm.prank(guardian);
        token.freeze(user1);
        assertTrue(token.frozen(user1));

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.AlreadyFrozen.selector, user1));
        token.freeze(user1);
    }
    
    function test_Unfreeze() public {
        vm.prank(guardian);
        token.freeze(user1);
        
        vm.prank(guardian);
        vm.expectEmit(true, false, false, false);
        emit AddressUnfrozen(user1);
        token.unfreeze(user1);
        
        assertFalse(token.frozen(user1));
    }
    
    function test_Unfreeze_RevertIf_NotGuardian() public {
        vm.expectRevert();
        token.unfreeze(user1);
    }
    
    function test_Unfreeze_RevertIf_ZeroAddress() public {
        vm.prank(guardian);
        vm.expectRevert(IdreUSD.ZeroAddress.selector);
        token.unfreeze(address(0));
    }

    function test_Unfreeze_RevertIf_AlreadyUnfrozen() public {
        vm.startPrank(guardian);
        token.freeze(user1);
        assertTrue(token.frozen(user1));

        token.unfreeze(user1);
        assertEq(token.frozen(user1), false);
        

        vm.expectRevert(abi.encodeWithSelector(IdreUSD.AlreadyUnfrozen.selector, user1));
        token.unfreeze(user1);
        vm.stopPrank();
    }
    
    // ============ Manager Role Tests ============
    
    function test_SetDreUSDManager() public {
        ManagerMock newManager = new ManagerMock();

        vm.expectEmit(true, true, false, false);
        emit IdreUSD.DreUSDManagerUpdated(address(manager), address(newManager));

        vm.prank(defaultAdmin);
        token.setDreUSDManager(address(newManager));

        assertEq(token.dreUSDManager(), address(newManager));
        vm.prank(address(newManager));
        token.mint(user2, 100 ether);
        assertEq(token.balanceOf(user2), 100 ether);
    }
    
    function test_RevokeManagerRevertsMint() public {
        vm.prank(defaultAdmin);
        token.setDreUSDManager(user2); // manager no longer allowed to mint/burn
        assertEq(token.dreUSDManager(), user2);

        vm.prank(address(manager));
        vm.expectRevert(IdreUSD.InvalidCaller.selector);
        token.mint(user1, 100 ether);
    }
    
    // ============ SanctionsList Tests ============
    
    function test_SetSanctionsList() public {
        SanctionsListMock newSanctionsList = new SanctionsListMock();
        
        vm.prank(defaultAdmin);
        vm.expectEmit(true, true, false, false);
        emit SanctionsListUpdated(address(0), address(newSanctionsList));
        token.setSanctionsList(address(newSanctionsList));
        
        assertEq(token.sanctionsList(), address(newSanctionsList));
    }
    
    function test_SetSanctionsList_RevertIf_NotAdmin() public {
        SanctionsListMock newSanctionsList = new SanctionsListMock();
        
        vm.expectRevert();
        token.setSanctionsList(address(newSanctionsList));
    }

    function test_SetSanctionsList_RevertIf_SameValue() public {
        vm.prank(defaultAdmin);
        token.setSanctionsList(address(sanctionsList));
        assertEq(token.sanctionsList(), address(sanctionsList));

        vm.prank(defaultAdmin);
        vm.expectRevert(IdreUSD.SameSanctionsList.selector);
        token.setSanctionsList(address(sanctionsList));
    }
    
    function test_SanctionsList_CanBeZeroAddress() public {
        vm.startPrank(defaultAdmin);
        token.setSanctionsList(address(sanctionsList));
        token.setSanctionsList(address(0));
        assertEq(token.sanctionsList(), address(0));
    }
    
    // ============ Access Control Tests ============
    
    function test_Roles()  public  {
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, defaultAdmin));
        assertTrue(token.hasRole(UPGRADER_ROLE, upgrader));
        assertTrue(token.hasRole(GUARDIAN_ROLE, guardian));
        assertFalse(token.hasRole(GUARDIAN_ROLE, user1));
    }
    
    // ============ Upgrade Tests ============
    
    function test_Upgrade() public {
        // Deploy new implementation
        dreUSD newImplementation = new dreUSD(address(endpoint));
        
        // Upgrade
        vm.prank(upgrader);
        token.upgradeToAndCall(address(newImplementation), "");
        
        // Verify token still works
        assertEq(token.name(), "dreUSD");
        assertEq(token.balanceOf(user1), INITIAL_SUPPLY);
    }
    
    function test_Upgrade_RevertIf_NotUpgrader() public {
        dreUSD newImplementation = new dreUSD(address(endpoint));
        
        vm.expectRevert();
        token.upgradeToAndCall(address(newImplementation), "");
    }
    
    // ============ Edge Cases ============
    
    function test_MintToZeroAddress() public {
        // Minting to zero address should work (for burning via mint)
        vm.prank(address(manager));
        vm.expectRevert(); // ERC20 doesn't allow minting to zero
        token.mint(address(0), 100 ether);
    }
    
    function test_BurnFromZeroAddress() public {
        // Burning from zero address should revert
        vm.prank(address(manager));
        vm.expectRevert(); // ERC20 doesn't allow burning from zero
        token.burn(address(0), 100 ether);
    }
    
    function test_SanctionsList_NotSet() public {
        // When sanctions list is not set, transfers should work
        assertEq(token.sanctionsList(), address(0));
        
        vm.prank(user1);
        bool success = token.transfer(user2, 50 ether);
        assertTrue(success);
        
        assertEq(token.balanceOf(user2), 50 ether);
    }
    
    function test_SanctionsList_ReturnsFalse() public {
        vm.prank(defaultAdmin);
        token.setSanctionsList(address(sanctionsList));
        
        // Sanctions list returns false for non-sanctioned address
        assertFalse(sanctionsList.isSanctioned(user1));
        
        vm.prank(user1);
        bool success = token.transfer(user2, 50 ether);
        assertTrue(success);
        
        assertEq(token.balanceOf(user2), 50 ether);
    }

    // ============ validateAddress Tests ============
    
    function test_ValidateAddress_Succeeds_ForNormalAddress() public  {
        // user1 is neither frozen nor sanctioned by default
        token.validateAddress(user1);
    }
    
    function test_ValidateAddress_RevertIf_FrozenAddress() public {
        vm.prank(guardian);
        token.freeze(user1);

        vm.expectRevert(abi.encodeWithSelector(IdreUSD.FrozenAddress.selector, user1));
        token.validateAddress(user1);
    }

    // ============ Ownership Tests ============

    function test_TransferOwnership_Succeeds_WhenDefaultAdmin() public {
        assertEq(token.owner(), defaultAdmin);
        address newOwner = makeAddr("newOwner");
        vm.prank(defaultAdmin);
        token.transferOwnership(newOwner);
        assertEq(token.owner(), newOwner);
    }

    function test_TransferOwnership_RevertIf_NotDefaultAdmin() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, DEFAULT_ADMIN_ROLE)
        );
        token.transferOwnership(newOwner);
        assertEq(token.owner(), defaultAdmin);
    }

    function test_RenounceOwnership_Succeeds_WhenDefaultAdmin() public {
        assertEq(token.owner(), defaultAdmin);
        vm.prank(defaultAdmin);
        token.renounceOwnership();
        assertEq(token.owner(), address(0));
    }

    function test_RenounceOwnership_RevertIf_NotDefaultAdmin() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, DEFAULT_ADMIN_ROLE)
        );
        token.renounceOwnership();
        assertEq(token.owner(), defaultAdmin);
    }

    /// @dev DEFAULT_ADMIN_ROLE can transfer ownership even when not the current owner (no stuck ownership).
    function test_TransferOwnership_Twice_DefaultAdminCanTransferAwayFromNonAdmin() public {
        address owner1 = makeAddr("owner1");
        address owner2 = makeAddr("owner2");
        assertEq(token.owner(), defaultAdmin);

        vm.prank(defaultAdmin);
        token.transferOwnership(owner1);
        assertEq(token.owner(), owner1);

        // defaultAdmin is no longer owner but has DEFAULT_ADMIN_ROLE; can still transfer again
        vm.prank(defaultAdmin);
        token.transferOwnership(owner2);
        assertEq(token.owner(), owner2);
    }

    /// @dev After two transfers, a third transfer by DEFAULT_ADMIN_ROLE still works.
    function test_TransferOwnership_ThreeTimes_Succeeds() public {
        address owner1 = makeAddr("owner1");
        address owner2 = makeAddr("owner2");
        address owner3 = makeAddr("owner3");

        vm.prank(defaultAdmin);
        token.transferOwnership(owner1);
        assertEq(token.owner(), owner1);

        vm.prank(defaultAdmin);
        token.transferOwnership(owner2);
        assertEq(token.owner(), owner2);

        vm.prank(defaultAdmin);
        token.transferOwnership(owner3);
        assertEq(token.owner(), owner3);
    }

    // ============ _credit (LZ cross-chain receive) Tests ============

    function test_Credit_MintsToValidAddress() public {
        uint256 amount = 100 ether;
        uint256 supplyBefore = tokenHarness.totalSupply();
        uint256 received = tokenHarness.credit(user2, amount, 1);
        assertEq(received, amount);
        assertEq(tokenHarness.balanceOf(user2), amount);
        assertEq(tokenHarness.totalSupply(), supplyBefore + amount);
    }

    function test_Credit_MintsToFrozenAddress_Quarantined() public {
        vm.prank(guardian);
        tokenHarness.freeze(user2);
        uint256 amount = 100 ether;
        uint256 received = tokenHarness.credit(user2, amount, 1);
        assertEq(received, amount);
        assertEq(tokenHarness.balanceOf(user2), amount);
        // Quarantined: recipient cannot transfer
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.FrozenAddress.selector, user2));
        tokenHarness.transfer(user1, 1 ether);
    }

    function test_Credit_MintsToSanctionedAddress_Quarantined() public {
        vm.prank(defaultAdmin);
        tokenHarness.setSanctionsList(address(sanctionsList));
        vm.prank(address(this));
        sanctionsList.setSanctioned(user2, true);
        uint256 amount = 100 ether;
        uint256 received = tokenHarness.credit(user2, amount, 1);
        assertEq(received, amount);
        assertEq(tokenHarness.balanceOf(user2), amount);
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.SanctionedAddress.selector, user2));
        tokenHarness.transfer(user1, 1 ether);
    }

    function test_Credit_ToZeroAddress_MintsToDead() public {
        uint256 amount = 50 ether;
        address dead = address(0xdead);
        tokenHarness.credit(address(0), amount, 1);
        assertEq(tokenHarness.balanceOf(dead), amount);
    }

    function test_Credit_ReturnsAmountReceivedLD() public {
        uint256 amount = 123 ether;
        uint256 received = tokenHarness.credit(user2, amount, 99);
        assertEq(received, amount);
    }

    function test_Credit_ZeroAmount_NoMint() public {
        uint256 supplyBefore = tokenHarness.totalSupply();
        uint256 balanceBefore = tokenHarness.balanceOf(user2);
        uint256 received = tokenHarness.credit(user2, 0, 1);
        assertEq(received, 0);
        assertEq(tokenHarness.totalSupply(), supplyBefore);
        assertEq(tokenHarness.balanceOf(user2), balanceBefore);
    }

    function test_ValidateAddress_RevertIf_SanctionedAddress() public {
        vm.prank(defaultAdmin);
        token.setSanctionsList(address(sanctionsList));

        vm.prank(address(this));
        sanctionsList.setSanctioned(user1, true);

        vm.expectRevert(abi.encodeWithSelector(IdreUSD.SanctionedAddress.selector, user1));
        token.validateAddress(user1);
    }

    function test_ValidateAddress_RevertIf_FrozenAndSanctionedAddress_FrozenTakesPrecedence() public {
        vm.prank(defaultAdmin);
        token.setSanctionsList(address(sanctionsList));

        vm.prank(address(this));
        sanctionsList.setSanctioned(user1, true);

        vm.prank(guardian);
        token.freeze(user1);

        // _validateAddress checks frozen first, so FrozenAddress should be thrown
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.FrozenAddress.selector, user1));
        token.validateAddress(user1);
    }
    
    function test_FreezeAndUnfreeze_MultipleTimes() public {
        vm.prank(guardian);
        token.freeze(user1);
        assertTrue(token.frozen(user1));
        
        vm.prank(guardian);
        token.unfreeze(user1);
        assertFalse(token.frozen(user1));
        
        vm.prank(guardian);
        token.freeze(user1);
        assertTrue(token.frozen(user1));
        
        vm.prank(guardian);
        token.unfreeze(user1);
        assertFalse(token.frozen(user1));
    }
    
    function test_SanctionsList_UpdatedAfterFreeze() public {
        vm.prank(guardian);
        token.freeze(user1);
        
        vm.prank(defaultAdmin);
        token.setSanctionsList(address(sanctionsList));
        
        vm.prank(address(this));
        sanctionsList.setSanctioned(user1, true);
        
        // Both frozen and sanctioned - should revert with FrozenAddress first
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.FrozenAddress.selector, user1));
        token.transfer(user2, 50 ether);
    }
}
