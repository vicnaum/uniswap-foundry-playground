// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

import {UniversalRouter} from "@uniswap/universal-router/contracts/UniversalRouter.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

abstract contract V4BasePoolScript is Script, StdCheats {
    using CurrencyLibrary for Currency;

    address internal constant DEFAULT_UNIVERSAL_ROUTER = 0xEf1c6E67703c7BD7107eed8303Fbe6EC2554BF6B;
    address internal constant DEFAULT_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    struct Config {
        UniversalRouter router;
        IPoolManager poolManager;
        IPermit2 permit2;
        address tokenA;
        address tokenB;
        address hook;
        uint24 lpFee;
        int24 tickSpacing;
        int24 targetTick;
        uint128 amountIn;
        uint128 minAmountOut;
        uint256 deadlineBufferSeconds;
        uint256 broadcasterKey;
        bytes hookData;
        bool skipPermit2Approval;
    }

    function loadConfig() internal view returns (Config memory cfg) {
        cfg.router = UniversalRouter(payable(vm.envOr("UNIVERSAL_ROUTER", DEFAULT_UNIVERSAL_ROUTER)));
        cfg.poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        cfg.permit2 = IPermit2(vm.envOr("PERMIT2", DEFAULT_PERMIT2));

        cfg.tokenA = address(0);
        cfg.tokenB = address(0);
        cfg.hook = address(0);
        cfg.lpFee = 0;
        cfg.tickSpacing = 0;
        cfg.targetTick = type(int24).min;
        cfg.amountIn = 0;
        cfg.minAmountOut = 0;
        cfg.deadlineBufferSeconds = vm.envOr("DEADLINE_BUFFER_SECONDS", uint256(300));
        cfg.broadcasterKey = vm.envOr("PRIVATE_KEY", uint256(0));
        cfg.skipPermit2Approval = vm.envOr("SKIP_PERMIT2_APPROVAL", false);
        cfg.hookData = vm.envOr("HOOK_DATA", bytes(""));

        require(address(cfg.poolManager) != address(0), "POOL_MANAGER unset");

        return cfg;
    }

    function buildPoolKey(Config memory cfg) internal pure returns (PoolKey memory key) {
        Currency currencyA = Currency.wrap(cfg.tokenA);
        Currency currencyB = Currency.wrap(cfg.tokenB);

        (Currency currency0, Currency currency1) =
            Currency.unwrap(currencyA) < Currency.unwrap(currencyB) ? (currencyA, currencyB) : (currencyB, currencyA);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: cfg.lpFee,
            tickSpacing: cfg.tickSpacing,
            hooks: IHooks(cfg.hook)
        });
    }

    function toUint24(uint256 value) internal pure returns (uint24) {
        require(value <= type(uint24).max, "uint24 overflow");
        return uint24(value);
    }

    function toUint128(uint256 value) internal pure returns (uint128) {
        require(value <= type(uint128).max, "uint128 overflow");
        return uint128(value);
    }

    function toInt24(int256 value) internal pure returns (int24) {
        require(value >= type(int24).min && value <= type(int24).max, "int24 overflow");
        return int24(value);
    }
}

