// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAeroV2Factory
 * @notice Minimal interface for Aerodrome V2 pool factory.
 *         Aerodrome V2 uses (tokenA, tokenB, stable) to identify pools.
 */
interface IAeroV2Factory {
    /// @notice Return address of pool created by this factory
    function getPool(
        address tokenA,
        address tokenB,
        bool stable
    ) external view returns (address pool);

    /// @notice Is a valid pool created by this factory
    function isPool(address pool) external view returns (bool);
}
