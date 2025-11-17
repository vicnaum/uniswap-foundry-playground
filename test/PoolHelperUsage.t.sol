// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V4PoolTestHelper} from "./utils/PoolTestHelper.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {console2} from "forge-std/console2.sol";
import {V4PoolUtils} from "src/v4/V4PoolUtils.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract PoolHelperUsageTest is V4PoolTestHelper {
    bytes32 internal constant POOL_ID = 0xd098a1b12d545657bf587313c2dafbec0958cc6f110376ce31fdef86d1d213b1;
    uint256 internal constant DEFAULT_BASE_BLOCK = 38_249_249;

    function setUp() public {
        uint256 forkBlock = vm.envOr("FORK_BLOCK", DEFAULT_BASE_BLOCK);
        string memory rpcUrl = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        }
        if (bytes(rpcUrl).length == 0) {
            string memory rpcAlias = vm.envOr("FORK_RPC_ALIAS", string("base"));
            rpcUrl = vm.rpcUrl(rpcAlias);
        }
        uint256 forkId = forkBlock == 0 ? vm.createFork(rpcUrl) : vm.createFork(rpcUrl, forkBlock);
        vm.selectFork(forkId);

        uint256 fromBlock = vm.envOr("LOG_FROM_BLOCK", uint256(0));
        uint256 toBlock = vm.envOr("LOG_TO_BLOCK", uint256(0));

        IPoolManager manager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        initPool(manager, POOL_ID, fromBlock, toBlock);
    }

    function testAddAndRemoveLiquidityRoundTrip() public {
        (V4PoolUtils.PoolSnapshot memory snapshot,,,) = getPoolState();
        console2.log("Current tick", snapshot.tick);
        console2.log("Current sqrtPriceX96", snapshot.sqrtPriceX96);
        console2.log("Current liquidity", snapshot.liquidity);
        console2.log("Tick spacing", poolKey.tickSpacing);

        int24 tickLower = priceToLowerTick(25, 100);
        int24 tickUpper = priceToUpperTick(80, 100);
        console2.log("Computed tickLower", tickLower);
        console2.log("Computed tickUpper", tickUpper);

        uint256 amount0Desired = 1 ether;
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        console2.log("sqrtPriceX96 (current)", snapshot.sqrtPriceX96);
        console2.log("sqrtLowerX96", sqrtLower);
        console2.log("sqrtUpperX96", sqrtUpper);

        uint128 liquidityFromAmount0 =
            LiquidityAmounts.getLiquidityForAmount0(snapshot.sqrtPriceX96, sqrtUpper, amount0Desired);
        uint256 amount1Desired =
            LiquidityAmounts.getAmount1ForLiquidity(sqrtLower, snapshot.sqrtPriceX96, liquidityFromAmount0);

        console2.log("Calculated amount1Desired", amount1Desired);

        (uint128 liquidityAdded, uint256 amount0Used, uint256 amount1Used,) =
            addLiquidityTicks(tickLower, tickUpper, amount0Desired, amount1Desired, bytes32(0));
        assertGt(liquidityAdded, 0, "liquidity should be minted");
        assertLe(amount0Used, amount0Desired, "token0 should not exceed requested");
        assertLe(amount1Used, amount1Desired, "token1 should not exceed requested");
        assertGt(amount0Used, 0, "token0 should be consumed");
        assertGt(amount1Used, 0, "token1 should be consumed");

        BalanceDelta deltaRemove = removeLiquidityTicks(tickLower, tickUpper, liquidityAdded, bytes32(0));
        assertGt(deltaRemove.amount0(), 0, "token0 should be returned on removal");
        assertGt(deltaRemove.amount1(), 0, "token1 should be returned on removal");
    }

    function testAddLiquidityBelowCurrentTick() public {
        (V4PoolUtils.PoolSnapshot memory snapshot,,,) = getPoolState();

        uint256 priceBelow = 2e17; // 0.2 USDC per SOMI
        int24 tickUpper = priceToUpperTick(priceBelow, 1e18);
        int24 tickLower = tickUpper - poolKey.tickSpacing * 10;
        assertLt(tickUpper, snapshot.tick, "range should sit below current tick");

        uint128 targetLiquidity = 1e12;
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        (uint256 amount0Req, uint256 amount1Req) =
            LiquidityAmounts.getAmountsForLiquidity(snapshot.sqrtPriceX96, sqrtLower, sqrtUpper, targetLiquidity);

        (uint128 liquidityAdded, uint256 amount0Used, uint256 amount1Used,) =
            addLiquidityTicks(tickLower, tickUpper, amount0Req + 10, amount1Req + 10, bytes32("below"));

        assertGe(liquidityAdded, targetLiquidity, "liquidity should at least match target");
        assertEq(amount0Used, 0, "token0 should not be consumed below range");
        assertGt(amount1Used, 0, "token1 should be consumed below range");
    }

    function testAddLiquidityAboveCurrentTick() public {
        (V4PoolUtils.PoolSnapshot memory snapshot,,,) = getPoolState();

        uint256 priceAbove = 5e17; // 0.5 USDC per SOMI
        int24 tickLower = priceToLowerTick(priceAbove, 1e18);
        int24 tickUpper = tickLower + poolKey.tickSpacing * 10;
        assertGt(tickLower, snapshot.tick, "range should sit above current tick");

        uint128 targetLiquidity = 1e12;
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        (uint256 amount0Req, uint256 amount1Req) =
            LiquidityAmounts.getAmountsForLiquidity(snapshot.sqrtPriceX96, sqrtLower, sqrtUpper, targetLiquidity);

        (uint128 liquidityAdded, uint256 amount0Used, uint256 amount1Used,) =
            addLiquidityTicks(tickLower, tickUpper, amount0Req + 10, amount1Req + 10, bytes32("above"));

        assertGe(liquidityAdded, targetLiquidity, "liquidity should at least match target");
        assertGt(amount0Used, 0, "token0 should be consumed above range");
        assertEq(amount1Used, 0, "token1 should not be consumed above range");
    }

    function testSwapSomiForUsdcExactInput() public {
        uint256 amountIn = 1e15; // 0.001 SOMI
        (V4PoolUtils.PoolSnapshot memory beforeSnapshot,,,) = getPoolState();

        BalanceDelta delta = swapExactInput(true, amountIn, 0, 0);
        (V4PoolUtils.PoolSnapshot memory afterSnapshot,,,) = getPoolState();

        assertLt(delta.amount0(), 0, "token0 should decrease");
        assertGt(delta.amount1(), 0, "token1 should increase");
        assertLt(afterSnapshot.sqrtPriceX96, beforeSnapshot.sqrtPriceX96, "price should move down");
    }

    function testSwapUsdcForSomiExactInput() public {
        uint256 amountIn = 10_000; // 0.01 USDC (6 decimals)
        (V4PoolUtils.PoolSnapshot memory beforeSnapshot,,,) = getPoolState();

        BalanceDelta delta = swapExactInput(false, amountIn, 0, 0);
        (V4PoolUtils.PoolSnapshot memory afterSnapshot,,,) = getPoolState();

        assertLt(delta.amount1(), 0, "token1 should decrease");
        assertGt(delta.amount0(), 0, "token0 should increase");
        assertGt(afterSnapshot.sqrtPriceX96, beforeSnapshot.sqrtPriceX96, "price should move up");
    }
}

