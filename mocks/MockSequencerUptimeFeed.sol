// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AggregatorV3Interface} from "@chainlink/contracts/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title MockSequencerUptimeFeed
 * @dev Mock for Chainlink L2 sequencer uptime feed. setLatestAnswer(answer, startedAt) stores both;
 *      latestRoundData() returns them so grace-period and sequencer-up/down tests pass.
 *      Answer 0 = sequencer up, 1 = sequencer down.
 */
contract MockSequencerUptimeFeed is AggregatorV3Interface {
    uint8 public override decimals = 8;
    string public override description = "Sequencer Uptime Feed";
    uint256 public override version = 1;

    int256 private _answer;
    uint256 private _startedAt;

    /**
     * @param answer 0 = sequencer up, 1 = sequencer down
     * @param startedAt Timestamp when sequencer came back up (returned as startedAt/updatedAt)
     */
    function setLatestAnswer(int256 answer, uint256 startedAt) external {
        _answer = answer;
        _startedAt = startedAt;
    }

    function getRoundData(
        uint80 /* _roundId */
    )
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        roundId = 1;
        answer = _answer;
        startedAt = _startedAt;
        updatedAt = _startedAt;
        answeredInRound = 1;
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        roundId = 1;
        answer = _answer;
        startedAt = _startedAt;
        updatedAt = _startedAt;
        answeredInRound = 1;
    }
}
