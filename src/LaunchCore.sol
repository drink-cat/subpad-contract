// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";
import {Token} from "./Token.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ILaunchCore, PERCENT_POINT} from "./interfaces/ILaunchCore.sol";
import {FeeRule} from "./interfaces/ILaunchCore.sol";

contract LaunchCore is Initializable, OwnableUpgradeable, UUPSUpgradeable, ILaunchCore {
    /// 无子 pad：收费 0.1%。4 位小数，5% = 500。
    uint256 private constant FEE_RATE_NO_SUBPAD = PERCENT_POINT / 1000;
    /// 有子 pad：收费 0.15%。
    uint256 private constant FEE_RATE_WITH_SUBPAD = PERCENT_POINT * 15 / 10_000;
    uint256 private constant SHARE_HALF = PERCENT_POINT / 2;
    uint256 private constant SHARE_40 = PERCENT_POINT * 40 / 100;
    uint256 private constant SHARE_20 = PERCENT_POINT * 20 / 100;

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
        Token token = new Token(params.tokenName, params.tokenSymbol  );
        token.mint(address(this), params.totalSupply);

        /// 创建池子
        bytes32 poolId = keccak256(abi.encode(msg.sender, params.tokenName, params.tokenSymbol, params.quoteToken));
        require(pools[poolId].token == address(0), "Pool already exists");

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
}
