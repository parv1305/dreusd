// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { DeployWithdrawalNFT } from "../script/nft/DeployWithdrawalNFT.s.sol";
import { dreWithdrawalNFT } from "../contracts/dreWithdrawalNFT.sol";
import { DreUSDMock } from "../contracts/mocks/DreUSDMock.sol";

/**
 * @title DeployWithdrawalNFTTest
 * @notice Tests the dreWithdrawalNFT deploy script logic.
 */
contract DeployWithdrawalNFTTest is Test, DeployWithdrawalNFT {
    function test_DeployWithdrawalNFT() public {
        vm.chainId(84532);
        address defaultAdmin = makeAddr("defaultAdmin");
        address upgrader = makeAddr("upgrader");
        DreUSDMock dreUSD = new DreUSDMock();

        dreWithdrawalNFT nft = _deployWithdrawalNFT("DRE Withdrawal", "dreWD", defaultAdmin, upgrader, address(dreUSD));
        address proxyAddr = address(nft);

        assertGt(proxyAddr.code.length, 0, "proxy should have code");
        assertEq(nft.name(), "DRE Withdrawal");
        assertEq(nft.symbol(), "dreWD");
        assertEq(nft.nextTokenId(), 1);
        assertEq(nft.dreUSD(), address(dreUSD), "dreUSD should be set");
        assertTrue(nft.hasRole(nft.DEFAULT_ADMIN_ROLE(), defaultAdmin), "defaultAdmin should have DEFAULT_ADMIN_ROLE");
        assertTrue(nft.hasRole(nft.UPGRADER_ROLE(), upgrader), "upgrader should have UPGRADER_ROLE");
    }
}
