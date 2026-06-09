// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { DeployDreRewardsDistributor } from "../script/rewardsDistributor/DeployDreRewardsDistributor.s.sol";
import { dreRewardsDistributor } from "../contracts/dreRewardsDistributor.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";

/**
 * @title DeployDreRewardsDistributorTest
 * @notice Tests the dreRewardsDistributor deploy script logic.
 */
contract DeployDreRewardsDistributorTest is Test, DeployDreRewardsDistributor {
    function test_DeployDreRewardsDistributor() public {
        vm.chainId(84532);
        address defaultAdmin = makeAddr("defaultAdmin");
        address upgraderAddress = makeAddr("upgrader");
        address pauserAddress = makeAddr("pauser");
        MockERC20 dreUSD = new MockERC20("dreUSD", "dreUSD", 18);
        address vault = makeAddr("vault");

        dreRewardsDistributor distributor = _deployDreRewardsDistributor(
            address(dreUSD),
            vault,
            defaultAdmin,
            upgraderAddress,
            pauserAddress
        );
        address proxyAddr = address(distributor);

        assertGt(proxyAddr.code.length, 0, "proxy should have code");
        assertEq(distributor.dreUSD(), address(dreUSD));
        assertEq(distributor.vault(), vault);
        assertEq(distributor.rewards(), 0);
        assertEq(distributor.VEST_PERIOD(), 7 days);
        assertTrue(distributor.hasRole(distributor.DEFAULT_ADMIN_ROLE(), defaultAdmin), "defaultAdmin should have DEFAULT_ADMIN_ROLE");
        assertTrue(distributor.hasRole(distributor.UPGRADER_ROLE(), upgraderAddress), "upgraderAddress should have UPGRADER_ROLE");
        assertTrue(distributor.hasRole(distributor.PAUSER_ROLE(), pauserAddress), "pauserAddress should have PAUSER_ROLE");
        assertFalse(distributor.hasRole(distributor.UPGRADER_ROLE(), defaultAdmin), "defaultAdmin should NOT have UPGRADER_ROLE");
        assertFalse(distributor.hasRole(distributor.PAUSER_ROLE(), defaultAdmin), "defaultAdmin should NOT have PAUSER_ROLE");
    }
}
