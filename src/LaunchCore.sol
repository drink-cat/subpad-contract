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

/// 发币和模拟成交。
/// 通过 UUPS 代理使用：实现合约构造时关掉初始化，真正的 owner 在代理的 initialize 里设置。
/// 代币总量铸在本合约里。用户买入时合约付出代币、收进扣费后的报价币；卖出时方向相反。
/// 手续费始终从交易者的报价币余额转给分成地址，不从池子库存里扣。
contract LaunchCore is Initializable, OwnableUpgradeable, UUPSUpgradeable, ILaunchCore {
    using PoolInfoLib for PoolInfo;
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;

    /// poolId => 池子。poolId = keccak256(abi.encode(创建者, 代币地址, 报价币地址))。
    mapping(bytes32 poolId => PoolInfo) public pools;

    /// 实现合约不能直接初始化，避免有人绕过代理把 owner 设走。
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// 代理部署时调用一次，把 initialOwner 设为管理员。发币和升级都只允许这个地址。
    function initialize(address initialOwner) public initializer {
        __Ownable_init(initialOwner);
    }

    /// UUPS 升级入口的权限检查。新实现地址由 owner 通过 upgradeToAndCall 传入。
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// 发行一种代币并建池。
    /// 新代币的 owner 是本合约（代理地址），总量铸给本合约。
    /// subpadId == 0：费率 0.1%，平台和发币人各 50%。
    /// subpadId != 0：费率 0.15%，平台 40%、发币人 40%、子 pad 20%。
    /// 发币人分成记在 msg.sender 上。本函数只能由 owner 调用，所以这两笔目前都进 owner。
    function createToken(CreateTokenParams calldata params) public onlyOwner {
        Token token = new Token(params.tokenName, params.tokenSymbol);
        token.mint(address(this), params.totalSupply);

        // 创建者、代币、报价币三者确定唯一池子。同一 owner 用同一报价币重复发币会得到不同代币地址，因此 poolId 不同。
        bytes32 poolId = keccak256(abi.encode(msg.sender, address(token), params.quoteToken));

        uint256 feeRate;
        FeeRule[] memory feeRules;
        if (params.subpadId == 0) {
            // 费率 10 = 0.1%。分成 5000 = 50%。
            feeRate = 10;
            feeRules = new FeeRule[](2);
            feeRules[0] = FeeRule({feeType: FeeType.PLATFORM, percent: 5000, feeTo: address(this)});
            feeRules[1] = FeeRule({feeType: FeeType.TOKEN_CREATOR, percent: 5000, feeTo: msg.sender});
        } else {
            // 费率 15 = 0.15%。分成 4000 / 4000 / 2000 = 40% / 40% / 20%。
            feeRate = 15;
            feeRules = new FeeRule[](3);
            feeRules[0] = FeeRule({feeType: FeeType.PLATFORM, percent: 4000, feeTo: address(this)});
            feeRules[1] = FeeRule({feeType: FeeType.TOKEN_CREATOR, percent: 4000, feeTo: msg.sender});
            feeRules[2] = FeeRule({feeType: FeeType.SUBPAD, percent: 2000, feeTo: params.subpadFeeTo});
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

    /// 按当前曲线价格模拟一笔成交。谁都可以调用，调用前须把相关代币 approve 给本合约。
    ///
    /// 输入二选一：
    /// - tokenAmount 非 0：按代币数量成交。先用现价换成报价币总额，再从这笔总额扣费。
    ///   买入时用户实际换到的代币就是指定数量；扣费后的报价币进入池子。
    /// - 否则 quoteTokenAmount 非 0：按报价币总额成交。先从这笔总额扣费，再用剩下的报价币换代币。
    ///   买入时用户付出的报价币是指定总额，换到的代币按扣费后的金额计算。
    ///
    /// 买入：交易者支付 quoteNet 给池子，池子支付 tokenAmount 给交易者，sellSum 增加，之后价格变高。
    /// 卖出：交易者支付 tokenAmount 给池子，池子支付 quoteNet 给交易者，sellSum 减少。
    /// 卖出不能超过 sellSum，也就是不能卖出比当前净买入更多的代币。
    ///
    /// 手续费在上面两种情况里都是另外从交易者的报价币余额转走。
    /// 因此卖出时交易者要自备手续费，报价币净入账 = quoteNet - fee，不是 quoteNet。
    function mockSwap(SwapParams calldata swapParams) public {
        PoolInfo storage pool = pools[swapParams.poolId];
        require(pool.token != address(0), "Pool not found");

        // 价格在改 sellSum 之前取，本笔成交整笔都用这一个价格。
        uint256 currentPrice = pool.getCurrentPrice();
        require(currentPrice > 0, "price");

        bool isBuy;
        uint256 tokenAmount;
        uint256 quoteAmount;
        uint256 quoteNet;
        if (swapParams.tokenAmount != 0) {
            isBuy = swapParams.tokenAmount > 0;
            tokenAmount = _abs(swapParams.tokenAmount);
            quoteAmount = tokenAmount.mulDivDown(currentPrice, PRICE_POINT);
            quoteNet = _takeQuoteFee(pool, quoteAmount);
        } else if (swapParams.quoteTokenAmount != 0) {
            isBuy = swapParams.quoteTokenAmount > 0;
            quoteAmount = _abs(swapParams.quoteTokenAmount);
            quoteNet = _takeQuoteFee(pool, quoteAmount);
            tokenAmount = quoteNet.mulDivDown(PRICE_POINT, currentPrice);
        } else {
            revert("empty swap");
        }

        IERC20 quoteToken = IERC20(pool.quoteToken);
        IERC20 launchToken = IERC20(pool.token);
        if (isBuy) {
            // 手续费已经在 _takeQuoteFee 里转走，这里只把扣费后的报价币收进池子。
            if (quoteNet > 0) quoteToken.safeTransferFrom(msg.sender, address(this), quoteNet);
            if (tokenAmount > 0) launchToken.safeTransfer(msg.sender, tokenAmount);
            pool.sellSum += tokenAmount;
        } else {
            require(pool.sellSum >= tokenAmount, "sellSum");
            if (tokenAmount > 0) launchToken.safeTransferFrom(msg.sender, address(this), tokenAmount);
            if (quoteNet > 0) quoteToken.safeTransfer(msg.sender, quoteNet);
            pool.sellSum -= tokenAmount;
        }

        _emitSwapOnce(pool, isBuy, tokenAmount, quoteAmount, quoteNet, currentPrice);
    }

    /// 发出 SwapOnce。单独成函数，避免 mockSwap 里局部变量过多导致栈太深。
    /// 事件里的小数位取自代币合约，方便链下直接换算，不参与计价。
    function _emitSwapOnce(
        PoolInfo storage pool,
        bool isBuy,
        uint256 tokenAmount,
        uint256 quoteAmount,
        uint256 quoteNet,
        uint256 price
    ) private {
        emit SwapOnce(
            pool.poolId,
            msg.sender,
            pool.token,
            isBuy,
            tokenAmount,
            IERC20Metadata(pool.token).decimals(),
            pool.quoteToken,
            quoteAmount,
            quoteNet,
            IERC20Metadata(pool.quoteToken).decimals(),
            price
        );
    }

    /// 从交易者的报价币里扣手续费，并按 feeRules 分给各收款地址。
    /// 返回扣费后剩余的报价币 quoteNet，由 mockSwap 决定这笔钱进池子还是打给交易者。
    ///
    /// 除最后一条规则外都向下取整。最后一条拿走 fee - 已分配，保证分成之和等于手续费，尘埃不会留在交易者或合约里。
    /// 某一条分成为 0 时跳过转账，也不发 FeeCharged。
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

    /// 有符号成交数量转成正数。int256 最小值取负会溢出，直接拒绝。
    function _abs(int256 value) private pure returns (uint256) {
        require(value != type(int256).min, "amount");
        // casting to 'uint256' is safe because value is not int256.min, and a negative value is negated first
        // forge-lint: disable-next-line(unsafe-typecast)
        return value < 0 ? uint256(-value) : uint256(value);
    }
}
