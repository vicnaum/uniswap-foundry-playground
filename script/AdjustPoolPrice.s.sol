// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {V4PoolUtils} from "src/v4/V4PoolUtils.sol";
import {V4PoolReporter} from "./v4/V4PoolReporter.sol";
import {V4PoolIntrospection} from "./v4/V4PoolIntrospection.sol";
import {V4PoolTargetLib} from "./v4/V4PoolTargetLib.sol";
import {V4BasePoolScript} from "./v4/V4BasePoolScript.sol";

contract AdjustPoolPriceScript is V4BasePoolScript {
    uint160 private constant PERMIT2_MAX_AMOUNT = type(uint160).max;
    uint48 private constant PERMIT2_MAX_EXPIRATION = type(uint48).max;
    uint256 private constant SLIPPAGE_BASIS = 995_000; // 0.5% buffer on expected output
    uint8 private constant UNIVERSAL_CMD_V4_SWAP = 0x10;

    function run(bytes32 poolIdInput, int24 targetTickInput) external {
        Config memory cfg = loadConfig();
        require(cfg.broadcasterKey != 0, "PRIVATE_KEY unset");

        bytes32 poolId = poolIdInput;
        if (poolId == bytes32(0)) {
            poolId = vm.envBytes32("POOL_ID");
        }
        require(poolId != bytes32(0), "poolId required");
        require(targetTickInput != type(int24).min, "target tick required");

        uint256 fromBlock = vm.envOr("LOG_FROM_BLOCK", uint256(0));
        uint256 defaultToBlock = block.number;
        if (defaultToBlock == 0) {
            defaultToBlock = fromBlock == 0 ? 50_000_000 : fromBlock + 5_000_000;
        }
        uint256 toBlock = vm.envOr("LOG_TO_BLOCK", defaultToBlock);
        if (toBlock == 0) {
            toBlock = defaultToBlock;
        }

        V4PoolIntrospection.PoolData memory data =
            V4PoolIntrospection.fetch(vm, cfg.poolManager, poolId, fromBlock, toBlock);

        cfg.tokenA = data.token0.token;
        cfg.tokenB = data.token1.token;
        cfg.lpFee = data.key.fee;
        cfg.tickSpacing = data.key.tickSpacing;
        cfg.hook = address(data.key.hooks);

        V4PoolReporter.logTokenInfo("Token0", data.token0);
        V4PoolReporter.logTokenInfo("Token1", data.token1);
        V4PoolReporter.logSnapshot("Before swap", data.snapshot, data.priceInfo, data.token0, data.token1, 6);

        V4PoolTargetLib.TargetResult memory target = V4PoolTargetLib.targetFromTick(data.snapshot, targetTickInput);
        V4PoolTargetLib.logTarget(target, data.token0, data.token1);

        if (target.inputAmount == 0) {
            console2.log("Target already met - no swap required.");
            return;
        }

        bool dryRun = vm.envOr("DRY_RUN", false);

        V4PoolUtils.TokenMetadata memory inputMeta = target.zeroForOne ? data.token0 : data.token1;
        V4PoolUtils.TokenMetadata memory outputMeta = target.zeroForOne ? data.token1 : data.token0;
        PoolKey memory key = data.key;
        Currency inputCurrency = target.zeroForOne ? key.currency0 : key.currency1;
        address owner = vm.addr(cfg.broadcasterKey);

        uint256 amountInWithFee = target.inputAmount;
        if (cfg.lpFee > 0) {
            amountInWithFee = FullMath.mulDiv(target.inputAmount, 1_000_000 + cfg.lpFee, 1_000_000);
            if (amountInWithFee <= target.inputAmount) {
                amountInWithFee = target.inputAmount + 1;
            }
        }

        uint256 availableBalance = _balanceOf(owner, inputCurrency);
        bool simulatedTopUpApplied = false;
        uint256 simulatedBalance = availableBalance;
        if (availableBalance < amountInWithFee) {
            uint256 deficit = amountInWithFee - availableBalance;
            string memory shortfallHuman = V4PoolUtils.amountToString(deficit, inputMeta.decimals, 6);

            console2.log("----------------------------------------------");
            console2.log("Insufficient input token balance detected.");
            console2.log(string(abi.encodePacked(" Wallet   : ", vm.toString(owner))));
            console2.log(
                string(
                    abi.encodePacked(
                        " Missing  : ", vm.toString(deficit), " (", shortfallHuman, " ", inputMeta.symbol, ")"
                    )
                )
            );
            console2.log("----------------------------------------------");

            if (!dryRun) {
                console2.log("Dry run disabled - please fund the wallet before broadcasting.");
                return;
            }

            // Auto-top-up for simulation / testing convenience.
            uint256 toppedBalance;
            if (Currency.unwrap(inputCurrency) == address(0)) {
                toppedBalance = owner.balance + deficit;
                vm.deal(owner, toppedBalance);
            } else {
                toppedBalance = IERC20(Currency.unwrap(inputCurrency)).balanceOf(owner) + deficit;
                deal(Currency.unwrap(inputCurrency), owner, toppedBalance);
            }

            availableBalance = _balanceOf(owner, inputCurrency);
            if (availableBalance < amountInWithFee) {
                console2.log("Unable to top up automatically. Please fund the wallet manually.");
                return;
            }
            simulatedBalance = availableBalance;
            simulatedTopUpApplied = true;
            console2.log(
                string(
                    abi.encodePacked(
                        "Wallet topped up to ",
                        vm.toString(availableBalance),
                        " (",
                        V4PoolUtils.amountToString(availableBalance, inputMeta.decimals, 6),
                        " ",
                        inputMeta.symbol,
                        ") for simulation."
                    )
                )
            );
        }

        uint128 amountIn = toUint128(amountInWithFee);
        uint128 amountOutMin = target.outputAmount == 0
            ? uint128(0)
            : toUint128(FullMath.mulDiv(target.outputAmount, SLIPPAGE_BASIS, 1_000_000));

        console2.log("Buffered input (raw)     :", amountIn);
        if (target.zeroForOne) {
            console2.log(
                string(
                    abi.encodePacked(
                        "Buffered input (~)      : ",
                        V4PoolUtils.amountToString(amountIn, inputMeta.decimals, 6),
                        " ",
                        inputMeta.symbol
                    )
                )
            );
        } else {
            console2.log(
                string(
                    abi.encodePacked(
                        "Buffered input (~)      : ",
                        V4PoolUtils.amountToString(amountIn, inputMeta.decimals, 6),
                        " ",
                        inputMeta.symbol
                    )
                )
            );
        }

        console2.log("Min amount out (raw)     :", amountOutMin);
        console2.log(
            string(
                abi.encodePacked(
                    "Min amount out (~)      : ",
                    V4PoolUtils.amountToString(amountOutMin, outputMeta.decimals, 6),
                    " ",
                    outputMeta.symbol
                )
            )
        );

        cfg.targetTick = target.targetTick;
        cfg.amountIn = amountIn;
        cfg.minAmountOut = amountOutMin;

        vm.startBroadcast(cfg.broadcasterKey);

        if (dryRun && simulatedTopUpApplied) {
            if (Currency.unwrap(inputCurrency) == address(0)) {
                vm.deal(owner, simulatedBalance);
            } else {
                deal(Currency.unwrap(inputCurrency), owner, simulatedBalance);
            }
            console2.log(
                string(
                    abi.encodePacked(
                        "Simulated balance applied for dry run: ",
                        vm.toString(simulatedBalance),
                        " (",
                        V4PoolUtils.amountToString(simulatedBalance, inputMeta.decimals, 6),
                        " ",
                        inputMeta.symbol,
                        ")"
                    )
                )
            );
        }

        if (!cfg.skipPermit2Approval) {
            approveIfNeeded(cfg, inputCurrency, amountInWithFee);
        }

        executeSwap(cfg, key, target.zeroForOne, amountIn, amountOutMin);

        (
            V4PoolUtils.PoolSnapshot memory finalSnapshot,
            V4PoolUtils.TokenMetadata memory token0Meta,
            V4PoolUtils.TokenMetadata memory token1Meta,
            V4PoolUtils.PriceInfo memory finalPriceInfo
        ) = V4PoolUtils.summarizePool(cfg.poolManager, key);

        V4PoolReporter.logSnapshot("After swap", finalSnapshot, finalPriceInfo, token0Meta, token1Meta, 6);

        vm.stopBroadcast();

        if (dryRun) {
            console2.log("Dry run complete - no on-chain broadcast.");
        }
    }

    function approveIfNeeded(Config memory cfg, Currency currency, uint256 requiredAmount) internal {
        address token = Currency.unwrap(currency);
        if (token == address(0)) {
            return;
        }

        IERC20 erc20 = IERC20(token);
        address owner = vm.addr(cfg.broadcasterKey);
        if (erc20.allowance(owner, address(cfg.permit2)) < requiredAmount) {
            erc20.approve(address(cfg.permit2), type(uint256).max);
        }

        cfg.permit2.approve(token, address(cfg.router), PERMIT2_MAX_AMOUNT, PERMIT2_MAX_EXPIRATION);
    }

    function executeSwap(
        Config memory cfg,
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMinimum
    ) internal {
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;

        bytes memory subActions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes[] memory subParams = new bytes[](3);
        subParams[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum,
                hookData: cfg.hookData
            })
        );

        subParams[1] = abi.encode(inputCurrency, uint256(amountIn));
        subParams[2] = abi.encode(outputCurrency, uint256(amountOutMinimum));

        bytes memory commands = abi.encodePacked(UNIVERSAL_CMD_V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(subActions, subParams);

        uint256 deadline = block.timestamp + cfg.deadlineBufferSeconds;
        uint256 valueToSend = Currency.unwrap(inputCurrency) == address(0) ? amountIn : 0;
        cfg.router.execute{value: valueToSend}(commands, inputs, deadline);
    }

    function _balanceOf(address owner, Currency currency) private view returns (uint256) {
        address token = Currency.unwrap(currency);
        if (token == address(0)) {
            return owner.balance;
        }
        return IERC20(token).balanceOf(owner);
    }
}

