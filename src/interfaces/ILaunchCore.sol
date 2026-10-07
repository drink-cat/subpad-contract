// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";

uint256 constant FEE_POINT = 1e4;
uint256 constant PRICE_POINT = 1e18;

interface ILaunchCore {
    struct CreateTokenParams {
        string tokenName;
        string tokenSymbol;
        uint256 tokenDecimals;
        uint256 totalSupply;
        address quoteToken;
        uint256 initPrice;
    }

    struct PoolInfo {
        bytes32 poolId;
        address creator;
        address token;
        address quoteToken;
    }

    // | fee_type | varchar | 费用类型。 platform=平台费 tokencreator=创建者费 subpad=子pad费 |
    enum FeeType {
        PLATFORM,
        TOKEN_CREATOR,
        SUBPAD
    }

    event TokenCreated(bytes32 indexed poolId, address indexed token, string tokenName, string tokenSymbol);
    event FeeInfo(bytes32 indexed poolId, FeeType feeType, address indexed feeTo, uint256 feeAmount);
}
