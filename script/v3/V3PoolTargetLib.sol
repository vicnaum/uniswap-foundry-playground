// SPDX-License-Identifier: MIT
pragma solidity >=0.8.12 <0.9.0;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";

import {V3PoolUtils} from "src/v3/V3PoolUtils.sol";

library V3PoolTargetLib {
    struct TargetResult {
        bool hasTarget;
        int24 targetTick;
        uint160 targetSqrtPriceX96;
        uint256 inputAmount;
        uint256 outputAmount;
        bool zeroForOne;
    }

    uint256 private constant Q96 = 1 << 96;
    uint256 private constant Q192 = 1 << 192;

    function promptTargetPrice(
        Vm vm,
        V3PoolUtils.TokenMetadata memory token0,
        V3PoolUtils.TokenMetadata memory token1,
        V3PoolUtils.PoolSnapshot memory snapshot,
        int24 initialTick
    ) internal returns (TargetResult memory result) {
        string memory forwardPrompt = string(
            abi.encodePacked(
                "Target price ",
                token0.symbol,
                "/",
                token1.symbol,
                " (",
                token1.symbol,
                " per ",
                token0.symbol,
                "). Leave blank to skip"
            )
        );

        string memory directInput = _prompt(vm, forwardPrompt);
        if (bytes(directInput).length > 0) {
            (uint256 num, uint256 den) = _parseDecimal(directInput);
            return _targetFromPrice(token0, token1, snapshot, num, den);
        }

        string memory inversePrompt = string(
            abi.encodePacked(
                "Target price ",
                token1.symbol,
                "/",
                token0.symbol,
                " (",
                token0.symbol,
                " per ",
                token1.symbol,
                "). Leave blank to skip"
            )
        );
        string memory inverseInput = _prompt(vm, inversePrompt);
        if (bytes(inverseInput).length > 0) {
            (uint256 inverseNum, uint256 inverseDen) = _parseDecimal(inverseInput);
            return _targetFromPrice(token0, token1, snapshot, inverseDen, inverseNum);
        }

        console2.log("No target price provided. Current tick:", initialTick);
        return result;
    }

    function targetFromTick(V3PoolUtils.PoolSnapshot memory snapshot, int24 targetTick)
        internal
        pure
        returns (TargetResult memory result)
    {
        uint160 sqrtTarget = TickMath.getSqrtRatioAtTick(targetTick);
        return _buildResult(snapshot, targetTick, sqrtTarget);
    }

    function logTarget(
        TargetResult memory result,
        V3PoolUtils.TokenMetadata memory token0,
        V3PoolUtils.TokenMetadata memory token1
    ) internal pure {
        console2.log("Target tick              :", result.targetTick);
        console2.log("Target sqrtPriceX96      :", uint256(result.targetSqrtPriceX96));
        (string memory forward, string memory inverse) =
            V3PoolUtils.tickToPriceStrings(result.targetTick, token0, token1, 6);
        console2.log(forward);
        console2.log(inverse);

        if (!result.hasTarget || result.inputAmount == 0) {
            console2.log("Pool already at target price.");
            return;
        }

        if (result.zeroForOne) {
            console2.log("Swap direction        :", string(abi.encodePacked(token0.symbol, " -> ", token1.symbol)));
            console2.log("Input amount (raw)    :", result.inputAmount);
            console2.log(
                string(
                    abi.encodePacked(
                        "Input amount (~)     : ",
                        V3PoolUtils.amountToString(result.inputAmount, token0.decimals, 6),
                        " ",
                        token0.symbol
                    )
                )
            );
            console2.log("Expected output (raw) :", result.outputAmount);
            console2.log(
                string(
                    abi.encodePacked(
                        "Expected output (~)  : ",
                        V3PoolUtils.amountToString(result.outputAmount, token1.decimals, 6),
                        " ",
                        token1.symbol
                    )
                )
            );
        } else {
            console2.log("Swap direction        :", string(abi.encodePacked(token1.symbol, " -> ", token0.symbol)));
            console2.log("Input amount (raw)    :", result.inputAmount);
            console2.log(
                string(
                    abi.encodePacked(
                        "Input amount (~)     : ",
                        V3PoolUtils.amountToString(result.inputAmount, token1.decimals, 6),
                        " ",
                        token1.symbol
                    )
                )
            );
            console2.log("Expected output (raw) :", result.outputAmount);
            console2.log(
                string(
                    abi.encodePacked(
                        "Expected output (~)  : ",
                        V3PoolUtils.amountToString(result.outputAmount, token0.decimals, 6),
                        " ",
                        token0.symbol
                    )
                )
            );
        }
    }

    function toInt24(int256 value) internal pure returns (int24) {
        require(value >= type(int24).min && value <= type(int24).max, "int24 overflow");
        return int24(value);
    }

    function _targetFromPrice(
        V3PoolUtils.TokenMetadata memory token0,
        V3PoolUtils.TokenMetadata memory token1,
        V3PoolUtils.PoolSnapshot memory snapshot,
        uint256 priceNum,
        uint256 priceDen
    ) private pure returns (TargetResult memory result) {
        require(priceNum > 0 && priceDen > 0, "invalid price");
        (int24 tickTarget, uint160 sqrtPriceTarget) =
            _computeTickFromPrice(priceNum, priceDen, token0.decimals, token1.decimals);
        return _buildResult(snapshot, tickTarget, sqrtPriceTarget);
    }

    function _buildResult(V3PoolUtils.PoolSnapshot memory snapshot, int24 targetTick, uint160 targetSqrtPriceX96)
        private
        pure
        returns (TargetResult memory result)
    {
        result.hasTarget = true;
        result.targetTick = targetTick;
        result.targetSqrtPriceX96 = targetSqrtPriceX96;

        uint160 sqrtCurrent = snapshot.sqrtPriceX96;
        if (targetSqrtPriceX96 == sqrtCurrent) {
            return result;
        }

        uint256 liquidity = uint256(snapshot.liquidity);
        if (liquidity == 0) {
            return result;
        }

        if (targetSqrtPriceX96 < sqrtCurrent) {
            result.zeroForOne = true;
            uint256 numerator = FullMath.mulDiv(
                liquidity << 96, sqrtCurrent - targetSqrtPriceX96, uint256(targetSqrtPriceX96) * sqrtCurrent
            );
            uint256 output = FullMath.mulDiv(liquidity, sqrtCurrent - targetSqrtPriceX96, Q96);
            result.inputAmount = numerator;
            result.outputAmount = output;
        } else {
            result.zeroForOne = false;
            uint256 input = FullMath.mulDiv(liquidity, targetSqrtPriceX96 - sqrtCurrent, Q96);
            uint256 output = FullMath.mulDiv(
                liquidity << 96, targetSqrtPriceX96 - sqrtCurrent, uint256(targetSqrtPriceX96) * sqrtCurrent
            );
            result.inputAmount = input;
            result.outputAmount = output;
        }
    }

    function _computeTickFromPrice(uint256 priceNum, uint256 priceDen, uint8 decimals0, uint8 decimals1)
        private
        pure
        returns (int24 tick, uint160 sqrtPriceX96)
    {
        uint256 scale0 = _pow10(decimals0);
        uint256 scale1 = _pow10(decimals1);

        uint256 ratioNumerator = priceNum * scale1;
        require(ratioNumerator / scale1 == priceNum, "ratio overflow");
        uint256 ratioDenominator = priceDen * scale0;
        require(ratioDenominator / scale0 == priceDen, "ratio overflow");

        uint256 value = FullMath.mulDiv(ratioNumerator, Q192, ratioDenominator);
        uint256 sqrtValue = _sqrt(value);
        require(sqrtValue >= TickMath.MIN_SQRT_RATIO, "price below bounds");
        require(sqrtValue <= TickMath.MAX_SQRT_RATIO, "price above bounds");

        sqrtPriceX96 = uint160(sqrtValue);
        tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);
    }

    function _prompt(Vm vm, string memory message) private returns (string memory value) {
        try vm.prompt(message) returns (string memory resp) {
            return resp;
        } catch (bytes memory) {
            return "";
        }
    }

    function _parseDecimal(string memory input) private pure returns (uint256 numerator, uint256 denominator) {
        bytes memory data = bytes(input);
        require(data.length > 0, "empty input");

        bool seenDot = false;
        uint8 decimalsCount = 0;

        for (uint256 i = 0; i < data.length; i++) {
            bytes1 char = data[i];
            if (char == ".") {
                require(!seenDot, "multiple decimal points");
                seenDot = true;
            } else {
                require(char >= "0" && char <= "9", "invalid character");
                uint256 digit = uint8(char) - 48;
                numerator = numerator * 10 + digit;
                if (seenDot) {
                    decimalsCount++;
                }
            }
        }

        require(numerator > 0, "zero value");
        require(decimalsCount <= 18, "too many decimals");

        denominator = decimalsCount == 0 ? 1 : _pow10(decimalsCount);
    }

    function _pow10(uint8 exponent) private pure returns (uint256) {
        require(exponent <= 38, "exponent too large");
        uint256 result = 1;
        for (uint8 i = 0; i < exponent; i++) {
            result *= 10;
        }
        return result;
    }

    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) {
            return 0;
        }
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}

