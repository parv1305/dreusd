// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {dreUSD} from "../contracts/dreUSD.sol";
import {IdreUSD} from "../contracts/interfaces/IdreUSD.sol";
import {SanctionsListMock} from "../contracts/mocks/SanctionsListMock.sol";
import {ManagerMock} from "../contracts/mocks/ManagerMock.sol";
import {EndpointV2Mock} from "../contracts/mocks/EndpointV2Mock.sol";
import {SanctionsListWhitelistWrapper} from "../contracts/whitelist/SanctionsListWhitelistWrapper.sol";

/**
 * @title SanctionsListWhitelistWrapperTest
 * @dev Integration tests: `dreUSD` calls `isSanctioned` on the wrapper. Non-whitelisted users are
 *      always treated as sanctioned (mint reverts). Whitelisted users succeed only when the
 *      underlying mock reports not sanctioned.
 */
contract SanctionsListWhitelistWrapperTest is Test {
    dreUSD public token;
    EndpointV2Mock public endpoint;
    ManagerMock public manager;
    SanctionsListMock public underlyingOracle;
    SanctionsListWhitelistWrapper public wrapper;

    address public defaultAdmin;
    address public guardian;
    address public upgrader;
    address public user;
    address public moderator;

    bytes32 public constant MODERATOR_ROLE = keccak256("MODERATOR_ROLE");

    uint256 constant INITIAL_SUPPLY = 1000 ether;

    function setUp() public {
        endpoint = new EndpointV2Mock();
        manager = new ManagerMock();
        underlyingOracle = new SanctionsListMock();

        defaultAdmin = makeAddr("defaultAdmin");
        guardian = makeAddr("guardian");
        upgrader = makeAddr("upgrader");
        user = makeAddr("user");
        moderator = makeAddr("moderator");

        dreUSD implementation = new dreUSD(address(endpoint));
        bytes memory initData = abi.encodeWithSelector(dreUSD.initialize.selector, defaultAdmin, upgrader, guardian);
        token = dreUSD(address(new ERC1967Proxy(address(implementation), initData)));

        vm.startPrank(defaultAdmin);
        token.setDreUSDManager(address(manager));
        wrapper = new SanctionsListWhitelistWrapper(underlyingOracle, defaultAdmin);
        wrapper.grantRole(MODERATOR_ROLE, moderator);
        token.setSanctionsList(address(wrapper));
        vm.stopPrank();
    }

    /// @dev Default path: not allowlisted, so wrapper `isSanctioned` is true without reading the oracle.
    function test_Mint_RevertWhen_NotWhitelisted() public {
        assertFalse(wrapper.isWhitelisted(user));

        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.SanctionedAddress.selector, user));
        token.mint(user, 1 ether);
    }

    /// @dev Allowlisted but underlying marks sanctioned; wrapper still reports sanctioned.
    function test_Mint_RevertWhen_WhitelistedAndSanctioned() public {
        vm.prank(moderator);
        wrapper.addToWhitelist(user);
        
        vm.prank(address(this));
        underlyingOracle.setSanctioned(user, true);
        assertTrue(wrapper.isSanctioned(user));

        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.SanctionedAddress.selector, user));
        token.mint(user, 1 ether);
    }

    /// @dev Not allowlisted: sanctioned even if underlying were clear (oracle irrelevant here).
    function test_Mint_RevertWhen_NotWhitelistedAndSanctioned() public {
        vm.prank(address(this));
        underlyingOracle.setSanctioned(user, true);
        assertTrue(wrapper.isSanctioned(user));

        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(IdreUSD.SanctionedAddress.selector, user));
        token.mint(user, 1 ether);
    }

    /// @dev Allowlisted and underlying not sanctioned; mint uses oracle result (not sanctioned).
    function test_Mint_SucceedsWhen_WhitelistedAndNotSanctioned() public {
        vm.prank(moderator);
        wrapper.addToWhitelist(user);
        assertFalse(wrapper.isSanctioned(user));

        vm.prank(address(manager));
        token.mint(user, 1 ether);
        assertEq(token.balanceOf(user), 1 ether);
    }
}
