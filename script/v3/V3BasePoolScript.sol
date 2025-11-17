// SPDX-License-Identifier: MIT
pragma solidity >=0.8.12 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

abstract contract V3BasePoolScript is Script, StdCheats {
    struct Config {
        IUniswapV3Pool pool;
        address token0;
        address token1;
        uint24 fee;
        uint256 broadcasterKey;
    }

    function loadConfig() internal view returns (Config memory cfg) {
        address poolAddress = vm.envAddress("V3_POOL_ADDRESS");
        require(poolAddress != address(0), "V3_POOL_ADDRESS unset");

        cfg.pool = IUniswapV3Pool(poolAddress);
        cfg.token0 = cfg.pool.token0();
        cfg.token1 = cfg.pool.token1();
        cfg.fee = cfg.pool.fee();
        cfg.broadcasterKey = vm.envOr("PRIVATE_KEY", uint256(0));

        return cfg;
    }
}

