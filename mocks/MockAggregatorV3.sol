// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @dev Minimal local copy of Chainlink's AggregatorV3Interface to avoid external import
 *      issues in the linter. Function signatures are identical to the original interface.
 */
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);

    function getRoundData(
        uint80 _roundId
    )
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/**
 * @title MockAggregatorV3
 * @dev Simple configurable mock for Chainlink AggregatorV3Interface used in tests.
 */
contract MockAggregatorV3 is AggregatorV3Interface {
    uint256 private constant STALENESS_OFFSET = 10 minutes;

    uint8 public override decimals;
    string public override description;
    uint256 public override version;

    int256 private _answer;

    constructor(
        uint8 _decimals,
        string memory _description,
        uint256 _version
    ) {
        decimals = _decimals;
        description = _description;
        version = _version;
        _answer = 1e8;
    }

    /**
     * @dev Allows tests to configure the latest price. Second parameter is ignored; round data always reports block.timestamp - 10 minutes.
     * @param answer New price answer.
     */
    function setLatestAnswer(int256 answer, uint256 /* updatedAt */) external {
        _answer = answer;
    }

    function _timestampForRound() internal view returns (uint256) {
        return block.timestamp - STALENESS_OFFSET;
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
        uint256 t = _timestampForRound();
        roundId = 1;
        answer = _answer;
        startedAt = t;
        updatedAt = t;
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
        uint256 t = _timestampForRound();
        roundId = 1;
        answer = _answer;
        startedAt = t;
        updatedAt = t;
        answeredInRound = 1;
    }
}

