// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { DeployDreUSDOracle } from "../script/oracle/DeployDreUSDOracle.s.sol";
import { Config } from "../script/Config.sol";
import { dreUSDOracle } from "../contracts/dreUSDOracle.sol";

/**
 * @title DeployDreUSDOracleTest
 * @notice Tests the dreUSDOracle deploy script logic.
 */
contract DeployDreUSDOracleTest is Test, DeployDreUSDOracle {
    function test_DeployDreUSDOracle() public {
        vm.chainId(Config.BASE_SEPOLIA);
        vm.warp(block.timestamp + 1 days);

        Config.ChainConfig memory cfg = Config.getChainConfig(block.chainid);
        dreUSDOracle oracle = _deployDreUSDOracle(cfg);
        address proxyAddr = address(oracle);

        assertGt(proxyAddr.code.length, 0, "proxy should have code");
        assertTrue(oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), cfg.defaultAdmin), "defaultAdmin should have DEFAULT_ADMIN_ROLE");
        assertTrue(oracle.hasRole(oracle.UPGRADER_ROLE(), cfg.upgrader), "upgrader should have UPGRADER_ROLE");
        assertTrue(oracle.hasRole(oracle.MODERATOR_ROLE(), cfg.moderator), "moderator should have MODERATOR_ROLE");
        assertNotEq(oracle.sequencerUptimeFeed(), address(0), "sequencer feed should be set");
        assertEq(oracle.gracePeriod(), 3600, "Grace period should be set to 3600 seconds");
    }

    function test_DeployDreUSDOracle_BaseMainnet() public {
        vm.chainId(Config.BASE_MAINNET);
        Config.ChainConfig memory cfg = Config.getChainConfig(block.chainid);
        if (cfg.defaultAdmin == address(0)) {
            cfg.defaultAdmin = makeAddr("defaultAdmin");
            cfg.upgrader = makeAddr("upgrader");
            cfg.moderator = makeAddr("moderator");
        }

        dreUSDOracle oracle = _deployDreUSDOracle(cfg);
        address proxyAddr = address(oracle);

        assertGt(proxyAddr.code.length, 0, "proxy should have code");
        assertEq(
            oracle.sequencerUptimeFeed(),
            0xBCF85224fc0756B9Fa45aA7892530B47e10b6433,
            "Base Mainnet should have sequencer feed set"
        );
        assertEq(oracle.gracePeriod(), 3600, "Grace period should be set to 3600 seconds");
    }
}
