// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAutomationCompatible} from "./IAutomationCompatible.sol";

/**
 * @title IdreWithdrawalKeeperBot
 * @notice Chainlink Automation bot that fills ready `dreWithdrawalNFT` positions via `dreUSDManager.fillWithdrawal` (vault only)
 */
interface IdreWithdrawalKeeperBot is IAutomationCompatible {
    error ZeroAddress();

    event WithdrawalsFilled(uint256 filledCount, uint256 totalFilled);

    function manager() external view returns (address);
}
