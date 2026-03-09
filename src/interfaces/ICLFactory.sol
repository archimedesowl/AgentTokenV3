// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ICLFactory
 * @notice Minimal interface for concentrated liquidity pool factories.
 *         Works with both Uniswap V3 Factory and Aerodrome Slipstream CLFactory.
 *
 * Uniswap V3: getPool(tokenA, tokenB, fee) where fee is uint24 (e.g. 500, 3000, 10000)
 * Slipstream: getPool(tokenA, tokenB, tickSpacing) where tickSpacing is int24
 *
 * We use separate lookup functions for each because the parameter types differ.
 */
interface ICLFactory {
    /// @notice Uniswap V3 style: lookup pool by fee tier (uint24)
    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external view returns (address pool);
}

interface ISlipstreamCLFactory {
    /// @notice Aerodrome Slipstream style: lookup pool by tick spacing (int24)
    function getPool(
        address tokenA,
        address tokenB,
        int24 tickSpacing
    ) external view returns (address pool);
}
