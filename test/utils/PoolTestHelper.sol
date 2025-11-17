// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {V4PoolUtils} from "src/v4/V4PoolUtils.sol";
import {V4PoolIntrospection} from "script/v4/V4PoolIntrospection.sol";
import {V4PoolTargetLib} from "script/v4/V4PoolTargetLib.sol";

abstract contract V4PoolTestHelper is Test {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager internal poolManager;
    PoolKey internal poolKey;
    V4PoolUtils.TokenMetadata internal token0Meta;
    V4PoolUtils.TokenMetadata internal token1Meta;

    PoolModifyLiquidityTest internal liquidityHelper;
    PoolSwapTest internal swapHelper;

    /// @notice Initialize helpers for a given pool id.
    function initPool(IPoolManager manager, bytes32 poolId, uint256 fromBlock, uint256 toBlock) internal {
        poolManager = manager;

        if (toBlock == 0) {
            toBlock = block.number;
        }

        V4PoolIntrospection.PoolData memory data =
            V4PoolIntrospection.fetch(vm, poolManager, poolId, fromBlock, toBlock);

        poolKey = data.key;
        token0Meta = data.token0;
        token1Meta = data.token1;

        liquidityHelper = new PoolModifyLiquidityTest(poolManager);
        swapHelper = new PoolSwapTest(poolManager);

        _ensureAllowance(token0Meta.token, address(liquidityHelper));
        _ensureAllowance(token1Meta.token, address(liquidityHelper));
        _ensureAllowance(token0Meta.token, address(swapHelper));
        _ensureAllowance(token1Meta.token, address(swapHelper));
    }

    /// @notice Fetch the latest pool snapshot and price info.
    function getPoolState()
        internal
        view
        returns (
            V4PoolUtils.PoolSnapshot memory snapshot,
            V4PoolUtils.TokenMetadata memory token0,
            V4PoolUtils.TokenMetadata memory token1,
            V4PoolUtils.PriceInfo memory priceInfo
        )
    {
        return V4PoolUtils.summarizePool(poolManager, poolKey);
    }

    /// @notice Convenience wrapper to add liquidity using token amounts.
    function addLiquidityTicks(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        bytes32 salt
    ) internal returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used, BalanceDelta delta) {
        (V4PoolUtils.PoolSnapshot memory snapshot,,,) = getPoolState();

        uint160 sqrtPriceX96 = snapshot.sqrtPriceX96;
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, amount0Desired, amount1Desired
        );
        require(liquidity > 0, "liquidity zero");

        (amount0Used, amount1Used) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity);

        console2.log("Helper:addLiquidity - amount0Used", amount0Used);
        console2.log("Helper:addLiquidity - amount1Used", amount1Used);

        uint256 amount0Fund = amount0Used + 1;
        uint256 amount1Fund = amount1Used == 0 ? 0 : amount1Used + 1;

        console2.log("Helper:addLiquidity - funding amount0", amount0Fund);
        console2.log("Helper:addLiquidity - funding amount1", amount1Fund);

        _fundToken(token0Meta.token, amount0Fund);
        _fundToken(token1Meta.token, amount1Fund);

        console2.log(
            "Helper:addLiquidity - balance token0 post-fund", IERC20(token0Meta.token).balanceOf(address(this))
        );
        console2.log(
            "Helper:addLiquidity - balance token1 post-fund", IERC20(token1Meta.token).balanceOf(address(this))
        );
        console2.log(
            "Helper:addLiquidity - allowance token0",
            IERC20(token0Meta.token).allowance(address(this), address(liquidityHelper))
        );
        console2.log(
            "Helper:addLiquidity - allowance token1",
            IERC20(token1Meta.token).allowance(address(this), address(liquidityHelper))
        );

        delta = liquidityHelper.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: salt
            }),
            ""
        );
    }

    /// @notice Remove liquidity from a range.
    function removeLiquidityTicks(int24 tickLower, int24 tickUpper, uint128 liquidity, bytes32 salt)
        internal
        returns (BalanceDelta delta)
    {
        delta = liquidityHelper.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(liquidity)),
                salt: salt
            }),
            ""
        );
    }

    /// @notice Perform an exact-input swap.
    function swapExactInput(bool zeroForOne, uint256 amountIn, uint256 minAmountOut, uint160 sqrtPriceLimitX96)
        internal
        returns (BalanceDelta delta)
    {
        require(amountIn > 0, "amountIn zero");
        require(amountIn <= type(uint128).max, "amountIn too large");

        if (sqrtPriceLimitX96 == 0) {
            sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }

        if (zeroForOne) {
            _fundToken(token0Meta.token, amountIn);
        } else {
            _fundToken(token1Meta.token, amountIn);
        }

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        delta = swapHelper.swap(poolKey, params, settings, "");

        if (minAmountOut > 0) {
            uint256 actualOut = zeroForOne
                ? uint256(uint128(uint256(int256(-delta.amount1()))))
                : uint256(uint128(uint256(int256(-delta.amount0()))));
            require(actualOut >= minAmountOut, "slippage exceeded");
        }
    }

    /// @notice Convert a price ratio (token1 per token0) to the nearest usable tick.
    function priceToNearestTick(uint256 priceNum, uint256 priceDen) internal view returns (int24) {
        (int24 rawTick,) = _priceToTick(priceNum, priceDen);
        return _nearestTick(rawTick);
    }

    /// @notice Convert a price ratio to a tick floored to tick spacing (useful for lower ranges).
    function priceToLowerTick(uint256 priceNum, uint256 priceDen) internal view returns (int24) {
        (int24 rawTick,) = _priceToTick(priceNum, priceDen);
        return _floorTick(rawTick);
    }

    /// @notice Convert a price ratio to a tick ceiled to tick spacing (useful for upper ranges).
    function priceToUpperTick(uint256 priceNum, uint256 priceDen) internal view returns (int24) {
        (int24 rawTick,) = _priceToTick(priceNum, priceDen);
        return _ceilTick(rawTick);
    }

    /// @notice Compute the target result required to reach a price.
    function estimateSwapForPrice(uint256 priceNum, uint256 priceDen)
        internal
        view
        returns (V4PoolTargetLib.TargetResult memory result, int24 targetTick)
    {
        (V4PoolUtils.PoolSnapshot memory snapshot,,,) = getPoolState();
        targetTick = priceToNearestTick(priceNum, priceDen);
        result = V4PoolTargetLib.targetFromTick(snapshot, targetTick);
    }

    function token0Asset() internal view returns (IERC20) {
        return IERC20(token0Meta.token);
    }

    function token1Asset() internal view returns (IERC20) {
        return IERC20(token1Meta.token);
    }

    function _priceToTick(uint256 priceNum, uint256 priceDen) private view returns (int24 tick, uint160 sqrtPriceX96) {
        require(priceNum > 0 && priceDen > 0, "invalid price");

        uint256 scale0 = V4PoolUtils.pow10(token0Meta.decimals);
        uint256 scale1 = V4PoolUtils.pow10(token1Meta.decimals);

        uint256 ratioNumerator = priceNum * scale1;
        require(ratioNumerator / scale1 == priceNum, "ratio overflow");
        uint256 ratioDenominator = priceDen * scale0;
        require(ratioDenominator / scale0 == priceDen, "ratio overflow");

        uint256 value = FullMath.mulDiv(ratioNumerator, 1 << 192, ratioDenominator);
        uint256 sqrtValue = Math.sqrt(value);
        require(sqrtValue >= TickMath.MIN_SQRT_PRICE, "price below bounds");
        require(sqrtValue <= TickMath.MAX_SQRT_PRICE, "price above bounds");

        // forge-lint: disable-next-line(unsafe-typecast)
        sqrtPriceX96 = uint160(sqrtValue);
        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    function _nearestTick(int24 tick) private view returns (int24) {
        int24 floorTick = _floorTick(tick);
        int24 ceilTick = _ceilTick(tick);
        if (ceilTick == floorTick) {
            return floorTick;
        }

        int256 diffFloor = int256(tick) - int256(floorTick);
        int256 diffCeil = int256(ceilTick) - int256(tick);
        if (diffFloor <= diffCeil) {
            return floorTick;
        }
        return ceilTick;
    }

    function _floorTick(int24 tick) private view returns (int24) {
        int24 spacing = poolKey.tickSpacing;
        int24 remainder = tick % spacing;
        if (remainder == 0) return tick;
        int24 adjusted = tick - remainder;
        if (tick < 0) {
            adjusted -= spacing;
        }
        return adjusted;
    }

    function _ceilTick(int24 tick) private view returns (int24) {
        int24 spacing = poolKey.tickSpacing;
        int24 remainder = tick % spacing;
        if (remainder == 0) return tick;
        int24 adjusted = tick - remainder;
        if (tick > 0) {
            adjusted += spacing;
        }
        return adjusted;
    }

    function _ensureAllowance(address token, address spender) private {
        if (token == address(0)) {
            return;
        }
        IERC20 erc20 = IERC20(token);
        uint256 current = erc20.allowance(address(this), spender);
        if (current == 0) {
            bool success = erc20.approve(spender, type(uint256).max);
            require(success, "approve failed");
            console2.log("Helper:_ensureAllowance approved", token);
        }
    }

    function _fundToken(address token, uint256 amount) private {
        if (amount == 0 || token == address(0)) {
            return;
        }
        IERC20 erc20 = IERC20(token);
        uint256 current = erc20.balanceOf(address(this));
        uint256 newBalance = current + amount;
        deal(token, address(this), newBalance);
        console2.log("Helper:_fundToken funded token", token);
        console2.log("Helper:_fundToken new balance", newBalance);
    }
}

