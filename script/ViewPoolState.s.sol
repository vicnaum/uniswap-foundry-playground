// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {Script} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {V4PoolReporter} from "./v4/V4PoolReporter.sol";
import {V4PoolIntrospection} from "./v4/V4PoolIntrospection.sol";
import {V4PoolTargetLib} from "./v4/V4PoolTargetLib.sol";

contract ViewPoolStateScript is Script {
    function run(bytes32 poolIdInput) external {
        address poolManagerAddr = vm.envAddress("POOL_MANAGER");
        IPoolManager manager = IPoolManager(poolManagerAddr);

        bytes32 poolId = poolIdInput;
        if (poolId == bytes32(0)) {
            poolId = vm.envBytes32("POOL_ID");
        }
        require(poolId != bytes32(0), "poolId required");

        uint256 fromBlock = vm.envOr("LOG_FROM_BLOCK", uint256(0));
        uint256 defaultToBlock = block.number;
        if (defaultToBlock == 0) {
            defaultToBlock = fromBlock == 0 ? 50_000_000 : fromBlock + 5_000_000;
        }
        uint256 toBlock = vm.envOr("LOG_TO_BLOCK", defaultToBlock);
        if (toBlock == 0) {
            toBlock = defaultToBlock;
        }

        V4PoolIntrospection.PoolData memory data = V4PoolIntrospection.fetch(vm, manager, poolId, fromBlock, toBlock);

        console2.log("Pool Initialize Event:");
        console2.log("  poolId        :");
        console2.logBytes32(poolId);
        console2.log("  currency0     :", data.token0.token);
        console2.log("  currency1     :", data.token1.token);
        console2.log("  fee           :", data.key.fee);
        console2.log("  tickSpacing   :", data.key.tickSpacing);
        console2.log("  hooks         :", address(data.key.hooks));
        console2.log("  init sqrtPriceX96 :", uint256(data.initSqrtPriceX96));
        console2.log("  init tick     :", data.initTick);
        console2.log("  blockNumber   :", data.initBlockNumber);
        console2.log("  transaction   :");
        console2.logBytes32(data.initTransactionHash);

        V4PoolReporter.logTokenInfo("Token0", data.token0);
        V4PoolReporter.logTokenInfo("Token1", data.token1);

        V4PoolReporter.logSnapshot("Current state", data.snapshot, data.priceInfo, data.token0, data.token1, 6);

        V4PoolTargetLib.TargetResult memory result =
            V4PoolTargetLib.promptTargetPrice(vm, data.token0, data.token1, data.snapshot, data.initTick);

        if (result.hasTarget) {
            V4PoolTargetLib.logTarget(result, data.token0, data.token1);
        }
    }
}

