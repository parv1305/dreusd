// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { DeployDreUSDManager } from "../script/dreUSDManager/DeployDreUSDManager.s.sol";
import { dreUSDManager } from "../contracts/dreUSDManager.sol";
import { DreUSDMock } from "../contracts/mocks/DreUSDMock.sol";
import { ERC4626Mock } from "../contracts/mocks/ERC4626Mock.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { DreUSDOracleMock } from "../contracts/mocks/DreUSDOracleMock.sol";
import { WithdrawalNFTMock } from "../contracts/mocks/WithdrawalNFTMock.sol";

/**
 * @title DeployDreUSDManagerTest
 * @notice Tests the dreUSDManager deploy script logic.
 */
contract DeployDreUSDManagerTest is Test, DeployDreUSDManager {
    function test_DeployDreUSDManager() public {
        // Set chain ID to Base Sepolia (84532) - dreUSDManager must only be deployed on Base chains
        vm.chainId(84532);
        
        DreUSDMock dreUSDToken = new DreUSDMock();
        ERC4626Mock dreUSDsVault = new ERC4626Mock(address(dreUSDToken));
        dreUSDsVault.setRewardsDistributor(makeAddr("rewardsDistributor"));
        MockERC20 usdcToken = new MockERC20("USDC", "USDC", 6);
        DreUSDOracleMock oracleMock = new DreUSDOracleMock();
        WithdrawalNFTMock expressNFT = new WithdrawalNFTMock();
        WithdrawalNFTMock withdrawalNFTMock = new WithdrawalNFTMock();

        // Create roles struct inline to reduce local variables
        dreUSDManager manager = _deployDreUSDManager(
            address(dreUSDToken),
            address(dreUSDsVault),
            address(usdcToken),
            address(oracleMock),
            address(expressNFT),
            address(withdrawalNFTMock),
            makeAddr("expressPaybackAddress"),
            makeAddr("expressFeeRecipient"),
            dreUSDManager.RoleAddresses({
                defaultAdmin: makeAddr("defaultAdmin"),
                upgrader: makeAddr("upgrader"),
                moderator: makeAddr("moderator"),
                withdrawalConfig: makeAddr("withdrawalConfig"),
                pauser: makeAddr("pauser"),
                keeper: makeAddr("keeper"),
                expressOperator: makeAddr("expressOperator"),
                treasury: makeAddr("treasury")
            })
        );

        address proxyAddr = address(manager);
        assertGt(proxyAddr.code.length, 0, "proxy should have code");

        // Immutables
        assertEq(manager.dreUSD(), address(dreUSDToken), "dreUSD immutable");
        assertEq(manager.dreUSDs(), address(dreUSDsVault), "dreUSDs immutable");
        assertEq(manager.usdc(), address(usdcToken), "usdc immutable");
        assertEq(manager.oracle(), address(oracleMock), "oracle immutable");
        assertEq(manager.expressWithdrawalNFT(), address(expressNFT), "expressWithdrawalNFT immutable");
        assertEq(manager.withdrawalNFT(), address(withdrawalNFTMock), "withdrawalNFT immutable");
        assertEq(manager.dreRewardsDistributor(), makeAddr("rewardsDistributor"), "dreRewardsDistributor");

        // Roles granted to correct addresses
        assertTrue(manager.hasRole(manager.DEFAULT_ADMIN_ROLE(), makeAddr("defaultAdmin")), "defaultAdmin should have DEFAULT_ADMIN_ROLE");
        assertTrue(manager.hasRole(manager.UPGRADER_ROLE(), makeAddr("upgrader")), "upgrader should have UPGRADER_ROLE");
        assertTrue(manager.hasRole(manager.MODERATOR_ROLE(), makeAddr("moderator")), "moderator should have MODERATOR_ROLE");
        assertTrue(manager.hasRole(manager.WITHDRAWAL_CONFIG_ROLE(), makeAddr("withdrawalConfig")), "withdrawalConfig should have WITHDRAWAL_CONFIG_ROLE");
        assertTrue(manager.hasRole(manager.PAUSER_ROLE(), makeAddr("pauser")), "pauser should have PAUSER_ROLE");
        assertTrue(manager.hasRole(manager.KEEPER_ROLE(), makeAddr("keeper")), "keeper should have KEEPER_ROLE");
        assertTrue(manager.hasRole(manager.EXPRESS_OPERATOR_ROLE(), makeAddr("expressOperator")), "expressOperator should have EXPRESS_OPERATOR_ROLE");
        assertTrue(manager.hasRole(manager.TREASURY_ROLE(), makeAddr("treasury")), "treasury should have TREASURY_ROLE");

        // Initial state from initialize()
        assertEq(manager.expressWithdrawalMaxLimit(), 10_000_000e6, "expressWithdrawalMaxLimit");
        assertEq(manager.expressWithdrawalAvailable(), 10_000_000e6, "expressWithdrawalAvailable");
        assertEq(manager.expressWithdrawalFeeBps(), 50, "expressWithdrawalFeeBps");
        assertEq(manager.withdrawalWaitingTime(), 7 days, "withdrawalWaitingTime");
        assertEq(manager.expressPaybackAddress(), makeAddr("expressPaybackAddress"), "expressPaybackAddress");
        assertEq(manager.expressFeeRecipient(), makeAddr("expressFeeRecipient"), "expressFeeRecipient");
    }
}
