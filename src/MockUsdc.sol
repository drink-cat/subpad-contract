// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// 测试用。便于领取币。
contract MockUsdc is ERC20, Ownable {
    constructor() ERC20("Mock USDC", "MockUSDC") Ownable(msg.sender) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    /// 自己领取币。测试用。
    function mintSelfFree(uint256 amount) public {
        _mint(msg.sender, amount);
    }

    function burn(address from, uint256 amount) public onlyOwner {
        _burn(from, amount);
    }

    function burn(uint256 amount) public {
        _burn(msg.sender, amount);
    }
}
