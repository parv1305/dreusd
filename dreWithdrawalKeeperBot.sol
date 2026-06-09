// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IdreWithdrawalKeeperBot} from "./interfaces/IdreWithdrawalKeeperBot.sol";
import {IWithdrawalKeeperManager} from "./interfaces/IWithdrawalKeeperManager.sol";
import {IWithdrawalNFT} from "./interfaces/IWithdrawalNFT.sol";
import {IWithdrawalNFTQueue} from "./interfaces/IWithdrawalNFTQueue.sol";
import {IdreUSD} from "./interfaces/IdreUSD.sol";
import {IAaveV3Adapter} from "./interfaces/IAaveV3Adapter.sol";

/**
 * @title dreWithdrawalKeeperBot
 * @notice Fills ready `dreWithdrawalNFT` positions via `dreUSDManager.fillWithdrawal` using the vault adapter.
 * @dev Scans token IDs from `lastBurnedTokenId + 1` in queue order (up to `nextTokenId - 1`).
 *      Stops at the first existing position younger than `withdrawalWaitingTime` (queue head not ready).
 *      Skips blocked holders; cumulative `usdcAmount` must fit vault liquidity.
 */
contract dreWithdrawalKeeperBot is IdreWithdrawalKeeperBot {
    uint256 public constant MAX_BATCH_SIZE = 10;

    /// @inheritdoc IdreWithdrawalKeeperBot
    address public immutable manager;

    constructor(address _manager) {
        if (_manager == address(0)) revert ZeroAddress();
        manager = _manager;
    }

    function checkUpkeep(bytes calldata /* checkData */) external view returns (bool upkeepNeeded, bytes memory performData) {
        uint256[] memory tokenIds = _collectFillableTokenIds(MAX_BATCH_SIZE);
        if (tokenIds.length == 0) {
            return (false, "");
        }
        performData = abi.encode(tokenIds);
        upkeepNeeded = true;
    }

    function performUpkeep(bytes calldata performData) external {
        uint256[] memory tokenIds = abi.decode(performData, (uint256[]));
        (uint256 filledCount, uint256 totalFilled) = IWithdrawalKeeperManager(manager).fillWithdrawal(tokenIds, true);
        emit WithdrawalsFilled(filledCount, totalFilled);
    }

    function _collectFillableTokenIds(uint256 batchSize) internal view returns (uint256[] memory tokenIds) {
        uint256 vaultLiquidity = _availableLiquidity();
        if (vaultLiquidity == 0) {
            return tokenIds;
        }

        IWithdrawalKeeperManager mgr = IWithdrawalKeeperManager(manager);
        if (mgr.paused()) {
            return tokenIds;
        }

        address nftAddr = mgr.withdrawalNFT();
        IWithdrawalNFT nft = IWithdrawalNFT(nftAddr);
        IWithdrawalNFTQueue queue = IWithdrawalNFTQueue(nftAddr);
        uint256 waitingTime = mgr.withdrawalWaitingTime();
        address dreUSDToken = mgr.dreUSD();

        uint256 tokenId = queue.lastBurnedTokenId() + 1;
        uint256 next = queue.nextTokenId();

        uint256[] memory scratch = new uint256[](batchSize);
        uint256 count;
        uint256 selectedUsdc;

        while (tokenId < next && count < batchSize) {
            if (!nft.positionExists(tokenId)) {
                tokenId++;
                continue;
            }

            IWithdrawalNFT.Position memory position = nft.getPosition(tokenId);
            if (block.timestamp < position.createdAt + waitingTime) {
                break;
            }

            address holder = IERC721(nftAddr).ownerOf(tokenId);
            if (IdreUSD(dreUSDToken).isBlockedAddress(holder)) {
                tokenId++;
                continue;
            }

            uint256 usdcAmount = position.usdcAmount;
            if (usdcAmount == 0) {
                tokenId++;
                continue;
            }
            if (selectedUsdc + usdcAmount > vaultLiquidity) {
                break;
            }

            scratch[count] = tokenId;
            count++;
            selectedUsdc += usdcAmount;
            tokenId++;
        }

        tokenIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            tokenIds[i] = scratch[i];
        }
    }

    function _availableLiquidity() internal view returns (uint256) {
        address adapter = IWithdrawalKeeperManager(manager).withdrawalVaultAdapter();
        if (adapter == address(0)) {
            return 0;
        }
        return IAaveV3Adapter(adapter).getAvailableBalance();
    }
}
