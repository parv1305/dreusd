// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { DeployDreUSDs } from "../script/dreUSDs/DeployDreUSDs.s.sol";
import { dreUSDs } from "../contracts/dreUSDs.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";

/**
 * @title DeployDreUSDsTest
 * @notice Tests the dreUSDs deploy script logic. dreUSDs must only be deployed on Base chains.
 */
contract DeployDreUSDsTest is Test, DeployDreUSDs {
    function test_DeployDreUSDs() public {
        // Set chain ID to Base Sepolia (84532) - dreUSDs must only be deployed on Base chains
        vm.chainId(84532);
        
        address defaultAdmin = makeAddr("defaultAdmin");
        MockERC20 dreUSD = new MockERC20("dreUSD", "dreUSD", 18);

        dreUSDs vault = _deployDreUSDs(address(dreUSD), defaultAdmin);
        address proxyAddr = address(vault);

        assertGt(proxyAddr.code.length, 0, "proxy should have code");
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), defaultAdmin), "defaultAdmin should have DEFAULT_ADMIN_ROLE");
        assertTrue(vault.hasRole(vault.UPGRADER_ROLE(), defaultAdmin), "defaultAdmin should have UPGRADER_ROLE");
        assertTrue(vault.hasRole(vault.PAUSER_ROLE(), defaultAdmin), "defaultAdmin should have PAUSER_ROLE");
        assertEq(vault.name(), "dreUSDs");
        assertEq(vault.symbol(), "dreUSDs");
        assertEq(address(vault.asset()), address(dreUSD));
    }
}
