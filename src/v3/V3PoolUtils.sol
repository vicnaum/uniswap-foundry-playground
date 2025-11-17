// SPDX-License-Identifier: MIT
pragma solidity >=0.8.12 <0.9.0;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

library V3PoolUtils {
    error ExponentTooLarge(uint8 exponent);

    uint256 private constant Q192 = uint256(1) << 192;
    uint256 private constant E18 = 1e18;
    uint256 private constant E36 = 1e36;

    struct TokenMetadata {
        address token;
        string symbol;
        string name;
        uint8 decimals;
    }

    struct PoolSnapshot {
        address pool;
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
        uint24 fee;
        int24 tickSpacing;
    }

    struct PriceInfo {
        uint256 price1Per0E18;
        uint256 price0Per1E18;
    }

    function fetchSnapshot(IUniswapV3Pool pool) internal view returns (PoolSnapshot memory snap) {
        (uint160 sqrtPriceX96, int24 tick,,,,,) = pool.slot0();
        uint128 liquidity = pool.liquidity();
        snap = PoolSnapshot({
            pool: address(pool),
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            liquidity: liquidity,
            fee: pool.fee(),
            tickSpacing: pool.tickSpacing()
        });
    }

    function fetchTokenMetadata(address token) internal view returns (TokenMetadata memory meta) {
        if (token == address(0)) {
            return TokenMetadata({token: token, symbol: "ETH", name: "Ether", decimals: 18});
        }

        string memory symbol = "???";
        string memory name = "";
        uint8 decimals = 18;
        IERC20Metadata erc20 = IERC20Metadata(token);

        try erc20.symbol() returns (string memory sym) {
            symbol = sym;
        } catch {}

        try erc20.name() returns (string memory nm) {
            name = nm;
        } catch {}

        try erc20.decimals() returns (uint8 dec) {
            decimals = dec;
        } catch {}

        meta = TokenMetadata({token: token, symbol: symbol, name: name, decimals: decimals});
    }

    function summarizePool(IUniswapV3Pool pool)
        internal
        view
        returns (
            PoolSnapshot memory snapshot,
            TokenMetadata memory token0,
            TokenMetadata memory token1,
            PriceInfo memory priceInfo
        )
    {
        snapshot = fetchSnapshot(pool);
        token0 = fetchTokenMetadata(pool.token0());
        token1 = fetchTokenMetadata(pool.token1());
        priceInfo = computePrices(snapshot.sqrtPriceX96, token0, token1);
    }

    function computePrices(uint160 sqrtPriceX96, TokenMetadata memory meta0, TokenMetadata memory meta1)
        internal
        pure
        returns (PriceInfo memory info)
    {
        if (sqrtPriceX96 == 0) {
            return PriceInfo({price1Per0E18: 0, price0Per1E18: 0});
        }

        uint256 scale0 = pow10(meta0.decimals);
        uint256 scale1 = pow10(meta1.decimals);

        uint256 numeratorA = uint256(sqrtPriceX96) * scale0;
        uint256 numeratorB = uint256(sqrtPriceX96) * E18;
        uint256 denominator = Q192 * scale1;

        uint256 price1Per0E18 = FullMath.mulDiv(numeratorA, numeratorB, denominator);
        uint256 price0Per1E18 = price1Per0E18 == 0 ? 0 : FullMath.mulDiv(E36, 1, price1Per0E18);

        info = PriceInfo({price1Per0E18: price1Per0E18, price0Per1E18: price0Per1E18});
    }

    function pow10(uint8 exponent) internal pure returns (uint256) {
        if (exponent > 38) revert ExponentTooLarge(exponent);
        uint256 result = 1;
        for (uint8 i = 0; i < exponent; i++) {
            result *= 10;
        }
        return result;
    }

    function amountToString(uint256 amount, uint8 decimals, uint8 precision) internal pure returns (string memory) {
        uint256 scaleDenominator = pow10(decimals);
        uint256 scaled = scaleDenominator == 0 ? 0 : FullMath.mulDiv(amount, E18, scaleDenominator);
        return decimalString(scaled, precision);
    }

    function decimalString(uint256 valueE18, uint8 precision) internal pure returns (string memory) {
        if (precision > 18) {
            precision = 18;
        }

        uint256 factor = 10 ** (18 - precision);
        uint256 integerPart = valueE18 / E18;

        if (precision == 0) {
            return _toString(integerPart);
        }

        uint256 truncated = valueE18 / factor;
        uint256 fractionalPart = truncated % (10 ** precision);

        string memory intStr = _toString(integerPart);
        string memory fracStr = _padFraction(fractionalPart, precision);

        return string(abi.encodePacked(intStr, ".", fracStr));
    }

    function formatPriceLine(TokenMetadata memory base, TokenMetadata memory quote, uint256 priceE18, uint8 precision)
        internal
        pure
        returns (string memory)
    {
        string memory readable = decimalString(priceE18, precision);
        return string(abi.encodePacked("1 ", base.symbol, " = ", readable, " ", quote.symbol));
    }

    function tickToPriceStrings(int24 tick, TokenMetadata memory token0, TokenMetadata memory token1, uint8 precision)
        internal
        pure
        returns (string memory forward, string memory inverse)
    {
        uint160 sqrtPrice = TickMath.getSqrtRatioAtTick(tick);
        PriceInfo memory info = computePrices(sqrtPrice, token0, token1);
        forward = formatPriceLine(token0, token1, info.price1Per0E18, precision);
        inverse = formatPriceLine(token1, token0, info.price0Per1E18, precision);
    }

    function liquidityForAmounts(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) internal pure returns (uint128 liquidity) {
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, amount0Desired, amount1Desired
        );
    }

    function _padFraction(uint256 value, uint8 precision) private pure returns (string memory) {
        bytes memory buffer = new bytes(precision);
        for (uint256 i = precision; i > 0; i--) {
            uint256 digit = value % 10;
            buffer[i - 1] = bytes1(uint8(48 + digit));
            value /= 10;
        }
        return string(buffer);
    }

    function _toString(uint256 value) private pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}

