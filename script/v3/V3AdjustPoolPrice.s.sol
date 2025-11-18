// SPDX-License-Identifier: MIT
pragma solidity >=0.8.12 <0.9.0;

import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";

import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import {V3PoolIntrospection} from "./V3PoolIntrospection.sol";
import {V3PoolReporter} from "./V3PoolReporter.sol";
import {V3PoolTargetLib} from "./V3PoolTargetLib.sol";
import {V3BasePoolScript} from "./V3BasePoolScript.sol";
import {V3PoolUtils} from "src/v3/V3PoolUtils.sol";

contract V3AdjustPoolPriceScript is V3BasePoolScript {
    uint256 private constant SLIPPAGE_BASIS = 995_000; // 0.5% buffer

    function run(address poolAddressInput, int24 targetTickInput) external {
        require(targetTickInput != type(int24).min, "target tick required");

        Config memory cfg = loadConfig(poolAddressInput);
        require(cfg.broadcasterKey != 0, "PRIVATE_KEY unset");

        V3PoolUtils.PoolSnapshot memory snapshot;
        V3PoolUtils.TokenMetadata memory token0Meta;
        V3PoolUtils.TokenMetadata memory token1Meta;
        V3PoolUtils.PriceInfo memory priceInfo;
        {
            V3PoolIntrospection.PoolData memory data = V3PoolIntrospection.fetch(vm, address(cfg.pool));
            snapshot = data.snapshot;
            token0Meta = data.token0;
            token1Meta = data.token1;
            priceInfo = data.priceInfo;
            V3PoolReporter.logTokenInfo("Token0", token0Meta);
            V3PoolReporter.logTokenInfo("Token1", token1Meta);
            V3PoolReporter.logSnapshot("Before swap", snapshot, priceInfo, token0Meta, token1Meta, 6);
        }

        V3PoolTargetLib.TargetResult memory target = V3PoolTargetLib.targetFromTick(snapshot, targetTickInput);
        V3PoolTargetLib.logTarget(target, token0Meta, token1Meta);

        if (!target.hasTarget || target.inputAmount == 0) {
            console2.log("Target already met - no swap required.");
            return;
        }

        bool dryRun = vm.envOr("DRY_RUN", false);
        address owner = vm.addr(cfg.broadcasterKey);

        bool zeroForOne = target.zeroForOne;
        address tokenIn = zeroForOne ? cfg.token0 : cfg.token1;
        address tokenOut = zeroForOne ? cfg.token1 : cfg.token0;

        V3PoolUtils.TokenMetadata memory inputMeta = zeroForOne ? token0Meta : token1Meta;
        uint256 amountInWithFee = target.inputAmount;
        if (cfg.fee > 0) {
            amountInWithFee = FullMath.mulDiv(target.inputAmount, 1_000_000 + cfg.fee, 1_000_000);
            if (amountInWithFee <= target.inputAmount) {
                amountInWithFee = target.inputAmount + 1;
            }
        }

        (uint256 availableBalance, uint256 simulatedBalance, bool simulatedTopUpApplied) =
            _ensureBalance(tokenIn, inputMeta, amountInWithFee, owner, dryRun);
        if (availableBalance < amountInWithFee && !dryRun) {
            return;
        }

        uint256 minAmountOut = 0;

        vm.startBroadcast(cfg.broadcasterKey);

        if (dryRun && simulatedTopUpApplied) {
            _applySimulatedBalance(tokenIn, owner, simulatedBalance);
        }

        _approveIfNeeded(tokenIn, owner, cfg.routerAddress, amountInWithFee);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: cfg.fee,
            recipient: owner,
            deadline: block.timestamp + cfg.deadlineBufferSeconds,
            amountIn: amountInWithFee,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = cfg.router.exactInputSingle{value: tokenIn == address(0) ? amountInWithFee : 0}(params);

        (
            V3PoolUtils.PoolSnapshot memory finalSnapshot,
            V3PoolUtils.TokenMetadata memory finalToken0,
            V3PoolUtils.TokenMetadata memory finalToken1,
            V3PoolUtils.PriceInfo memory finalPriceInfo
        ) = V3PoolUtils.summarizePool(cfg.pool);

        V3PoolReporter.logSnapshot("After swap", finalSnapshot, finalPriceInfo, finalToken0, finalToken1, 6);
        console2.log("Router reported output (raw):", amountOut);

        vm.stopBroadcast();

        if (dryRun) {
            console2.log("Dry run complete - no on-chain broadcast.");
        }
    }

    function _approveIfNeeded(address token, address owner, address spender, uint256 requiredAmount) internal {
        if (token == address(0)) {
            return;
        }
        IERC20 erc20 = IERC20(token);
        if (erc20.allowance(owner, spender) < requiredAmount) {
            erc20.approve(spender, type(uint256).max);
        }
    }

    function _balanceOf(address token, address owner) internal view returns (uint256) {
        if (token == address(0)) {
            return owner.balance;
        }
        return IERC20(token).balanceOf(owner);
    }

    function _ensureBalance(
        address tokenIn,
        V3PoolUtils.TokenMetadata memory inputMeta,
        uint256 requiredAmount,
        address owner,
        bool dryRun
    ) internal returns (uint256 availableBalance, uint256 simulatedBalance, bool simulatedTopUpApplied) {
        availableBalance = _balanceOf(tokenIn, owner);
        simulatedBalance = availableBalance;

        if (availableBalance >= requiredAmount) {
            return (availableBalance, simulatedBalance, false);
        }

        uint256 deficit = requiredAmount - availableBalance;
        console2.log("----------------------------------------------");
        console2.log("Insufficient input token balance detected.");
        console2.log("Wallet   :", owner);
        console2.log("Missing (raw) :", deficit);
        console2.log("Missing (~)   :", V3PoolUtils.amountToString(deficit, inputMeta.decimals, 6));
        console2.log("----------------------------------------------");

        if (!dryRun) {
            console2.log("Dry run disabled - please fund the wallet before broadcasting.");
            return (availableBalance, simulatedBalance, false);
        }

        uint256 toppedBalance = availableBalance + deficit;
        if (tokenIn == address(0)) {
            vm.deal(owner, toppedBalance);
        } else {
            deal(tokenIn, owner, toppedBalance);
        }

        simulatedBalance = toppedBalance;
        simulatedTopUpApplied = true;
        availableBalance = _balanceOf(tokenIn, owner);
        console2.log("Wallet topped up (raw):", availableBalance);

        return (availableBalance, simulatedBalance, simulatedTopUpApplied);
    }

    function _applySimulatedBalance(address tokenIn, address owner, uint256 simulatedBalance) internal {
        if (tokenIn == address(0)) {
            vm.deal(owner, simulatedBalance);
        } else {
            deal(tokenIn, owner, simulatedBalance);
        }
        console2.log("Simulated balance applied (raw):", simulatedBalance);
    }
}

