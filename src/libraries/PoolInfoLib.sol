// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ILaunchCore} from "../interfaces/ILaunchCore.sol";
import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";

library PoolInfoLib {
    using FixedPointMathLib for uint256;

    // 写一个简单的curve函数，计算价格。
    // price = initPrice + 0.003*sellSum
    // initPrice sellSum 单位都是 18 。
    // todo 斜率需要修改。
    function getCurrentPrice(ILaunchCore.PoolInfo storage pool) public view returns (uint256) {
        return pool.initPrice + pool.sellSum.mulDivDown(30, 10000);
    }
}
