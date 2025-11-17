// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {V4PoolUtils} from "src/v4/V4PoolUtils.sol";

library V4PoolReporter {
    function logTokenInfo(string memory label, V4PoolUtils.TokenMetadata memory meta) internal pure {
        console2.log(string.concat(label, " address"), meta.token);
        console2.log(string.concat(label, " symbol"), meta.symbol);
        if (bytes(meta.name).length != 0) {
            console2.log(string.concat(label, " name"), meta.name);
        }
        console2.log(string.concat(label, " decimals"), uint256(meta.decimals));
    }

    function logSnapshot(
        string memory label,
        V4PoolUtils.PoolSnapshot memory snapshot,
        V4PoolUtils.PriceInfo memory price,
        V4PoolUtils.TokenMetadata memory token0,
        V4PoolUtils.TokenMetadata memory token1,
        uint8 precision
    ) internal pure {
        console2.log(string.concat(label, " tick"), snapshot.tick);
        console2.log(string.concat(label, " sqrtPriceX96"), uint256(snapshot.sqrtPriceX96));
        console2.log(string.concat(label, " liquidity"), uint256(snapshot.liquidity));
        console2.log(string.concat(label, " protocolFee"), snapshot.protocolFee);
        console2.log(string.concat(label, " lpFee"), snapshot.lpFee);
        console2.log(string.concat(label, " poolId (bytes32)"));
        console2.logBytes32(PoolId.unwrap(snapshot.id));

        console2.log(V4PoolUtils.formatPriceLine(token0, token1, price.price1Per0E18, precision));
        console2.log(V4PoolUtils.formatPriceLine(token1, token0, price.price0Per1E18, precision));
    }
}

