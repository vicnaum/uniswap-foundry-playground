// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

using PoolIdLibrary for PoolKey;
using CurrencyLibrary for Currency;
using StateLibrary for IPoolManager;

library V4PoolUtils {
    error ExponentTooLarge(uint8 exponent);

    uint256 private constant Q192 = 2 ** 192;
    uint256 private constant E18 = 1e18;
    uint256 private constant E36 = 1e36;

    struct TokenMetadata {
        address token;
        string symbol;
        string name;
        uint8 decimals;
    }

    struct PoolSnapshot {
        PoolId id;
        uint160 sqrtPriceX96;
        int24 tick;
        uint24 protocolFee;
        uint24 lpFee;
        uint128 liquidity;
    }

    struct PriceInfo {
        uint256 price1Per0E18;
        uint256 price0Per1E18;
    }

    function fetchSnapshot(IPoolManager manager, PoolKey memory key) internal view returns (PoolSnapshot memory snap) {
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(poolId);
        uint128 liquidity = manager.getLiquidity(poolId);

        snap = PoolSnapshot({
            id: poolId,
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            protocolFee: protocolFee,
            lpFee: lpFee,
            liquidity: liquidity
        });
    }

    function fetchTokenMetadata(Currency currency) internal view returns (TokenMetadata memory meta) {
        address token = Currency.unwrap(currency);
        if (token == address(0)) {
            meta = TokenMetadata({token: token, symbol: "ETH", name: "Ether", decimals: 18});
            return meta;
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

    function decimalString(uint256 valueE18, uint8 precision) internal pure returns (string memory) {
        if (precision > 18) {
            precision = 18;
        }

        uint256 factor = 10 ** (18 - precision);
        uint256 integerPart = valueE18 / E18;
        uint256 truncated = valueE18 / factor;
        uint256 fractionalPart = truncated % (10 ** precision);

        string memory intStr = Strings.toString(integerPart);
        string memory fracStr = padFraction(fractionalPart, precision);

        return string(abi.encodePacked(intStr, ".", fracStr));
    }

    function padFraction(uint256 value, uint8 precision) internal pure returns (string memory) {
        bytes memory buffer = new bytes(precision);
        for (uint256 i = precision; i > 0; i--) {
            uint256 digit = value % 10;
            buffer[i - 1] = bytes1(uint8(48 + digit));
            value /= 10;
        }
        return string(buffer);
    }

    function amountToString(uint256 amount, uint8 decimals, uint8 precision) internal pure returns (string memory) {
        uint256 scaleDenominator = pow10(decimals);
        uint256 scaled = scaleDenominator == 0 ? 0 : FullMath.mulDiv(amount, E18, scaleDenominator);
        return decimalString(scaled, precision);
    }

    function formatPriceLine(TokenMetadata memory base, TokenMetadata memory quote, uint256 priceE18, uint8 precision)
        internal
        pure
        returns (string memory)
    {
        string memory readable = decimalString(priceE18, precision);
        return string(abi.encodePacked("1 ", base.symbol, " = ", readable, " ", quote.symbol));
    }

    function summarizePool(IPoolManager manager, PoolKey memory key)
        internal
        view
        returns (
            PoolSnapshot memory snapshot,
            TokenMetadata memory token0,
            TokenMetadata memory token1,
            PriceInfo memory priceInfo
        )
    {
        snapshot = fetchSnapshot(manager, key);
        token0 = fetchTokenMetadata(key.currency0);
        token1 = fetchTokenMetadata(key.currency1);
        priceInfo = computePrices(snapshot.sqrtPriceX96, token0, token1);
    }

    function tickToPriceStrings(int24 tick, TokenMetadata memory token0, TokenMetadata memory token1, uint8 precision)
        internal
        pure
        returns (string memory forward, string memory inverse)
    {
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);
        PriceInfo memory info = computePrices(sqrtPrice, token0, token1);
        forward = formatPriceLine(token0, token1, info.price1Per0E18, precision);
        inverse = formatPriceLine(token1, token0, info.price0Per1E18, precision);
    }
}

