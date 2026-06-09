// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { Config } from "../script/Config.sol";
import { DeployDreUSD } from "../script/dreUSD/DeployDreUSD.s.sol";
import { dreUSD } from "../contracts/dreUSD.sol";

/**
 * @title DeployDreUSDTest
 * @notice Tests the dreUSD deploy script logic. Uses a fork so the LayerZero
 *         endpoint exists (initialize() calls it); run with:
 *         forge test --match-path test/DeployDreUSD.t.sol --fork-url <RPC_URL>
 */
contract DeployDreUSDTest is Test, DeployDreUSD {
    uint256 constant BASE_SEPOLIA_CHAIN_ID = 84532;
    string constant BASE_SEPOLIA_RPC = "https://sepolia.base.org";

    function test_DeployDreUSD_OnFork() public {
        vm.createSelectFork(BASE_SEPOLIA_RPC);
        assertEq(block.chainid, BASE_SEPOLIA_CHAIN_ID);

        address endpoint = Config.getLzEndpoint(block.chainid);
        require(endpoint != address(0), "LZ endpoint not set for chain");
        address defaultAdmin = makeAddr("defaultAdmin");
        address upgrader = makeAddr("upgrader");
        address guardian = makeAddr("guardian");
        address factory = Config.DEFAULT_CREATE2_FACTORY;

        dreUSD token = _deployDreUSD(endpoint, defaultAdmin, upgrader, guardian, factory);
        address proxyAddr = address(token);

        assertGt(proxyAddr.code.length, 0, "proxy should have code");

        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), defaultAdmin), "defaultAdmin should have DEFAULT_ADMIN_ROLE");
        assertTrue(token.hasRole(token.UPGRADER_ROLE(), upgrader), "upgrader should have UPGRADER_ROLE");
        assertTrue(token.hasRole(token.GUARDIAN_ROLE(), guardian), "guardian should have GUARDIAN_ROLE");
        assertEq(token.name(), "dreUSD");
        assertEq(token.symbol(), "dreUSD");
    }
}
