//SPDx-License-Identifier: MIT

pragma solidity ^0.8.18;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 * @author Codex-BugMeNot
 * @notice This library is to Check the ChainLink Oracle for the stale data.
 * If a price is stale, the function will revert and render the DSCEngine unusable - this is by design
 * We watn DSCEngine to freeze if prices becoem stale.
 *
 * So,if the chainlink network Explodes and you have a lot of money Locked in the protocol ... too Bad.
 */
library OracleLib {
    error Oracle__StalePrice();

    uint256 private constant TIMEOUT = 3 hours;

    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        uint256 secondsSince = block.timestamp - updatedAt;
        if (secondsSince > TIMEOUT) {
            revert Oracle__StalePrice();
        }
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
