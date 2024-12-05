// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract HawalaToken is ERC20, Ownable {
    constructor(
        address initialOwner
    ) Ownable(initialOwner) ERC20("HawalaDex token", "HAWALA") {
        _mint(msg.sender, 1_000_000_000 * 10 ** decimals());
    }
}
