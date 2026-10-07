// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {LaunchCore} from "../src/LaunchCore.sol";
import {MockUsdc} from "../src/MockUsdc.sol";
import {ILaunchCore, PERCENT_POINT, PRICE_POINT} from "../src/interfaces/ILaunchCore.sol";

/// 发币、mock 买卖、报价币手续费分成。
contract LaunchCoreFlowTest is Test {
    uint256 private constant FEE_RATE_NO_SUBPAD = 10;
    uint256 private constant FEE_RATE_WITH_SUBPAD = 15;
    uint256 private constant INIT_PRICE = 1 ether;
    uint256 private constant TOTAL_SUPPLY = 1_000_000 ether;

    LaunchCore internal core;
    MockUsdc internal usdc;

    address internal owner = makeAddr("owner");
    address internal trader = makeAddr("trader");
    address internal subpadFeeTo = makeAddr("subpad");

    function setUp() public {
        usdc = new MockUsdc();
        LaunchCore implementation = new LaunchCore();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(LaunchCore.initialize, (owner))
        );
        core = LaunchCore(address(proxy));
        usdc.mint(trader, 1_000_000_000 ether);
    }

    function test_createToken_withoutSubpad() public {
        (bytes32 poolId, address token) = _createToken("NoPad", "NPAD", 0, address(0));

        assertEq(IERC20Metadata(token).name(), "NoPad");
        assertEq(IERC20Metadata(token).symbol(), "NPAD");
        assertEq(IERC20Metadata(token).decimals(), 18);
        assertEq(IERC20(token).totalSupply(), TOTAL_SUPPLY);
        assertEq(IERC20(token).balanceOf(address(core)), TOTAL_SUPPLY);

        _assertPool(poolId, token, 0, address(0), FEE_RATE_NO_SUBPAD, 0);
    }

    function test_createToken_withSubpad() public {
        (bytes32 poolId, address token) = _createToken("WithPad", "WPAD", 7, subpadFeeTo);

        _assertPool(poolId, token, 7, subpadFeeTo, FEE_RATE_WITH_SUBPAD, 0);
    }

    function test_createToken_revertsIfNotOwner() public {
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, trader));
        core.createToken(_params("Nope", "NO", 0, address(0)));
    }

    /// 无子 pad：费率 0.1%，平台和创建者各 50%。先按代币数量买入，再卖出一部分。
    function test_flow_buyThenSell_feeWithoutSubpad() public {
        (bytes32 poolId, address token) = _createToken("Flow", "FLOW", 0, address(0));
        _approveTrader(token);

        uint256 buyTokens = 1_000 ether;
        uint256 buyQuote = _quoteForTokens(buyTokens, INIT_PRICE);
        uint256 buyFee = _fee(buyQuote, FEE_RATE_NO_SUBPAD);
        uint256 buyNet = buyQuote - buyFee;

        assertEq(buyQuote, 1_000 ether);
        assertEq(buyFee, 1 ether);
        assertEq(buyNet, 999 ether);

        uint256 traderQuoteBefore = usdc.balanceOf(trader);
        vm.recordLogs();
        _swap(poolId, int256(buyTokens), 0);

        assertEq(IERC20(token).balanceOf(trader), buyTokens);
        assertEq(IERC20(token).balanceOf(address(core)), TOTAL_SUPPLY - buyTokens);
        assertEq(usdc.balanceOf(trader), traderQuoteBefore - buyQuote);
        assertEq(usdc.balanceOf(address(core)), buyNet);
        assertEq(usdc.balanceOf(owner), buyFee);
        _expectCharged(poolId, buyFee / 2, buyFee / 2, 0);

        uint256 sellSumAfterBuy = buyTokens;
        uint256 priceAfterBuy = _curvePrice(INIT_PRICE, sellSumAfterBuy);
        assertEq(priceAfterBuy, 4 ether);
        _assertPool(poolId, token, 0, address(0), FEE_RATE_NO_SUBPAD, sellSumAfterBuy);

        uint256 sellTokens = 200 ether;
        uint256 sellQuote = _quoteForTokens(sellTokens, priceAfterBuy);
        uint256 sellFee = _fee(sellQuote, FEE_RATE_NO_SUBPAD);
        uint256 sellNet = sellQuote - sellFee;

        assertEq(sellQuote, 800 ether);
        assertEq(sellFee, 0.8 ether);
        assertEq(sellNet, 799.2 ether);

        // 卖出时手续费从交易者持有的报价币划走，合约再支付扣费后的报价币。
        vm.recordLogs();
        _swap(poolId, -int256(sellTokens), 0);

        assertEq(IERC20(token).balanceOf(trader), buyTokens - sellTokens);
        assertEq(usdc.balanceOf(trader), traderQuoteBefore - buyQuote - sellFee + sellNet);
        assertEq(usdc.balanceOf(address(core)), buyNet - sellNet);
        assertEq(usdc.balanceOf(owner), buyFee + sellFee);
        _expectCharged(poolId, sellFee / 2, sellFee / 2, 0);
        _assertPool(poolId, token, 0, address(0), FEE_RATE_NO_SUBPAD, sellSumAfterBuy - sellTokens);
    }

    /// 有子 pad：费率 0.15%，平台 40%、创建者 40%、子 pad 20%。按报价币数量买卖。
    function test_flow_buyThenSell_feeWithSubpad() public {
        (bytes32 poolId, address token) = _createToken("Sub", "SUB", 9, subpadFeeTo);
        _approveTrader(token);

        uint256 buyQuote = 1_000 ether;
        uint256 buyFee = _fee(buyQuote, FEE_RATE_WITH_SUBPAD);
        uint256 buyNet = buyQuote - buyFee;
        uint256 buyTokens = _tokensForQuote(buyNet, INIT_PRICE);

        assertEq(buyFee, 1.5 ether);
        assertEq(buyNet, 998.5 ether);
        assertEq(buyTokens, 998.5 ether);

        uint256 traderQuoteBefore = usdc.balanceOf(trader);
        vm.recordLogs();
        _swap(poolId, 0, int256(buyQuote));

        assertEq(IERC20(token).balanceOf(trader), buyTokens);
        assertEq(usdc.balanceOf(trader), traderQuoteBefore - buyQuote);
        assertEq(usdc.balanceOf(address(core)), buyNet);
        assertEq(usdc.balanceOf(owner), _share(buyFee, 40) + _share(buyFee, 40));
        assertEq(usdc.balanceOf(subpadFeeTo), buyFee - _share(buyFee, 40) - _share(buyFee, 40));
        _expectCharged(poolId, _share(buyFee, 40), _share(buyFee, 40), 0.3 ether);

        uint256 priceAfterBuy = _curvePrice(INIT_PRICE, buyTokens);
        uint256 sellQuote = 100 ether;
        uint256 sellFee = _fee(sellQuote, FEE_RATE_WITH_SUBPAD);
        uint256 sellNet = sellQuote - sellFee;
        uint256 sellTokens = _tokensForQuote(sellNet, priceAfterBuy);

        vm.recordLogs();
        _swap(poolId, 0, -int256(sellQuote));

        assertEq(IERC20(token).balanceOf(trader), buyTokens - sellTokens);
        assertEq(usdc.balanceOf(trader), traderQuoteBefore - buyQuote - sellFee + sellNet);
        assertEq(usdc.balanceOf(address(core)), buyNet - sellNet);
        uint256 ownerFees = _share(buyFee, 40) * 2 + _share(sellFee, 40) * 2;
        assertEq(usdc.balanceOf(owner), ownerFees);
        assertEq(usdc.balanceOf(subpadFeeTo), buyFee + sellFee - ownerFees);
        _expectCharged(poolId, _share(sellFee, 40), _share(sellFee, 40), sellFee - _share(sellFee, 40) * 2);
        _assertPool(poolId, token, 9, subpadFeeTo, FEE_RATE_WITH_SUBPAD, buyTokens - sellTokens);
    }

    /// 最后一条分成规则拿走余数，避免向下取整把尘埃留在合约里。
    function test_feeSplit_lastRuleTakesRemainder() public {
        (bytes32 poolId, address token) = _createToken("Dust", "DUST", 1, subpadFeeTo);
        _approveTrader(token);

        // 报价 2000，费率 0.15% => 手续费 3。40% 各得 1，子 pad 拿走余下的 1。
        vm.recordLogs();
        _swap(poolId, 2000, 0);

        _expectCharged(poolId, 1, 1, 1);
        assertEq(usdc.balanceOf(owner), 2);
        assertEq(usdc.balanceOf(subpadFeeTo), 1);
        assertEq(usdc.balanceOf(address(core)), 1997);
        assertEq(IERC20(token).balanceOf(trader), 2000);
    }

    function test_mockSwap_revertsWhenPoolMissing() public {
        vm.expectRevert(bytes("Pool not found"));
        core.mockSwap(ILaunchCore.SwapParams({poolId: bytes32(uint256(1)), tokenAmount: 1, quoteTokenAmount: 0}));
    }

    function test_mockSwap_revertsWhenPriceZero() public {
        (bytes32 poolId, address token) = _createTokenAtPrice("Zero", "ZERO", 0);
        _approveTrader(token);

        vm.expectRevert(bytes("price"));
        _swap(poolId, 1 ether, 0);
    }

    function test_mockSwap_revertsWhenAmountEmpty() public {
        (bytes32 poolId, address token) = _createToken("Empty", "EMP", 0, address(0));
        _approveTrader(token);

        vm.expectRevert(bytes("empty swap"));
        _swap(poolId, 0, 0);
    }

    function test_mockSwap_revertsWhenSellExceedsSold() public {
        (bytes32 poolId, address token) = _createToken("Over", "OVER", 0, address(0));
        _approveTrader(token);
        _swap(poolId, 100 ether, 0);

        vm.expectRevert(bytes("sellSum"));
        _swap(poolId, -101 ether, 0);
    }

    function _createToken(string memory name, string memory symbol, uint256 subpadId, address feeTo)
        internal
        returns (bytes32 poolId, address token)
    {
        token = vm.computeCreateAddress(address(core), vm.getNonce(address(core)));
        vm.prank(owner);
        core.createToken(_params(name, symbol, subpadId, feeTo));
        poolId = keccak256(abi.encode(owner, token, address(usdc)));
    }

    function _createTokenAtPrice(string memory name, string memory symbol, uint256 initPrice)
        internal
        returns (bytes32 poolId, address token)
    {
        ILaunchCore.CreateTokenParams memory params = _params(name, symbol, 0, address(0));
        params.initPrice = initPrice;
        token = vm.computeCreateAddress(address(core), vm.getNonce(address(core)));
        vm.prank(owner);
        core.createToken(params);
        poolId = keccak256(abi.encode(owner, token, address(usdc)));
    }

    function _params(string memory name, string memory symbol, uint256 subpadId, address feeTo)
        internal
        view
        returns (ILaunchCore.CreateTokenParams memory)
    {
        return ILaunchCore.CreateTokenParams({
            useMockSwap: true,
            tokenName: name,
            tokenSymbol: symbol,
            tokenDecimals: 18,
            totalSupply: TOTAL_SUPPLY,
            quoteToken: address(usdc),
            initPrice: INIT_PRICE,
            subpadId: subpadId,
            subpadFeeTo: feeTo
        });
    }

    function _approveTrader(address token) internal {
        vm.startPrank(trader);
        usdc.approve(address(core), type(uint256).max);
        IERC20(token).approve(address(core), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(bytes32 poolId, int256 tokenAmount, int256 quoteTokenAmount) internal {
        vm.prank(trader);
        core.mockSwap(
            ILaunchCore.SwapParams({poolId: poolId, tokenAmount: tokenAmount, quoteTokenAmount: quoteTokenAmount})
        );
    }

    struct PoolView {
        bool useMockSwap;
        bytes32 poolId;
        address creator;
        address token;
        address quoteToken;
        uint256 initPrice;
        uint256 sellSum;
        uint256 subpadId;
        address subpadFeeTo;
        uint256 feeRate;
    }

    function _assertPool(
        bytes32 poolId,
        address token,
        uint256 subpadId,
        address feeTo,
        uint256 feeRate,
        uint256 sellSum
    ) internal view {
        PoolView memory pool = _pool(poolId);
        assertTrue(pool.useMockSwap);
        assertEq(pool.poolId, poolId);
        assertEq(pool.creator, owner);
        assertEq(pool.token, token);
        assertEq(pool.quoteToken, address(usdc));
        assertEq(pool.initPrice, INIT_PRICE);
        assertEq(pool.sellSum, sellSum);
        assertEq(pool.subpadId, subpadId);
        assertEq(pool.subpadFeeTo, feeTo);
        assertEq(pool.feeRate, feeRate);
    }

    function _pool(bytes32 poolId) internal view returns (PoolView memory pool) {
        (bool ok, bytes memory data) =
            address(core).staticcall(abi.encodeWithSelector(bytes4(keccak256("pools(bytes32)")), poolId));
        require(ok, "pool");
        pool = abi.decode(data, (PoolView));
    }

    function _expectCharged(bytes32 poolId, uint256 platformFee, uint256 creatorFee, uint256 subpadFee) internal view {
        (uint256 platform, uint256 creator, uint256 subpad) = _charged(poolId);
        assertEq(platform, platformFee);
        assertEq(creator, creatorFee);
        assertEq(subpad, subpadFee);
    }

    /// 读取本次交易记录下的手续费事件。getRecordedLogs 只能取一次。
    function _charged(bytes32 poolId)
        internal
        view
        returns (uint256 platformFee, uint256 creatorFee, uint256 subpadFee)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("FeeCharged(bytes32,uint8,address,uint8,uint256,address)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length != 4 || logs[i].topics[0] != topic || logs[i].topics[1] != poolId) {
                continue;
            }
            (uint8 decodedType, uint8 feeDecimal, uint256 feeAmount) = abi.decode(logs[i].data, (uint8, uint8, uint256));
            address feeTo = address(uint160(uint256(logs[i].topics[3])));
            assertEq(feeDecimal, 6);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), address(usdc));
            if (decodedType == uint8(ILaunchCore.FeeType.PLATFORM)) {
                assertEq(feeTo, owner);
                platformFee += feeAmount;
            } else if (decodedType == uint8(ILaunchCore.FeeType.TOKEN_CREATOR)) {
                assertEq(feeTo, owner);
                creatorFee += feeAmount;
            } else if (decodedType == uint8(ILaunchCore.FeeType.SUBPAD)) {
                assertEq(feeTo, subpadFeeTo);
                subpadFee += feeAmount;
            }
        }
    }

    function _quoteForTokens(uint256 tokenAmount, uint256 price) internal pure returns (uint256) {
        return tokenAmount * price / PRICE_POINT;
    }

    function _tokensForQuote(uint256 quoteNet, uint256 price) internal pure returns (uint256) {
        return quoteNet * PRICE_POINT / price;
    }

    function _fee(uint256 quoteAmount, uint256 feeRate) internal pure returns (uint256) {
        return quoteAmount * feeRate / PERCENT_POINT;
    }

    function _share(uint256 amount, uint256 percent) internal pure returns (uint256) {
        return amount * percent / 100;
    }

    function _curvePrice(uint256 initPrice, uint256 sellSum) internal pure returns (uint256) {
        return initPrice + sellSum * 30 / 10_000;
    }
}
