// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IWithdrawalKeeperManager} from "../interfaces/IWithdrawalKeeperManager.sol";

/**
 * @title WithdrawalKeeperManagerMock
 * @dev Minimal manager mock for dreWithdrawalKeeperBot tests
 */
contract WithdrawalKeeperManagerMock is IWithdrawalKeeperManager {
    address public override withdrawalNFT;
    uint256 public override withdrawalWaitingTime;
    address public override dreUSD;
    address public override usdc;
    address public override withdrawalVaultAdapter;
    bool public override paused;

    uint256 public lastFilledCount;
    uint256 public lastTotalFilled;
    uint256[] public lastTokenIds;
    bool public lastUseVault;

    constructor(
        address _withdrawalNFT,
        address _dreUSD,
        address _usdc,
        uint256 _waitingTime
    ) {
        withdrawalNFT = _withdrawalNFT;
        dreUSD = _dreUSD;
        usdc = _usdc;
        withdrawalWaitingTime = _waitingTime;
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function setVaultAdapter(address adapter) external {
        withdrawalVaultAdapter = adapter;
    }

    function fillWithdrawal(uint256[] calldata tokenIds, bool useVault)
        external
        returns (uint256 filledCount, uint256 totalFilled)
    {
        lastTokenIds = tokenIds;
        lastUseVault = useVault;
        filledCount = tokenIds.length;
        totalFilled = tokenIds.length * 1e6;
        lastFilledCount = filledCount;
        lastTotalFilled = totalFilled;
    }
}
