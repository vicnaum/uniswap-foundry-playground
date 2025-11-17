// SPDX-License-Identifier: MIT
pragma solidity >=0.8.12 <0.9.0;

import {console2} from "forge-std/console2.sol";

import {V3PoolUtils} from "src/v3/V3PoolUtils.sol";

library V3PoolReporter {
    function logTokenInfo(string memory label, V3PoolUtils.TokenMetadata memory meta) internal pure {
        console2.log(string.concat(label, " address"), meta.token);
        console2.log(string.concat(label, " symbol"), meta.symbol);
        if (bytes(meta.name).length != 0) {
            console2.log(string.concat(label, " name"), meta.name);
        }
        console2.log(string.concat(label, " decimals"), uint256(meta.decimals));
    }

    function logSnapshot(
        string memory label,
        V3PoolUtils.PoolSnapshot memory snapshot,
        V3PoolUtils.PriceInfo memory price,
        V3PoolUtils.TokenMetadata memory token0,
        V3PoolUtils.TokenMetadata memory token1,
        uint8 precision
    ) internal pure {
        console2.log(string.concat(label, " tick"), snapshot.tick);
        console2.log(string.concat(label, " sqrtPriceX96"), uint256(snapshot.sqrtPriceX96));
        console2.log(string.concat(label, " liquidity"), uint256(snapshot.liquidity));
        console2.log(string.concat(label, " fee"), snapshot.fee);
        console2.log(string.concat(label, " tickSpacing"), snapshot.tickSpacing);
        console2.log(string.concat(label, " pool address"), snapshot.pool);

        console2.log(V3PoolUtils.formatPriceLine(token0, token1, price.price1Per0E18, precision));
        console2.log(V3PoolUtils.formatPriceLine(token1, token0, price.price0Per1E18, precision));
    }
}

