// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MetaNodeToken is ERC20 {
    constructor(address initialRecipient) ERC20("MetaNodeToken", "MetaNode") {
        // 初始供应量
        _mint(initialRecipient, 10000 * 1_000_000_000_000_000_000);
    }
}
