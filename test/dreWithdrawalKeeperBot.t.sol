// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";
import {WithdrawalEnumerableNFTMock} from "../contracts/mocks/WithdrawalEnumerableNFTMock.sol";
import {WithdrawalKeeperManagerMock} from "../contracts/mocks/WithdrawalKeeperManagerMock.sol";
import {DreUSDBlockedMock} from "../contracts/mocks/DreUSDBlockedMock.sol";
import {AaveV3AdapterMock} from "../contracts/mocks/AaveV3AdapterMock.sol";
import {dreWithdrawalKeeperBot} from "../contracts/dreWithdrawalKeeperBot.sol";

contract DreWithdrawalKeeperBotTest is Test {
    MockERC20 public usdc;
    WithdrawalEnumerableNFTMock public nft;
    DreUSDBlockedMock public dreUSD;
    WithdrawalKeeperManagerMock public manager;
    AaveV3AdapterMock public vaultAdapter;
    dreWithdrawalKeeperBot public bot;

    address public user = makeAddr("user");
    uint256 public constant WAITING_TIME = 7 days;
    uint256 public constant USDC_AMOUNT = 500e6;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        nft = new WithdrawalEnumerableNFTMock();
        dreUSD = new DreUSDBlockedMock();
        manager = new WithdrawalKeeperManagerMock(address(nft), address(dreUSD), address(usdc), WAITING_TIME);
        vaultAdapter = new AaveV3AdapterMock(address(usdc), address(this));
        manager.setVaultAdapter(address(vaultAdapter));
        bot = new dreWithdrawalKeeperBot(address(manager));
    }

    function _fundVault(uint256 amount) internal {
        vaultAdapter.setAvailableBalance(amount);
        usdc.mint(address(vaultAdapter), amount);
    }

    function test_checkUpkeep_ReturnsFalseWhenNothingReady() public {
        vm.prank(address(manager));
        nft.mint(user, USDC_AMOUNT);

        (bool needed, bytes memory performData) = bot.checkUpkeep("");
        assertFalse(needed);
        assertEq(performData.length, 0);
    }

    function test_checkUpkeep_ReturnsFalseWhenNoVaultLiquidity() public {
        vm.prank(address(manager));
        nft.mint(user, USDC_AMOUNT);

        vm.warp(block.timestamp + WAITING_TIME + 1);

        (bool needed,) = bot.checkUpkeep("");
        assertFalse(needed);
    }

    function test_checkUpkeep_ReturnsTokenIdsWhenReady() public {
        vm.prank(address(manager));
        uint256 tokenId = nft.mint(user, USDC_AMOUNT);

        vm.warp(block.timestamp + WAITING_TIME + 1);
        _fundVault(USDC_AMOUNT);

        (bool needed, bytes memory performData) = bot.checkUpkeep("");
        assertTrue(needed);

        uint256[] memory tokenIds = abi.decode(performData, (uint256[]));
        assertEq(tokenIds.length, 1);
        assertEq(tokenIds[0], tokenId);
    }

    function test_performUpkeep_CallsFillWithdrawalWithVault() public {
        vm.prank(address(manager));
        uint256 tokenId = nft.mint(user, USDC_AMOUNT);

        vm.warp(block.timestamp + WAITING_TIME + 1);
        _fundVault(USDC_AMOUNT);

        (bool needed, bytes memory performData) = bot.checkUpkeep("");
        assertTrue(needed);

        bot.performUpkeep(performData);

        assertEq(manager.lastFilledCount(), 1);
        assertEq(manager.lastTokenIds(0), tokenId);
        assertTrue(manager.lastUseVault());
    }

    function test_checkUpkeep_SkipsBlockedOwner() public {
        dreUSD.setBlocked(user, true);

        vm.prank(address(manager));
        nft.mint(user, USDC_AMOUNT);

        vm.warp(block.timestamp + WAITING_TIME + 1);
        _fundVault(USDC_AMOUNT * 2);

        (bool needed,) = bot.checkUpkeep("");
        assertFalse(needed);
    }

    function test_checkUpkeep_StopsAtFirstNotReady() public {
        vm.prank(address(manager));
        uint256 id1 = nft.mint(user, USDC_AMOUNT);

        vm.warp(block.timestamp + WAITING_TIME + 1);

        vm.prank(address(manager));
        nft.mint(user, USDC_AMOUNT);

        _fundVault(USDC_AMOUNT * 2);

        (bool needed, bytes memory performData) = bot.checkUpkeep("");
        assertTrue(needed);

        uint256[] memory tokenIds = abi.decode(performData, (uint256[]));
        assertEq(tokenIds.length, 1);
        assertEq(tokenIds[0], id1);
    }

    function test_checkUpkeep_SkipsGapsBelowFrontier() public {
        vm.startPrank(address(manager));
        nft.mint(user, USDC_AMOUNT);
        nft.mint(user, USDC_AMOUNT);
        nft.mint(user, USDC_AMOUNT);
        vm.stopPrank();

        vm.prank(address(manager));
        nft.burn(3);

        vm.warp(block.timestamp + WAITING_TIME + 1);
        _fundVault(USDC_AMOUNT * 3);

        (bool needed,) = bot.checkUpkeep("");
        assertFalse(needed);
    }

    function test_checkUpkeep_RespectsMaxBatchSize() public {
        vm.startPrank(address(manager));
        for (uint256 i = 0; i < 12; i++) {
            nft.mint(user, USDC_AMOUNT);
        }
        vm.stopPrank();

        vm.warp(block.timestamp + WAITING_TIME + 1);
        _fundVault(USDC_AMOUNT * 12);

        (bool needed, bytes memory performData) = bot.checkUpkeep("");
        assertTrue(needed);

        uint256[] memory tokenIds = abi.decode(performData, (uint256[]));
        assertEq(tokenIds.length, bot.MAX_BATCH_SIZE());
    }

    function _toArray(uint256 value) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = value;
    }
}
