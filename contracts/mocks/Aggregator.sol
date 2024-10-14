// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract Aggregator is Ownable {
    constructor() Ownable(msg.sender) {}

    uint256 public answer;

    function setAnswer(uint256 _answer) external onlyOwner() {
        answer = _answer;
    }

    function latestAnswer() external view returns (uint256) {
        return answer;
    }
}