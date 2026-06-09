// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { Config } from "../script/Config.sol";
import { DeployDreSystem } from "../script/DeployDreSystem.s.sol";
import { dreUSD } from "../contracts/dreUSD.sol";

/**
 * @title DeployDreSystemTest
 * @notice Test points:
 *   1. run() reverts with a clear error when the chain has no LZ endpoint (prevents deploying on wrong chain).
 *   2. _deployBaseComponents deploys and wires all Base components correctly: vault uses token as asset,
 *      rewards distributor uses token + vault, manager has correct immutables and admin roles, NFTs have
 *      correct names/symbols, ShareOFT adapter and composer reference vault/token/adapter.
 *   Run fork test: forge test --match-path test/DeployDreSystem.t.sol --fork-url https://sepolia.base.org
 */
contract DeployDreSystemTest is Test, DeployDreSystem {
    uint256 constant BASE_SEPOLIA_CHAIN_ID = 84532;
    string constant BASE_SEPOLIA_RPC = "https://sepolia.base.org";
    uint256 constant ANVIL_DEFAULT_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    /// Point 1: run() must revert when LZ endpoint is not configured (unsupported chain), so we don't deploy on wrong chain.
    function test_run_RevertsWhenLzEndpointNotFound() public {
        vm.chainId(31337);
        // // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("PRIVATE_KEY", vm.toString(ANVIL_DEFAULT_PK));
        vm.deal(vm.addr(ANVIL_DEFAULT_PK), 100 ether);
        vm.expectRevert("LZ_ENDPOINT_V2 not found in config");
        this.run();
    }

    /// Point 2: _deployBaseComponents deploys all contracts and wires them correctly (vault→token, manager→vault/oracle/NFTs, etc.).
    function test_deployBaseComponents_DeploysAndWiresAllContracts_OnBaseSepoliaFork() public {
        vm.createSelectFork(BASE_SEPOLIA_RPC);
        assertEq(block.chainid, BASE_SEPOLIA_CHAIN_ID);

        Config.ChainConfig memory cfg = Config.getChainConfig(block.chainid);
        address defaultAdmin = cfg.defaultAdmin;
        address upgrader = cfg.upgrader;
        address guardian = cfg.guardian;
        address endpoint = Config.getLzEndpoint(block.chainid);
        address factory = Config.DEFAULT_CREATE2_FACTORY;
        vm.deal(defaultAdmin, 200 ether);

        dreUSD token = _deployDreUSD(endpoint, defaultAdmin, upgrader, guardian, factory);
        assertGt(address(token).code.length, 0, "dreUSD deployed");
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), defaultAdmin), "dreUSD admin");

        // SetupHelper inside _deployBaseComponents calls manager/oracle with admin-only functions; prank so msg.sender is defaultAdmin.
        vm.startPrank(defaultAdmin);
        BaseComponents memory c = _deployBaseComponents(token, cfg);
        vm.stopPrank();

        // All components deployed
        assertGt(address(c.vault).code.length, 0, "vault deployed");
        assertGt(address(c.rewardsDistributor).code.length, 0, "rewardsDistributor deployed");
        assertGt(address(c.oracle).code.length, 0, "oracle deployed");
        assertGt(address(c.manager).code.length, 0, "manager deployed");
        assertGt(address(c.shareOFTAdapter).code.length, 0, "shareOFTAdapter deployed");
        assertGt(address(c.composer).code.length, 0, "composer deployed");

        // Vault: asset is dreUSD, admin has roles
        assertEq(c.vault.asset(), address(token), "vault.asset == token");
        assertTrue(c.vault.hasRole(c.vault.DEFAULT_ADMIN_ROLE(), defaultAdmin), "vault admin");

        // Rewards distributor: dreUSD and vault set
        assertEq(c.rewardsDistributor.dreUSD(), address(token), "distributor.dreUSD == token");
        assertEq(c.rewardsDistributor.vault(), address(c.vault), "distributor.vault == vault");
        assertTrue(c.rewardsDistributor.hasRole(c.rewardsDistributor.DEFAULT_ADMIN_ROLE(), defaultAdmin), "distributor admin");

        // Manager immutables and wiring
        assertEq(c.manager.dreUSD(), address(token), "manager.dreUSD");
        assertEq(c.manager.dreUSDs(), address(c.vault), "manager.dreUSDs");
        assertEq(c.manager.oracle(), address(c.oracle), "manager.oracle");
        assertEq(c.manager.expressWithdrawalNFT(), address(c.expressNFT), "manager.expressWithdrawalNFT");
        assertEq(c.manager.withdrawalNFT(), address(c.standardNFT), "manager.withdrawalNFT");
        // manager.dreRewardsDistributor() reads from vault; vault.rewardsDistributor is set in SetupHelper.setupDreUSDs (run after deploy, not in _deployBaseComponents)
        assertEq(c.manager.dreRewardsDistributor(), address(0), "manager.dreRewardsDistributor (from vault, set in setup)");
        assertEq(c.manager.usdc(), cfg.usdc, "manager.usdc");
        assertTrue(c.manager.hasRole(c.manager.DEFAULT_ADMIN_ROLE(), defaultAdmin), "manager admin");

        // Withdrawal NFTs: names/symbols and admin
        assertEq(c.standardNFT.name(), "DRE Withdrawal", "standard NFT name");
        assertEq(c.standardNFT.symbol(), "dreWD", "standard NFT symbol");
        assertEq(c.expressNFT.name(), "DRE Express Withdrawal", "express NFT name");
        assertEq(c.expressNFT.symbol(), "dreEXP", "express NFT symbol");
        assertTrue(c.standardNFT.hasRole(c.standardNFT.DEFAULT_ADMIN_ROLE(), defaultAdmin), "standard NFT admin");
        assertTrue(c.expressNFT.hasRole(c.expressNFT.DEFAULT_ADMIN_ROLE(), defaultAdmin), "express NFT admin");

        // ShareOFT adapter: vault as inner token, delegate is owner
        assertEq(c.shareOFTAdapter.token(), address(c.vault), "shareOFTAdapter token == vault");
        assertEq(c.shareOFTAdapter.owner(), defaultAdmin, "shareOFTAdapter owner");

        // Composer: vault, asset OFT, share OFT adapter (VaultComposerSync immutables)
        assertEq(address(c.composer.VAULT()), address(c.vault), "composer.VAULT");
        assertEq(c.composer.ASSET_OFT(), address(token), "composer.ASSET_OFT");
        assertEq(c.composer.SHARE_OFT(), address(c.shareOFTAdapter), "composer.SHARE_OFT");
    }
}
