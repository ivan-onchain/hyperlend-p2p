// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract Aggregator is Ownable {
    constructor() Ownable(msg.sender) {}

    int256 private _answer;
    bool private _revert;
    uint256 private _priceAge;

    uint8 public decimals = 8;

    function setAnswer(int256 answer) external {
        _answer = answer;
    }

    function setDecimals(uint8 newDecimals) external {
        decimals = newDecimals;
    }

    function setRevert(bool shouldRevert) external {
        _revert = shouldRevert;
    }

    function setPriceAge(uint256 priceAge) external {
        _priceAge = priceAge;
    }

    function latestAnswer() external view returns (int256) {
        require(!_revert, "Oracle: forced revert");
        return _answer;
    }

    function latestRoundData() external view returns (
        uint80 roundId, 
        int256 answer, 
        uint256 startedAt, 
        uint256 updatedAt, 
        uint80 answeredInRound
    ) {
        require(!_revert, "Oracle: forced revert");
        roundId = 0;
        answer = _answer;
        startedAt = _priceAge == 0 ? block.timestamp : block.timestamp - _priceAge;
        updatedAt = _priceAge == 0 ? block.timestamp : block.timestamp - _priceAge;
        answeredInRound = 0;
    }
}