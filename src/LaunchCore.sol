// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";
import {Token} from "./Token.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILaunchCore, PERCENT_POINT, PRICE_POINT} from "./interfaces/ILaunchCore.sol";
import {PoolInfoLib} from "./libraries/PoolInfoLib.sol";

contract LaunchCore is Initializable, OwnableUpgradeable, UUPSUpgradeable, ILaunchCore {
    /// 无子 pad：收费 0.1%。4 位小数，5% = 500。
    uint256 private constant FEE_RATE_NO_SUBPAD = PERCENT_POINT / 1000;
    /// 有子 pad：收费 0.15%。
    uint256 private constant FEE_RATE_WITH_SUBPAD = PERCENT_POINT * 15 / 10_000;
    uint256 private constant SHARE_HALF = PERCENT_POINT / 2;
    uint256 private constant SHARE_40 = PERCENT_POINT * 40 / 100;
    uint256 private constant SHARE_20 = PERCENT_POINT * 20 / 100;

    using PoolInfoLib for PoolInfo;
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;

    mapping(bytes32 poolId => PoolInfo) public pools;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) public initializer {
        __Ownable_init(initialOwner);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function createToken(CreateTokenParams calldata params) public onlyOwner {
        /// 创建代币
        Token token = new Token(params.tokenName, params.tokenSymbol);
        token.mint(address(this), params.totalSupply);

        /// 创建池子
        bytes32 poolId = keccak256(abi.encode(msg.sender, address(token), params.quoteToken));

        uint256 feeRate;
        FeeRule[] memory feeRules;
        if (params.subpadId == 0) {
            feeRate = FEE_RATE_NO_SUBPAD;
            feeRules = new FeeRule[](2);
            feeRules[0] = FeeRule({feeType: FeeType.PLATFORM, percent: SHARE_HALF, feeTo: owner()});
            feeRules[1] = FeeRule({feeType: FeeType.TOKEN_CREATOR, percent: SHARE_HALF, feeTo: msg.sender});
        } else {
            feeRate = FEE_RATE_WITH_SUBPAD;
            feeRules = new FeeRule[](3);
            feeRules[0] = FeeRule({feeType: FeeType.PLATFORM, percent: SHARE_40, feeTo: owner()});
            feeRules[1] = FeeRule({feeType: FeeType.TOKEN_CREATOR, percent: SHARE_40, feeTo: msg.sender});
            feeRules[2] = FeeRule({feeType: FeeType.SUBPAD, percent: SHARE_20, feeTo: params.subpadFeeTo});
        }

        PoolInfo storage pool = pools[poolId];
        pool.useMockSwap = params.useMockSwap;
        pool.poolId = poolId;
        pool.creator = msg.sender;
        pool.token = address(token);
        pool.quoteToken = params.quoteToken;
        pool.initPrice = params.initPrice;
        pool.sellSum = 0;
        pool.subpadId = params.subpadId;
        pool.subpadFeeTo = params.subpadFeeTo;
        pool.feeRate = feeRate;
        for (uint256 i = 0; i < feeRules.length; i++) {
            pool.feeRules.push(feeRules[i]);
        }
    }

    // 模拟swap交易。
    function mockSwap(SwapParams calldata swapParams) public {
        PoolInfo storage pool = pools[swapParams.poolId];
        require(pool.token != address(0), "Pool not found");

        uint256 currentPrice = pool.getCurrentPrice();
        require(currentPrice > 0, "price");

        // 手续费只从 quoteToken 扣。
        // 指定 quote：先扣费，再用剩余报价换代币。
        // 指定 token：先按现价换成 quote，再从这笔 quote 扣费。
        bool isBuy;
        uint256 tokenAmount;
        uint256 quoteNet;
        if (swapParams.tokenAmount != 0) {
            isBuy = swapParams.tokenAmount > 0;
            tokenAmount = _abs(swapParams.tokenAmount);
            uint256 quoteAmount = tokenAmount.mulDivDown(currentPrice, PRICE_POINT);
            quoteNet = _takeQuoteFee(pool, quoteAmount);
        } else if (swapParams.quoteTokenAmount != 0) {
            isBuy = swapParams.quoteTokenAmount > 0;
            quoteNet = _takeQuoteFee(pool, _abs(swapParams.quoteTokenAmount));
            tokenAmount = quoteNet.mulDivDown(PRICE_POINT, currentPrice);
        } else {
            revert("empty swap");
        }

        IERC20 quoteToken = IERC20(pool.quoteToken);
        IERC20 launchToken = IERC20(pool.token);
        if (isBuy) {
            if (quoteNet > 0) quoteToken.safeTransferFrom(msg.sender, address(this), quoteNet);
            if (tokenAmount > 0) launchToken.safeTransfer(msg.sender, tokenAmount);
            pool.sellSum += tokenAmount;
        } else {
            require(pool.sellSum >= tokenAmount, "sellSum");
            if (tokenAmount > 0) launchToken.safeTransferFrom(msg.sender, address(this), tokenAmount);
            if (quoteNet > 0) quoteToken.safeTransfer(msg.sender, quoteNet);
            pool.sellSum -= tokenAmount;
        }
    }

    /// 手续费只从用户的报价币扣除，并按 feeRules 转给接收地址。返回扣费后的报价币金额。
    function _takeQuoteFee(PoolInfo storage pool, uint256 quoteAmount) private returns (uint256 quoteNet) {
        uint256 fee = quoteAmount.mulDivDown(pool.feeRate, PERCENT_POINT);
        uint256 distributed;
        uint8 feeDecimal = IERC20Metadata(pool.quoteToken).decimals();
        IERC20 quoteToken = IERC20(pool.quoteToken);
        uint256 ruleCount = pool.feeRules.length;
        for (uint256 i = 0; i < ruleCount; i++) {
            FeeRule storage rule = pool.feeRules[i];
            uint256 part = i + 1 == ruleCount ? fee - distributed : fee.mulDivDown(rule.percent, PERCENT_POINT);
            distributed += part;
            if (part == 0) continue;
            quoteToken.safeTransferFrom(msg.sender, rule.feeTo, part);
            emit FeeCharged(pool.poolId, rule.feeType, pool.quoteToken, feeDecimal, part, rule.feeTo);
        }
        quoteNet = quoteAmount - fee;
    }

    function _abs(int256 value) private pure returns (uint256) {
        require(value != type(int256).min, "amount");
        // casting to 'uint256' is safe because value is not int256.min, and a negative value is negated first
        // forge-lint: disable-next-line(unsafe-typecast)
        return value < 0 ? uint256(-value) : uint256(value);
    }
}
