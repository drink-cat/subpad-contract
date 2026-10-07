// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";

uint256 constant PERCENT_POINT = 1e4;
uint256 constant PRICE_POINT = 1e18;
uint256 constant FEE_POINT = PERCENT_POINT;

interface ILaunchCore {
    struct CreateTokenParams {
        bool useMockSwap; // 是否使用mock swap。
        string tokenName;
        string tokenSymbol;
        uint256 tokenDecimals;
        uint256 totalSupply;
        address quoteToken;
        uint256 initPrice;
        uint256 subpadId; // 子pad id。 0 表示没有子pad。
        address subpadFeeTo; // 子pad 费用接收地址。
    }

    struct SwapParams {
        bytes32 poolId;
        int256 tokenAmount; // 正数=买。负数=卖。0=无。
        int256 quoteTokenAmount; // 正数=买。负数=卖。0=无。
    }

    struct PoolInfo {
        bool useMockSwap; // 是否使用mock swap。
        bytes32 poolId;
        address creator;
        address token;
        address quoteToken;
        uint256 initPrice; // PRICE_POINT
        uint256 sellSum; // 卖出的数量。 价格与数量有关。
        uint256 subpadId; // 子pad id。 0 表示没有子pad。
        address subpadFeeTo; // 子pad 费用接收地址。
        uint256 feeRate; // 费用比例。4位小数。  5%=500
        FeeRule[] feeRules; // 多个规则的比例，加起来等于 100%
    }

    // | fee_type | varchar | 费用类型。 platform=平台费 tokencreator=创建者费 subpad=子pad费 |
    enum FeeType {
        PLATFORM,
        TOKEN_CREATOR,
        SUBPAD
    }

    struct FeeRule {
        FeeType feeType; // 费用类型
        uint256 percent; // 占比。4位小数。  5%=500
        address feeTo; // 费用接收地址
    }

    event TokenCreated(
        bytes32 indexed poolId,
        address indexed creator,
        address indexed token,
        string tokenName,
        string tokenSymbol,
        address quoteToken,
        string quoteTokenSymbol,
        uint256 launchSupply,
        int24 tickSpacing
    );
    event FeeCharged(
        bytes32 indexed poolId,
        FeeType feeType,
        address indexed feeToken,
        uint8 feeDecimal,
        uint256 feeAmount,
        address indexed feeTo
    );
}

