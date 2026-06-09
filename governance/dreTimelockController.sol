// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TimelockController as TimelockBase} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract dreTimelockController is TimelockBase {
    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors
    ) TimelockBase(minDelay, proposers, executors, address(0)) {}
}
