// SPDX-License-Identifier: MIT
pragma solidity >=0.8.12 <0.9.0;

import "./utils/V3PoolTestHelper.sol";

import {V3PoolUtils} from "src/v3/V3PoolUtils.sol";
import {V3PoolIntrospection} from "script/v3/V3PoolIntrospection.sol";
import {V3PoolTargetLib} from "script/v3/V3PoolTargetLib.sol";

contract V3PoolUtilsTest is V3PoolTestHelper {
    uint24 internal constant DEFAULT_FEE = 3_000;

    function setUp() public {
        _deployV3Pool(DEFAULT_FEE, 0);
        _mintLiquidity(-600, 600, 1e9);
    }

    function testSummarizePoolReturnsMetadata() public {
        (
            V3PoolUtils.PoolSnapshot memory snapshot,
            V3PoolUtils.TokenMetadata memory token0Meta,
            V3PoolUtils.TokenMetadata memory token1Meta,
            V3PoolUtils.PriceInfo memory priceInfo
        ) = V3PoolUtils.summarizePool(pool);

        assertEq(snapshot.pool, address(pool), "snapshot pool mismatch");
        assertEq(snapshot.fee, DEFAULT_FEE, "fee mismatch");
        assertEq(snapshot.tickSpacing, pool.tickSpacing(), "tick spacing mismatch");
        assertEq(token0Meta.token, address(token0), "token0 meta mismatch");
        assertEq(token1Meta.token, address(token1), "token1 meta mismatch");
        assertApproxEqAbs(int256(snapshot.tick), 0, 1, "tick should be close to zero");
        assertApproxEqAbs(priceInfo.price1Per0E18, 1e18, 1e15, "price1 per0 mismatch");
        assertApproxEqAbs(priceInfo.price0Per1E18, 1e18, 1e15, "price0 per1 mismatch");
    }

    function testIntrospectionFetchesPoolData() public {
        V3PoolIntrospection.PoolData memory data = V3PoolIntrospection.fetch(vm, address(pool));
        assertEq(address(data.pool), address(pool), "pool address mismatch");
        assertEq(data.snapshot.pool, address(pool), "snapshot pool mismatch");
        assertEq(data.token0.token, address(token0), "token0 mismatch");
        assertEq(data.token1.token, address(token1), "token1 mismatch");
        assertEq(data.priceInfo.price1Per0E18, data.priceInfo.price1Per0E18, "price info should be set");
    }

    function testTargetFromTickProducesSwapAmounts() public {
        (
            V3PoolUtils.PoolSnapshot memory snapshot,
            V3PoolUtils.TokenMetadata memory token0Meta,
            V3PoolUtils.TokenMetadata memory token1Meta,
            V3PoolUtils.PriceInfo memory priceInfo
        ) = V3PoolUtils.summarizePool(pool);
        int24 targetTick = V3PoolTargetLib.toInt24(int256(snapshot.tick) + 120);

        V3PoolTargetLib.TargetResult memory target = V3PoolTargetLib.targetFromTick(snapshot, targetTick);
        assertTrue(target.hasTarget, "target expected");
        assertFalse(target.zeroForOne, "expect price increase");
        assertGt(target.inputAmount, 0, "input should be positive");
        assertGt(target.outputAmount, 0, "output should be positive");
        assertEq(target.targetTick, targetTick, "tick mismatch");

        (string memory forward,) = V3PoolUtils.tickToPriceStrings(targetTick, token0Meta, token1Meta, 6);
        assertGt(bytes(forward).length, 0, "price string expected");
        assertApproxEqAbs(priceInfo.price1Per0E18, 1e18, 1e15, "initial price sanity");
    }
}

