// SPDX-License-Identifier: MIT
pragma solidity >=0.8.12 <0.9.0;

import "forge-std/Test.sol";

import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {UniswapV3Factory} from "@uniswap/v3-core/contracts/UniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3MintCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "insufficient allowance");
        allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

abstract contract V3PoolTestHelper is Test, IUniswapV3MintCallback {
    MockERC20 internal token0;
    MockERC20 internal token1;
    IUniswapV3Factory internal factory;
    IUniswapV3Pool internal pool;

    function _deployV3Pool(uint24 fee, int24 initTick) internal {
        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");

        factory = new UniswapV3Factory();
        address poolAddress = factory.createPool(address(token0), address(token1), fee);
        pool = IUniswapV3Pool(poolAddress);

        if (pool.token0() != address(token0)) {
            (token0, token1) = (token1, token0);
        }

        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(initTick);
        pool.initialize(sqrtPriceX96);
    }

    function _mintLiquidity(int24 tickLower, int24 tickUpper, uint128 liquidityDesired)
        internal
        returns (uint256 amount0Actual, uint256 amount1Actual)
    {
        require(address(pool) != address(0), "pool not deployed");

        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        amount0Actual = LiquidityAmounts.getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidityDesired);
        amount1Actual = LiquidityAmounts.getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidityDesired);

        token0.mint(address(this), amount0Actual);
        token1.mint(address(this), amount1Actual);

        token0.approve(address(pool), amount0Actual);
        token1.approve(address(pool), amount1Actual);

        pool.mint(address(this), tickLower, tickUpper, liquidityDesired, abi.encode(address(token0), address(token1)));

        // If the position straddles the current price, the pool may request different amounts in the callback.
        // Any unused tokens remain on this contract balance, which is acceptable for tests.
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external override {
        require(msg.sender == address(pool), "unauthorised callback");
        if (amount0Owed > 0) {
            token0.transfer(msg.sender, amount0Owed);
        }
        if (amount1Owed > 0) {
            token1.transfer(msg.sender, amount1Owed);
        }
    }
}

