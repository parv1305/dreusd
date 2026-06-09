// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title ISanctionsList
 * @dev Interface for sanctions list oracle
 */
interface ISanctionsList {
    function isSanctioned(address addr) external view returns (bool);
}

