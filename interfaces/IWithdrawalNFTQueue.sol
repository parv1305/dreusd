// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IWithdrawalNFTQueue
 * @notice Queue frontier views on `dreWithdrawalNFT` (public state; not part of audited `IWithdrawalNFT`).
 */
interface IWithdrawalNFTQueue {
    function lastBurnedTokenId() external view returns (uint256);

    function nextTokenId() external view returns (uint256);
}
