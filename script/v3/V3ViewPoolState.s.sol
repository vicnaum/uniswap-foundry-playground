// SPDX-License-Identifier: MIT
pragma solidity >=0.8.12 <0.9.0;

import {console2} from "forge-std/console2.sol";

import {V3BasePoolScript} from "./V3BasePoolScript.sol";
import {V3PoolIntrospection} from "./V3PoolIntrospection.sol";
import {V3PoolReporter} from "./V3PoolReporter.sol";
import {V3PoolTargetLib} from "./V3PoolTargetLib.sol";
import {V3PoolUtils} from "src/v3/V3PoolUtils.sol";

contract V3ViewPoolStateScript is V3BasePoolScript {
    function run(address poolAddressInput) external {
        address poolAddress = poolAddressInput;
        if (poolAddress == address(0)) {
            poolAddress = vm.envAddress("V3_POOL_ADDRESS");
        }
        require(poolAddress != address(0), "pool address required");

        V3PoolIntrospection.PoolData memory data = V3PoolIntrospection.fetch(vm, poolAddress);

        console2.log("Uniswap V3 Pool:");
        console2.log("  address     :", poolAddress);
        console2.log("  fee         :", data.snapshot.fee);
        console2.log("  tick spacing:", data.snapshot.tickSpacing);
        console2.log("  liquidity   :", uint256(data.snapshot.liquidity));
        console2.log("  sqrtPriceX96:", uint256(data.snapshot.sqrtPriceX96));
        console2.log("  current tick:", data.snapshot.tick);

        V3PoolReporter.logTokenInfo("Token0", data.token0);
        V3PoolReporter.logTokenInfo("Token1", data.token1);
        V3PoolReporter.logSnapshot("Current state", data.snapshot, data.priceInfo, data.token0, data.token1, 6);

        V3PoolTargetLib.TargetResult memory target =
            V3PoolTargetLib.promptTargetPrice(vm, data.token0, data.token1, data.snapshot, data.snapshot.tick);
        if (target.hasTarget) {
            V3PoolTargetLib.logTarget(target, data.token0, data.token1);
        }
    }
}

