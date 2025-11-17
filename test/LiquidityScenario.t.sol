// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V4PoolTestHelper} from "./utils/PoolTestHelper.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {V4PoolUtils} from "src/v4/V4PoolUtils.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {V4PoolTargetLib} from "script/v4/V4PoolTargetLib.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

contract LiquidityScenarioTest is V4PoolTestHelper {
    bytes32 internal constant POOL_ID = 0xd098a1b12d545657bf587313c2dafbec0958cc6f110376ce31fdef86d1d213b1;

    uint256 internal constant LOWER_PRICE_NUM = 28;
    uint256 internal constant LOWER_PRICE_DEN = 100;
    uint256 internal constant UPPER_PRICE_NUM = 1;
    uint256 internal constant UPPER_PRICE_DEN = 1;
    uint256 internal constant TARGET_PRICE_NUM = 31;
    uint256 internal constant TARGET_PRICE_DEN = 100;
    uint256 internal constant LIQUIDITY_AMOUNT0 = 28_100 ether;

    function setUp() public {
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(38_249_249));
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

    function testLiquidityAndSwapMatchesEstimates() public {
        (V4PoolUtils.PoolSnapshot memory beforeSnapshot,,,) = getPoolState();

        int24 tickLower = priceToLowerTick(LOWER_PRICE_NUM, LOWER_PRICE_DEN);
        int24 tickUpper = priceToUpperTick(UPPER_PRICE_NUM, UPPER_PRICE_DEN);

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidityFromAmount0 =
            LiquidityAmounts.getLiquidityForAmount0(beforeSnapshot.sqrtPriceX96, sqrtUpper, LIQUIDITY_AMOUNT0);
        uint256 amount1Required =
            LiquidityAmounts.getAmount1ForLiquidity(sqrtLower, beforeSnapshot.sqrtPriceX96, liquidityFromAmount0);

        (uint128 liquidityMinted, uint256 amount0Used, uint256 amount1Used, BalanceDelta addDelta) =
            addLiquidityTicks(tickLower, tickUpper, LIQUIDITY_AMOUNT0, amount1Required, bytes32(0));

        assertGt(liquidityMinted, 0, "liquidity should be minted");
        assertApproxEqAbs(uint256(liquidityMinted), uint256(liquidityFromAmount0), 1e9, "liquidity mismatch");

        (uint256 expectedAmount0, uint256 expectedAmount1) =
            LiquidityAmounts.getAmountsForLiquidity(beforeSnapshot.sqrtPriceX96, sqrtLower, sqrtUpper, liquidityMinted);
        assertApproxEqAbs(amount0Used, expectedAmount0, 1e15, "token0 allocation mismatch");
        assertApproxEqAbs(amount1Used, expectedAmount1, 1e3, "token1 allocation mismatch");
        assertLt(addDelta.amount0(), 0, "token0 delta should be negative");
        assertLt(addDelta.amount1(), 0, "token1 delta should be negative");

        (V4PoolUtils.PoolSnapshot memory snapshotAfterAdd,,,) = getPoolState();
        assertGt(uint256(snapshotAfterAdd.liquidity), uint256(beforeSnapshot.liquidity), "liquidity should increase");

        (V4PoolTargetLib.TargetResult memory target, int24 targetTick) =
            estimateSwapForPrice(TARGET_PRICE_NUM, TARGET_PRICE_DEN);
        assertTrue(target.hasTarget, "target result expected");
        assertFalse(target.zeroForOne, "expected token1 -> token0 swap to raise price");

        uint24 lpFee = snapshotAfterAdd.lpFee;
        uint256 amountInGross = target.inputAmount;
        if (lpFee > 0 && lpFee < 1_000_000) {
            amountInGross = FullMath.mulDivRoundingUp(target.inputAmount, 1_000_000, 1_000_000 - lpFee);
        }

        BalanceDelta swapDelta = swapExactInput(target.zeroForOne, amountInGross, 0, target.targetSqrtPriceX96);

        V4PoolUtils.PoolSnapshot memory finalSnapshot;
        V4PoolUtils.PriceInfo memory finalPrice;
        (finalSnapshot,,, finalPrice) = getPoolState();

        assertApproxEqAbs(int256(finalSnapshot.tick), int256(targetTick), 1, "tick mismatch");

        V4PoolUtils.PriceInfo memory targetPriceInfo =
            V4PoolUtils.computePrices(TickMath.getSqrtPriceAtTick(targetTick), token0Meta, token1Meta);
        assertApproxEqRel(finalPrice.price1Per0E18, targetPriceInfo.price1Per0E18, 5e15, "final price mismatch");

        uint256 usdcSpentGross = uint256(uint128(uint256(int256(-swapDelta.amount1()))));
        assertEq(usdcSpentGross, amountInGross, "gross input mismatch");

        uint256 feeAmount = lpFee == 0 ? 0 : FullMath.mulDivRoundingUp(usdcSpentGross, lpFee, 1_000_000);
        uint256 usdcNet = usdcSpentGross - feeAmount;
        assertApproxEqRel(usdcNet, target.inputAmount, 5e15, "net input mismatch");

        uint256 somiReceived = uint256(uint128(uint256(int256(swapDelta.amount0()))));
        assertApproxEqRel(somiReceived, target.outputAmount, 5e15, "output mismatch");

        emit log_named_decimal_uint("USDC gross in", usdcSpentGross, token1Meta.decimals);
        emit log_named_decimal_uint("USDC net in", usdcNet, token1Meta.decimals);
        emit log_named_decimal_uint("USDC fee", feeAmount, token1Meta.decimals);
        emit log_named_decimal_uint("SOMI received", somiReceived, token0Meta.decimals);
        emit log_named_decimal_uint("Final price (USDC per SOMI)", finalPrice.price1Per0E18, 18);

        uint256 privateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        if (privateKey != 0) {
            address signer = vm.addr(privateKey);
            emit log_named_decimal_uint("Signer SOMI balance", token0Asset().balanceOf(signer), token0Meta.decimals);
            emit log_named_decimal_uint("Signer USDC balance", token1Asset().balanceOf(signer), token1Meta.decimals);
        }
    }
}

