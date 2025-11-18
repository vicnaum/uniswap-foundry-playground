// SPDX-License-Identifier: MIT
pragma solidity >=0.8.12 <0.9.0;

import {console2} from "forge-std/console2.sol";

import {V3BasePoolScript} from "./V3BasePoolScript.sol";
import {V3PoolIntrospection} from "./V3PoolIntrospection.sol";
import {V3PoolTargetLib} from "./V3PoolTargetLib.sol";
import {V3PoolReporter} from "./V3PoolReporter.sol";

contract V3EstimateSwapScript is V3BasePoolScript {
    function run(address poolAddressInput, uint256 priceNum, uint256 priceDen) external {
        require(priceNum > 0 && priceDen > 0, "invalid price");

        address poolAddress = poolAddressInput;
        if (poolAddress == address(0)) {
            poolAddress = vm.envAddress("V3_POOL_ADDRESS");
        }
        require(poolAddress != address(0), "pool address required");

        V3PoolIntrospection.PoolData memory data = V3PoolIntrospection.fetch(vm, poolAddress);

        console2.log("Target price numerator", priceNum);
        console2.log("Target price denominator", priceDen);
        console2.log(string.concat("Token0 symbol: ", data.token0.symbol));
        console2.log(string.concat("Token1 symbol: ", data.token1.symbol));
        V3PoolTargetLib.TargetResult memory target =
            V3PoolTargetLib.targetFromPrice(data.token0, data.token1, data.snapshot, priceNum, priceDen);

        if (!target.hasTarget || target.inputAmount == 0) {
            console2.log("Pool already at target price.");
            return;
        }

        V3PoolTargetLib.logTarget(target, data.token0, data.token1);
    }
}

