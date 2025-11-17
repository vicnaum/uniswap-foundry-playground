// SPDX-License-Identifier: MIT
pragma solidity >=0.8.12 <0.9.0;

import {Vm} from "forge-std/Vm.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {V3PoolUtils} from "src/v3/V3PoolUtils.sol";

library V3PoolIntrospection {
    struct PoolData {
        IUniswapV3Pool pool;
        V3PoolUtils.PoolSnapshot snapshot;
        V3PoolUtils.TokenMetadata token0;
        V3PoolUtils.TokenMetadata token1;
        V3PoolUtils.PriceInfo priceInfo;
    }

    function fetch(Vm, address poolAddress) internal view returns (PoolData memory data) {
        require(poolAddress != address(0), "pool address required");
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);

        (
            V3PoolUtils.PoolSnapshot memory snapshot,
            V3PoolUtils.TokenMetadata memory token0Meta,
            V3PoolUtils.TokenMetadata memory token1Meta,
            V3PoolUtils.PriceInfo memory priceInfo
        ) = V3PoolUtils.summarizePool(pool);

        data = PoolData({pool: pool, snapshot: snapshot, token0: token0Meta, token1: token1Meta, priceInfo: priceInfo});
    }
}

