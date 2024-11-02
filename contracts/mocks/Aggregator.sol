// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract Aggregator is Ownable {
    constructor() Ownable(msg.sender) {}

    int256 private _answer;
    bool private _revert;

    function setAnswer(int256 answer) external {
        _answer = answer;
    }

    function setRevert(bool shouldRevert) external {
        _revert = shouldRevert;
    }

    function latestAnswer() external view returns (int256) {
        require(!_revert, "Oracle: forced revert");
        return _answer;
    }
}