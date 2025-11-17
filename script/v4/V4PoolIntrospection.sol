// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {V4PoolUtils} from "src/v4/V4PoolUtils.sol";

library V4PoolIntrospection {
    struct PoolData {
        PoolKey key;
        V4PoolUtils.PoolSnapshot snapshot;
        V4PoolUtils.TokenMetadata token0;
        V4PoolUtils.TokenMetadata token1;
        V4PoolUtils.PriceInfo priceInfo;
        uint160 initSqrtPriceX96;
        int24 initTick;
        uint256 initBlockNumber;
        bytes32 initTransactionHash;
    }

    function fetch(Vm vm, IPoolManager poolManager, bytes32 poolId, uint256 fromBlock, uint256 toBlock)
        internal
        view
        returns (PoolData memory data)
    {
        bytes32 initializeTopic = keccak256("Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)");

        bytes32[] memory topics = new bytes32[](2);
        topics[0] = initializeTopic;
        topics[1] = poolId;

        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(fromBlock, toBlock, address(poolManager), topics);
        require(logs.length > 0, "Initialize event not found");

        Vm.EthGetLogs memory initLog = logs[0];
        for (uint256 i = 1; i < logs.length; i++) {
            if (logs[i].blockNumber < initLog.blockNumber) {
                initLog = logs[i];
            }
        }

        address currency0Addr = address(uint160(uint256(initLog.topics[2])));
        address currency1Addr = address(uint160(uint256(initLog.topics[3])));

        (uint24 fee, int24 tickSpacing, address hooksAddr, uint160 sqrtPriceX96Init, int24 tickInit) =
            abi.decode(initLog.data, (uint24, int24, address, uint160, int24));

        data.key = PoolKey({
            currency0: Currency.wrap(currency0Addr),
            currency1: Currency.wrap(currency1Addr),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooksAddr)
        });

        (
            V4PoolUtils.PoolSnapshot memory snapshot,
            V4PoolUtils.TokenMetadata memory token0Meta,
            V4PoolUtils.TokenMetadata memory token1Meta,
            V4PoolUtils.PriceInfo memory priceInfo
        ) = V4PoolUtils.summarizePool(poolManager, data.key);

        data.snapshot = snapshot;
        data.token0 = token0Meta;
        data.token1 = token1Meta;
        data.priceInfo = priceInfo;
        data.initSqrtPriceX96 = sqrtPriceX96Init;
        data.initTick = tickInit;
        data.initBlockNumber = uint256(initLog.blockNumber);
        data.initTransactionHash = initLog.transactionHash;
    }
}

