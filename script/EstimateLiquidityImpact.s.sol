// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {V4PoolUtils} from "src/v4/V4PoolUtils.sol";
import {V4PoolIntrospection} from "./v4/V4PoolIntrospection.sol";
import {V4PoolTargetLib} from "./v4/V4PoolTargetLib.sol";
import {V4BasePoolScript} from "./v4/V4BasePoolScript.sol";
import {V4PoolReporter} from "./v4/V4PoolReporter.sol";

contract EstimateLiquidityImpactScript is V4BasePoolScript {
    uint256 private constant Q96 = 1 << 96;

    struct AddedRange {
        bool enabled;
        uint256 amount0;
        uint256 amount1;
        uint160 sqrtLower;
        uint160 sqrtUpper;
        uint256 liquidity;
    }

    struct FlowBreakdown {
        uint256 token1Existing;
        uint256 token1Added;
        uint256 token0Existing;
        uint256 token0Added;
        bool priceIncreases;
    }

    function run(bytes32 poolIdInput) external {
        Config memory cfg = loadConfig();

        bytes32 poolId = poolIdInput;
        if (poolId == bytes32(0)) {
            poolId = vm.envBytes32("POOL_ID");
        }
        require(poolId != bytes32(0), "poolId required");

        uint256 fromBlock = vm.envOr("LOG_FROM_BLOCK", uint256(0));
        uint256 defaultToBlock = block.number == 0 ? 50_000_000 : block.number;
        uint256 toBlock = vm.envOr("LOG_TO_BLOCK", defaultToBlock);

        V4PoolIntrospection.PoolData memory data =
            V4PoolIntrospection.fetch(vm, cfg.poolManager, poolId, fromBlock, toBlock);

        V4PoolReporter.logTokenInfo("Token0", data.token0);
        V4PoolReporter.logTokenInfo("Token1", data.token1);
        V4PoolReporter.logSnapshot("Current state", data.snapshot, data.priceInfo, data.token0, data.token1, 6);

        V4PoolTargetLib.TargetResult memory target =
            V4PoolTargetLib.promptTargetPrice(vm, data.token0, data.token1, data.snapshot, data.snapshot.tick);
        require(target.hasTarget, "target price required");

        AddedRange memory added = _collectAddedRangeInputs(data);

        string memory marketMsg = string(
            abi.encodePacked(
                "External market price (", data.token1.symbol, " per ", data.token0.symbol, "). Leave blank to skip"
            )
        );
        (bool hasMarketPrice, uint256 marketPriceNum, uint256 marketPriceDen) = _promptDecimal(marketMsg);

        FlowBreakdown memory flow = _simulate(
            uint256(data.snapshot.liquidity),
            added.liquidity,
            data.snapshot.sqrtPriceX96,
            target.targetSqrtPriceX96,
            added.sqrtLower,
            added.sqrtUpper
        );

        _logFlowSummary(flow, data, added);

        if (flow.priceIncreases) {
            _logPriceIncreaseMetrics(flow, data, added, hasMarketPrice, marketPriceNum, marketPriceDen);
        } else {
            _logPriceDecreaseMetrics(flow, data, added, hasMarketPrice, marketPriceNum, marketPriceDen);
        }
    }

    function _collectAddedRangeInputs(V4PoolIntrospection.PoolData memory data)
        private
        returns (AddedRange memory added)
    {
        string memory addRange = _prompt("Add virtual liquidity before simulation? [y/N]");
        if (!_isYes(addRange)) {
            return added;
        }

        added.enabled = true;
        added.amount0 = _promptAmount(
            string(
                abi.encodePacked("Amount of ", data.token0.symbol, " to add (supports decimals). Leave blank for 0")
            ),
            data.token0.decimals
        );
        added.amount1 = _promptAmount(
            string(
                abi.encodePacked("Amount of ", data.token1.symbol, " to add (supports decimals). Leave blank for 0")
            ),
            data.token1.decimals
        );
        require(added.amount0 > 0 || added.amount1 > 0, "at least one token amount required");

        (uint256 lowerNum, uint256 lowerDen) = _promptDecimalRequired(
            string(
                abi.encodePacked("Lower price bound (", data.token1.symbol, " per ", data.token0.symbol, "), e.g. 0.28")
            )
        );
        (uint256 upperNum, uint256 upperDen) = _promptDecimalRequired(
            string(
                abi.encodePacked("Upper price bound (", data.token1.symbol, " per ", data.token0.symbol, "), e.g. 1.00")
            )
        );

        added.sqrtLower = _priceToSqrt(lowerNum, lowerDen, data.token0.decimals, data.token1.decimals);
        added.sqrtUpper = _priceToSqrt(upperNum, upperDen, data.token0.decimals, data.token1.decimals);
        require(added.sqrtLower < added.sqrtUpper, "lower bound must be below upper bound");

        added.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            data.snapshot.sqrtPriceX96, added.sqrtLower, added.sqrtUpper, added.amount0, added.amount1
        );

        console2.log("Added liquidity (raw) :", added.liquidity);
        console2.log(
            string(
                abi.encodePacked(
                    "Added liquidity amount0 (~): ",
                    V4PoolUtils.amountToString(added.amount0, data.token0.decimals, 6),
                    " ",
                    data.token0.symbol
                )
            )
        );
        console2.log(
            string(
                abi.encodePacked(
                    "Added liquidity amount1 (~): ",
                    V4PoolUtils.amountToString(added.amount1, data.token1.decimals, 6),
                    " ",
                    data.token1.symbol
                )
            )
        );
    }

    function _simulate(
        uint256 liquidityExisting,
        uint256 liquidityAdded,
        uint160 sqrtStart,
        uint160 sqrtTarget,
        uint160 sqrtLower,
        uint160 sqrtUpper
    ) private pure returns (FlowBreakdown memory flow) {
        if (sqrtTarget == sqrtStart) {
            return flow;
        }

        flow.priceIncreases = sqrtTarget > sqrtStart;
        uint160 current = sqrtStart;
        if (flow.priceIncreases) {
            if (current < sqrtLower) {
                uint160 end = sqrtTarget < sqrtLower ? sqrtTarget : sqrtLower;
                if (end > current) {
                    (uint256 amt0, uint256 amt1) = _computeUp(liquidityExisting, current, end);
                    flow.token0Existing += amt0;
                    flow.token1Existing += amt1;
                    current = end;
                }
            }

            if (current < sqrtTarget) {
                uint160 startInRange = current;
                if (startInRange < sqrtLower) startInRange = sqrtLower;
                uint160 endInRange = sqrtTarget;
                if (endInRange > sqrtUpper) endInRange = sqrtUpper;

                if (endInRange > startInRange) {
                    (uint256 amt0Base, uint256 amt1Base) = _computeUp(liquidityExisting, startInRange, endInRange);
                    flow.token0Existing += amt0Base;
                    flow.token1Existing += amt1Base;

                    if (liquidityAdded > 0) {
                        (uint256 amt0New, uint256 amt1New) = _computeUp(liquidityAdded, startInRange, endInRange);
                        flow.token0Added += amt0New;
                        flow.token1Added += amt1New;
                    }
                    current = endInRange;
                }
            }

            if (current < sqrtTarget) {
                (uint256 amt0, uint256 amt1) = _computeUp(liquidityExisting, current, sqrtTarget);
                flow.token0Existing += amt0;
                flow.token1Existing += amt1;
            }
        } else {
            if (current > sqrtUpper) {
                uint160 end = sqrtTarget > sqrtUpper ? sqrtUpper : sqrtTarget;
                if (end < current) {
                    (uint256 amt0, uint256 amt1) = _computeDown(liquidityExisting, current, end);
                    flow.token0Existing += amt0;
                    flow.token1Existing += amt1;
                    current = end;
                }
            }

            if (current > sqrtTarget) {
                uint160 startInRange = current;
                if (startInRange > sqrtUpper) startInRange = sqrtUpper;
                uint160 endInRange = sqrtTarget;
                if (endInRange < sqrtLower) endInRange = sqrtLower;

                if (endInRange < startInRange) {
                    (uint256 amt0Base, uint256 amt1Base) = _computeDown(liquidityExisting, startInRange, endInRange);
                    flow.token0Existing += amt0Base;
                    flow.token1Existing += amt1Base;

                    if (liquidityAdded > 0) {
                        (uint256 amt0New, uint256 amt1New) = _computeDown(liquidityAdded, startInRange, endInRange);
                        flow.token0Added += amt0New;
                        flow.token1Added += amt1New;
                    }
                    current = endInRange;
                }
            }

            if (current > sqrtTarget) {
                (uint256 amt0, uint256 amt1) = _computeDown(liquidityExisting, current, sqrtTarget);
                flow.token0Existing += amt0;
                flow.token1Existing += amt1;
            }
        }
    }

    function _computeUp(uint256 liquidity, uint160 sqrtStart, uint160 sqrtEnd)
        private
        pure
        returns (uint256 amount0Out, uint256 amount1In)
    {
        uint256 delta = uint256(sqrtEnd) - uint256(sqrtStart);
        amount1In = FullMath.mulDiv(liquidity, delta, Q96);
        amount0Out = FullMath.mulDiv(liquidity << 96, delta, uint256(sqrtEnd) * uint256(sqrtStart));
    }

    function _computeDown(uint256 liquidity, uint160 sqrtStart, uint160 sqrtEnd)
        private
        pure
        returns (uint256 amount0In, uint256 amount1Out)
    {
        uint256 delta = uint256(sqrtStart) - uint256(sqrtEnd);
        amount0In = FullMath.mulDiv(liquidity << 96, delta, uint256(sqrtStart) * uint256(sqrtEnd));
        amount1Out = FullMath.mulDiv(liquidity, delta, Q96);
    }

    function _logFlowSummary(
        FlowBreakdown memory flow,
        V4PoolIntrospection.PoolData memory data,
        AddedRange memory added
    ) private pure {
        console2.log("--------------- Swap Summary ---------------");
        console2.log("Price movement      :", flow.priceIncreases ? "Increase" : "Decrease");
        console2.log("Existing liquidity  :", uint256(data.snapshot.liquidity));
        if (added.enabled) {
            console2.log("Added liquidity     :", added.liquidity);
        }

        if (flow.priceIncreases) {
            console2.log(
                string(
                    abi.encodePacked(
                        "Token1 in (existing): ",
                        V4PoolUtils.amountToString(flow.token1Existing, data.token1.decimals, 6),
                        " ",
                        data.token1.symbol
                    )
                )
            );
            console2.log(
                string(
                    abi.encodePacked(
                        "Token1 in (added)   : ",
                        V4PoolUtils.amountToString(flow.token1Added, data.token1.decimals, 6),
                        " ",
                        data.token1.symbol
                    )
                )
            );
            console2.log(
                string(
                    abi.encodePacked(
                        "Token0 out (existing): ",
                        V4PoolUtils.amountToString(flow.token0Existing, data.token0.decimals, 6),
                        " ",
                        data.token0.symbol
                    )
                )
            );
            console2.log(
                string(
                    abi.encodePacked(
                        "Token0 out (added)  : ",
                        V4PoolUtils.amountToString(flow.token0Added, data.token0.decimals, 6),
                        " ",
                        data.token0.symbol
                    )
                )
            );
        } else {
            console2.log(
                string(
                    abi.encodePacked(
                        "Token0 in (existing): ",
                        V4PoolUtils.amountToString(flow.token0Existing, data.token0.decimals, 6),
                        " ",
                        data.token0.symbol
                    )
                )
            );
            console2.log(
                string(
                    abi.encodePacked(
                        "Token0 in (added)   : ",
                        V4PoolUtils.amountToString(flow.token0Added, data.token0.decimals, 6),
                        " ",
                        data.token0.symbol
                    )
                )
            );
            console2.log(
                string(
                    abi.encodePacked(
                        "Token1 out (existing): ",
                        V4PoolUtils.amountToString(flow.token1Existing, data.token1.decimals, 6),
                        " ",
                        data.token1.symbol
                    )
                )
            );
            console2.log(
                string(
                    abi.encodePacked(
                        "Token1 out (added)  : ",
                        V4PoolUtils.amountToString(flow.token1Added, data.token1.decimals, 6),
                        " ",
                        data.token1.symbol
                    )
                )
            );
        }
        console2.log("--------------------------------------------");
    }

    function _logPriceIncreaseMetrics(
        FlowBreakdown memory flow,
        V4PoolIntrospection.PoolData memory data,
        AddedRange memory added,
        bool hasMarketPrice,
        uint256 marketNum,
        uint256 marketDen
    ) private pure {
        uint256 totalToken1Net = flow.token1Existing + flow.token1Added;
        uint256 totalToken0Out = flow.token0Existing + flow.token0Added;

        uint24 feeMicros = data.snapshot.lpFee;
        uint256 grossToken1 = totalToken1Net;
        uint256 feeAmount = 0;
        if (feeMicros > 0 && feeMicros < 1_000_000) {
            grossToken1 = FullMath.mulDivRoundingUp(totalToken1Net, 1_000_000, 1_000_000 - feeMicros);
            feeAmount = grossToken1 - totalToken1Net;
        }

        uint256 scale0 = V4PoolUtils.pow10(data.token0.decimals);
        uint256 scale1 = V4PoolUtils.pow10(data.token1.decimals);

        uint256 avgNetPriceE18 = FullMath.mulDiv(totalToken1Net, scale0 * 1e18, totalToken0Out * scale1);
        uint256 avgGrossPriceE18 = FullMath.mulDiv(grossToken1, scale0 * 1e18, totalToken0Out * scale1);

        console2.log("Net token1 required  :", V4PoolUtils.amountToString(totalToken1Net, data.token1.decimals, 6));
        console2.log("Gross token1 (with fee):", V4PoolUtils.amountToString(grossToken1, data.token1.decimals, 6));
        console2.log("Fee amount (LP share):", V4PoolUtils.amountToString(feeAmount, data.token1.decimals, 6));
        console2.log(
            string(
                abi.encodePacked(
                    "Average net price    : ",
                    V4PoolUtils.decimalString(avgNetPriceE18, 6),
                    " ",
                    data.token1.symbol,
                    "/",
                    data.token0.symbol
                )
            )
        );
        console2.log(
            string(
                abi.encodePacked(
                    "Average gross price  : ",
                    V4PoolUtils.decimalString(avgGrossPriceE18, 6),
                    " ",
                    data.token1.symbol,
                    "/",
                    data.token0.symbol
                )
            )
        );

        if (added.enabled) {
            console2.log(
                string(
                    abi.encodePacked(
                        "Token0 sold from new range (~): ",
                        V4PoolUtils.amountToString(flow.token0Added, data.token0.decimals, 6),
                        " ",
                        data.token0.symbol
                    )
                )
            );
        }

        if (hasMarketPrice) {
            uint256 marketValueRaw =
                _valueAtPrice(totalToken0Out, marketNum, marketDen, data.token0.decimals, data.token1.decimals);
            uint256 lossNet = marketValueRaw > totalToken1Net ? marketValueRaw - totalToken1Net : 0;
            uint256 lossGross = marketValueRaw > grossToken1 ? marketValueRaw - grossToken1 : 0;

            console2.log(
                string(
                    abi.encodePacked(
                        "Value at market price : ",
                        V4PoolUtils.amountToString(marketValueRaw, data.token1.decimals, 6),
                        " ",
                        data.token1.symbol
                    )
                )
            );
            console2.log(
                string(
                    abi.encodePacked(
                        "Opportunity cost (net): ",
                        V4PoolUtils.amountToString(lossNet, data.token1.decimals, 6),
                        " ",
                        data.token1.symbol
                    )
                )
            );
            console2.log(
                string(
                    abi.encodePacked(
                        "Opportunity cost (gross): ",
                        V4PoolUtils.amountToString(lossGross, data.token1.decimals, 6),
                        " ",
                        data.token1.symbol
                    )
                )
            );
        }

        console2.log("--------------------------------------------");
    }

    function _logPriceDecreaseMetrics(
        FlowBreakdown memory flow,
        V4PoolIntrospection.PoolData memory data,
        AddedRange memory added,
        bool hasMarketPrice,
        uint256 marketNum,
        uint256 marketDen
    ) private pure {
        uint256 totalToken0Net = flow.token0Existing + flow.token0Added;
        uint256 totalToken1Out = flow.token1Existing + flow.token1Added;

        uint24 feeMicros = data.snapshot.lpFee;
        uint256 grossToken0 = totalToken0Net;
        uint256 feeAmount = 0;
        if (feeMicros > 0 && feeMicros < 1_000_000) {
            grossToken0 = FullMath.mulDivRoundingUp(totalToken0Net, 1_000_000, 1_000_000 - feeMicros);
            feeAmount = grossToken0 - totalToken0Net;
        }

        uint256 scale0 = V4PoolUtils.pow10(data.token0.decimals);
        uint256 scale1 = V4PoolUtils.pow10(data.token1.decimals);

        uint256 avgNetPriceE18 = FullMath.mulDiv(totalToken1Out, scale0 * 1e18, totalToken0Net * scale1);
        uint256 avgGrossPriceE18 = FullMath.mulDiv(totalToken1Out, scale0 * 1e18, grossToken0 * scale1);

        console2.log("Net token0 required  :", V4PoolUtils.amountToString(totalToken0Net, data.token0.decimals, 6));
        console2.log("Gross token0 (with fee):", V4PoolUtils.amountToString(grossToken0, data.token0.decimals, 6));
        console2.log("Fee amount (LP share):", V4PoolUtils.amountToString(feeAmount, data.token0.decimals, 6));
        console2.log(
            string(
                abi.encodePacked(
                    "Average net price    : ",
                    V4PoolUtils.decimalString(avgNetPriceE18, 6),
                    " ",
                    data.token1.symbol,
                    "/",
                    data.token0.symbol
                )
            )
        );
        console2.log(
            string(
                abi.encodePacked(
                    "Average gross price  : ",
                    V4PoolUtils.decimalString(avgGrossPriceE18, 6),
                    " ",
                    data.token1.symbol,
                    "/",
                    data.token0.symbol
                )
            )
        );

        if (added.enabled) {
            console2.log(
                string(
                    abi.encodePacked(
                        "Token1 sold from new range (~): ",
                        V4PoolUtils.amountToString(flow.token1Added, data.token1.decimals, 6),
                        " ",
                        data.token1.symbol
                    )
                )
            );
        }

        if (hasMarketPrice) {
            uint256 marketValueRaw =
                _valueAtPriceInverse(totalToken1Out, marketNum, marketDen, data.token0.decimals, data.token1.decimals);
            uint256 lossNet = marketValueRaw > totalToken0Net ? marketValueRaw - totalToken0Net : 0;
            uint256 lossGross = marketValueRaw > grossToken0 ? marketValueRaw - grossToken0 : 0;

            console2.log(
                string(
                    abi.encodePacked(
                        "Value at market price : ",
                        V4PoolUtils.amountToString(marketValueRaw, data.token0.decimals, 6),
                        " ",
                        data.token0.symbol
                    )
                )
            );
            console2.log(
                string(
                    abi.encodePacked(
                        "Opportunity cost (net): ",
                        V4PoolUtils.amountToString(lossNet, data.token0.decimals, 6),
                        " ",
                        data.token0.symbol
                    )
                )
            );
            console2.log(
                string(
                    abi.encodePacked(
                        "Opportunity cost (gross): ",
                        V4PoolUtils.amountToString(lossGross, data.token0.decimals, 6),
                        " ",
                        data.token0.symbol
                    )
                )
            );
        }

        console2.log("--------------------------------------------");
    }

    function _promptAmount(string memory message, uint8 decimals) private returns (uint256) {
        string memory input = _prompt(message);
        if (bytes(input).length == 0) {
            return 0;
        }
        (uint256 numerator, uint256 denominator) = _parseDecimal(input);
        uint256 scale = V4PoolUtils.pow10(decimals);
        return FullMath.mulDiv(numerator, scale, denominator);
    }

    function _prompt(string memory message) private returns (string memory value) {
        try vm.prompt(message) returns (string memory resp) {
            return _trim(resp);
        } catch (bytes memory) {
            return "";
        }
    }

    function _promptDecimal(string memory message) private returns (bool, uint256, uint256) {
        string memory input = _prompt(message);
        if (bytes(input).length == 0) {
            return (false, 0, 0);
        }
        (uint256 num, uint256 den) = _parseDecimal(input);
        return (true, num, den);
    }

    function _promptDecimalRequired(string memory message) private returns (uint256, uint256) {
        string memory input;
        do {
            input = _prompt(message);
        } while (bytes(input).length == 0);
        return _parseDecimal(input);
    }

    function _parseDecimal(string memory input) private pure returns (uint256 numerator, uint256 denominator) {
        bytes memory data = bytes(_trim(input));
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

    function _priceToSqrt(uint256 priceNum, uint256 priceDen, uint8 decimals0, uint8 decimals1)
        private
        pure
        returns (uint160 sqrtPriceX96)
    {
        require(priceNum > 0 && priceDen > 0, "invalid price");
        uint256 scale0 = V4PoolUtils.pow10(decimals0);
        uint256 scale1 = V4PoolUtils.pow10(decimals1);

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
    }

    function _valueAtPrice(
        uint256 token0AmountRaw,
        uint256 priceNum,
        uint256 priceDen,
        uint8 decimals0,
        uint8 decimals1
    ) private pure returns (uint256) {
        uint256 inter = FullMath.mulDiv(token0AmountRaw, priceNum, priceDen);
        uint256 scale0 = V4PoolUtils.pow10(decimals0);
        uint256 scale1 = V4PoolUtils.pow10(decimals1);
        return FullMath.mulDiv(inter, scale1, scale0);
    }

    function _valueAtPriceInverse(
        uint256 token1AmountRaw,
        uint256 priceNum,
        uint256 priceDen,
        uint8 decimals0,
        uint8 decimals1
    ) private pure returns (uint256) {
        uint256 inter = FullMath.mulDiv(token1AmountRaw, priceDen, priceNum);
        uint256 scale0 = V4PoolUtils.pow10(decimals0);
        uint256 scale1 = V4PoolUtils.pow10(decimals1);
        return FullMath.mulDiv(inter, scale0, scale1);
    }

    function _isYes(string memory input) private pure returns (bool) {
        bytes memory data = bytes(_trim(input));
        if (data.length == 0) return false;
        bytes1 char = data[0];
        return char == "y" || char == "Y";
    }

    function _trim(string memory value) private pure returns (string memory) {
        bytes memory data = bytes(value);
        uint256 start = 0;
        uint256 end = data.length;
        while (start < end && data[start] == 0x20) start++;
        while (end > start && data[end - 1] == 0x20) end--;
        if (start == 0 && end == data.length) {
            return value;
        }
        bytes memory out = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            out[i - start] = data[i];
        }
        return string(out);
    }

    function _pow10(uint8 exponent) private pure returns (uint256 result) {
        result = 1;
        for (uint8 i = 0; i < exponent; i++) {
            result *= 10;
        }
    }
}

