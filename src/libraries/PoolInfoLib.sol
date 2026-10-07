// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ILaunchCore} from "../interfaces/ILaunchCore.sol";
import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";

/// 池子定价。挂在 PoolInfo 的 storage 引用上，由 LaunchCore 在成交前调用。
library PoolInfoLib {
    using FixedPointMathLib for uint256;

    /// 当前曲线价格。
    /// price = initPrice + sellSum * 0.003
    /// 0.003 = 30 / 10000。initPrice 和 sellSum 都是 18 位精度，乘完后的价格单位仍是 PRICE_POINT。
    /// 净卖出越多价格越高；卖回代币使 sellSum 下降，价格跟着下降。
    /// 斜率 0.003 是临时值，后续要改。
    function getCurrentPrice(ILaunchCore.PoolInfo storage pool) public view returns (uint256) {
        return pool.initPrice + pool.sellSum.mulDivDown(30, 10000);
    }
}
