# AgentTokenV3

**Tax-on-Transfer Compatibility Module for Concentrated Liquidity Pools**

Drop-in upgrade for [Virtuals Protocol](https://app.virtuals.io/) AgentToken that enables native support for Uniswap V3, Aerodrome Slipstream, and any concentrated liquidity (CL) DEX — without wrapping, without a Zapper, and without breaking existing V2 pools.

> **Status**: All 88 tests passing (48 unit + 22 auto-detect unit + 10 fork + 8 auto-detect fork)

---

## Table of Contents

- [The Problem](#the-problem)
- [The Solution: Dual-Mode Tax](#the-solution-dual-mode-tax)
- [Architecture Overview](#architecture-overview)
- [What Changed from V2](#what-changed-from-v2)
- [Storage Layout (Proxy Safe)](#storage-layout-proxy-safe)
- [Auto-Detection: How It Works](#auto-detection-how-it-works)
- [New V3 Functions Reference](#new-v3-functions-reference)
- [Upgrade Guide for Virtuals Team](#upgrade-guide-for-virtuals-team)
- [Deployment Checklist](#deployment-checklist)
- [Factory Registration (Post-Deploy)](#factory-registration-post-deploy)
- [Build & Test](#build--test)
- [Gas Impact](#gas-impact)
- [File Structure](#file-structure)
- [Key Addresses (Base Mainnet)](#key-addresses-base-mainnet)
- [Dependencies](#dependencies)
- [Security Considerations](#security-considerations)

---

## The Problem

Concentrated Liquidity (CL) pools — Uniswap V3, Aerodrome Slipstream — enforce a strict balance invariant on every swap callback:

```
balanceBefore + expectedAmount <= balanceAfter
```

The current AgentToken (V1/V2) applies tax by **skimming from the delivered amount**: if you sell 100 tokens with 1% tax, the pool only receives 99. CL pools see `99 < 100` and **revert with `IIA` (Insufficient Input Amount)**.

This means Virtuals agent tokens **cannot trade on any CL pool** — only legacy V2 AMMs.

**Impact**: Agent tokens are locked out of Uniswap V3 and Aerodrome Slipstream, which together represent the majority of Base chain liquidity.

---

## The Solution: Dual-Mode Tax

AgentTokenV3 introduces a **dual-mode tax** that adapts its behavior based on which type of pool is involved:

### Sell-Side (Token → Pool)

| Pool Type | How Tax Is Applied | What Pool Receives | What Sender Pays |
|---|---|---|---|
| **V2 (AMM)** | Tax deducted from delivered amount | `amount - tax` | `amount` |
| **CL (V3/Slipstream)** | Tax debited from sender's remaining balance **separately** | `amount` (full) | `amount + tax` |

### Buy-Side (Pool → Token)

Buy tax is **identical for both pool types** — tax is deducted from what the buyer receives. CL pools don't verify what the recipient gets, so this works as-is.

### The "Debit-from-Sender" Mechanism (CL Sells)

```
Sender balance:  1000 tokens
Sell amount:      100 tokens
Tax (1%):           1 token

V2 (original):
  _balances[sender] -= 100          → sender has 900
  _balances[pool]   += 99           → pool gets 99 (tax deducted)
  _balances[contract] += 1          → contract holds tax
  ❌ CL pool sees 99 < 100 → REVERT

V3 CL mode:
  _balances[sender] -= 101          → sender pays amount + tax
  _balances[pool]   += 100          → pool gets full 100
  _balances[contract] += 1          → contract holds tax
  ✅ CL pool sees 100 >= 100 → SUCCESS
```

The pool always receives exactly what it expects. The tax burden shifts to the sender's remaining balance instead of the transfer amount.

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                       AgentTokenV3                                │
│                                                                   │
│  transfer() / transferFrom()                                      │
│       │                                                           │
│       ▼                                                           │
│  _isOrDetectPool(from) || _isOrDetectPool(to)                     │
│       │                                                           │
│       ├── Already in _liquidityPools set? → YES → applyTax=true   │
│       │                                                           │
│       ├── In _checkedNonPool cache? → YES → applyTax=false        │
│       │                                                           │
│       └── Unknown? → _autoDetectAndRegister()                     │
│              │                                                    │
│              ├── Probe CL factories (UniV3, Slipstream)           │
│              │    → Match? → Add to _liquidityPools + _clPools    │
│              │                                                    │
│              ├── Probe V2 factories (Aerodrome V2)                │
│              │    → Match? → Add to _liquidityPools only          │
│              │                                                    │
│              └── No match → Cache in _checkedNonPool              │
│                                                                   │
│  _transfer(from, to, amount, applyTax)                            │
│       │                                                           │
│       ├── Is CL pool sell? → Debit-from-sender model              │
│       │     sender pays (amount + tax)                            │
│       │     pool receives (amount)                                │
│       │                                                           │
│       └── Everything else → Original V2 model                     │
│             pool receives (amount - tax)                          │
└──────────────────────────────────────────────────────────────────┘
```

---

## What Changed from V2

This is a **minimal, surgical upgrade**. Every line of V2 logic is preserved. Only new code was added.

### New Storage Variables (appended after V2 storage)

| Variable | Type | Purpose |
|---|---|---|
| `_clPools` | `EnumerableSet.AddressSet` | Tracks which pools use the CL tax model |
| `_clFactories` | `CLFactoryEntry[]` | Registry of CL factory addresses for auto-detection |
| `_v2Factories` | `V2FactoryEntry[]` | Registry of V2 factory addresses for auto-detection |
| `_checkedNonPool` | `mapping(address => bool)` | Cache of addresses confirmed as non-pools |

### New Interfaces Added

| File | Purpose |
|---|---|
| `ICLFactory.sol` | `getPool(tokenA, tokenB, uint24 fee)` — Uniswap V3 factory lookup |
| `ISlipstreamCLFactory` | `getPool(tokenA, tokenB, int24 tickSpacing)` — Aerodrome Slipstream factory lookup |
| `IAeroV2Factory.sol` | `getPool(tokenA, tokenB, bool stable)` — Aerodrome V2 factory lookup |

### Modified Functions (2 functions, minimal changes)

| Function | Change |
|---|---|
| `transfer()` | Calls `_isOrDetectPool()` instead of `isLiquidityPool()` for the `applyTax` flag |
| `transferFrom()` | Same — calls `_isOrDetectPool()` instead of `isLiquidityPool()` |

### Modified Internal Logic (2 functions)

| Function | Change |
|---|---|
| `_transfer()` | Added CL sell branch: if destination is a CL pool, use debit-from-sender model |
| `_taxProcessing()` | Added `!isCLPool(to_)` guard so CL sells are not double-taxed (they are handled in `_transfer` directly) |

### Functions NOT Changed

Every other function in V2 is **byte-for-byte identical**: `initialize`, `addInitialLiquidity`, `_autoSwap`, `_swapTax`, `_eligibleForSwap`, `_mint`, `_burn`, `_approve`, `_spendAllowance`, `distributeTaxTokens`, `withdrawETH`, `withdrawERC20`, `_beforeTokenTransfer`, `_afterTokenTransfer`, all view functions, all admin functions.

---

## Storage Layout (Proxy Safe)

AgentTokenV3 is designed for **UUPS/Transparent proxy upgrade**. Storage is strictly append-only.

```
Slot Range    │ Source     │ Variables
──────────────┼────────────┼──────────────────────────────────────────
0             │ V1         │ uniswapV2Pair
1             │ V1         │ botProtectionDurationInSeconds
2             │ V1         │ _tokenHasTax (bool, packed)
3             │ V1         │ _uniswapRouter
4             │ V1         │ fundedDate, projectBuyTaxBasisPoints,
              │            │ projectSellTaxBasisPoints, swapThresholdBasisPoints,
              │            │ pairToken (packed)
5             │ V1         │ _autoSwapInProgress
6             │ V1         │ projectTaxRecipient
7             │ V1         │ projectTaxPendingSwap, vault (packed)
8             │ V1         │ _name
9             │ V1         │ _symbol
10            │ V1         │ _totalSupply
11            │ V1         │ _balances (mapping)
12            │ V1         │ _allowances (mapping)
13            │ V1         │ _validCallerCodeHashes (EnumerableSet)
14-15         │ V1         │ _liquidityPools (EnumerableSet)
16            │ V1         │ _factory
──────────────┼────────────┼──────────────────────────────────────────
17            │ V2         │ blacklists (mapping)
──────────────┼────────────┼──────────────────────────────────────────
18-19         │ V3 (NEW)   │ _clPools (EnumerableSet)
20            │ V3 (NEW)   │ _clFactories (CLFactoryEntry[])
21            │ V3 (NEW)   │ _v2Factories (V2FactoryEntry[])
22            │ V3 (NEW)   │ _checkedNonPool (mapping)
```

**Important**: No V1 or V2 storage slots are modified. New V3 storage is appended at the end. This ensures all existing proxy state (balances, allowances, LP pools, tax config, blacklists) survives the upgrade intact.

---

## Auto-Detection: How It Works

Instead of requiring manual `addCLPool()` calls every time a new pool is created, AgentTokenV3 can **automatically detect** pools at transfer time.

### The Flow

1. **Admin registers factory addresses** (one-time setup):
   ```solidity
   // Register Uniswap V3 Factory with its fee tiers
   token.addUniV3Factory(
       0x33128a8fC17869897dcE68Ed026d694621f6FDfD,  // UniV3 Factory on Base
       [100, 500, 3000, 10000]                       // Standard fee tiers
   );

   // Register Aerodrome Slipstream CLFactory with tick spacings
   token.addSlipstreamFactory(
       0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A,  // Slipstream CLFactory on Base
       [1, 50, 100, 200]                              // Common tick spacings
   );

   // Register Aerodrome V2 PoolFactory
   token.addV2Factory(
       0x420DD381b31aEf6683db6B902084cB0FFECe40Da   // Aero V2 PoolFactory on Base
   );
   ```

2. **When a transfer targets an unknown address**:
   - `transfer()`/`transferFrom()` calls `_isOrDetectPool(address)`
   - If the address is already registered → fast return
   - If the address is in the non-pool cache → fast return (no external calls)
   - Otherwise → `_autoDetectAndRegister()` probes each factory:
     - CL factories: calls `factory.getPool(token, pairToken, feeOrSpacing)` for every fee tier / tick spacing
     - V2 factories: calls `factory.getPool(token, pairToken, stable)` for both `true` and `false`
   - If any factory returns a match → pool is auto-registered (CL pools go into both `_liquidityPools` and `_clPools`)
   - If no match → address is cached in `_checkedNonPool` (so it's never probed again)

3. **Result**: Any pool created on a registered factory is automatically detected the first time someone tries to trade through it. No admin action needed per-pool.

### Cache Behavior

| Address Status | Gas Cost | External Calls |
|---|---|---|
| Already registered LP | ~2.5k (SLOAD) | 0 |
| Cached non-pool | ~2.5k (SLOAD) | 0 |
| First-time unknown (3 factories) | ~127k | Up to 10 external calls |
| Same address second time | ~10k | 0 |

### Edge Case: resetNonPoolCache

If a pool is created on a registered factory **after** an address was already cached as a non-pool, the admin can call:

```solidity
token.resetNonPoolCache(poolAddress);
```

The next transfer involving that address will re-probe the factories and detect the pool.

---

## New V3 Functions Reference

### CL Pool Management

```solidity
// Register a concentrated liquidity pool manually
// Adds to both _liquidityPools (tax trigger) and _clPools (CL tax mode)
function addCLPool(address newCLPool_) external onlyOwnerOrFactory;

// Remove a CL pool from both registries
function removeCLPool(address removedCLPool_) external onlyOwnerOrFactory;

// Check if an address is a registered CL pool
function isCLPool(address queryAddress_) external view returns (bool);

// List all registered CL pool addresses
function clPools() external view returns (address[] memory);
```

### Factory Registry (Auto-Detection)

```solidity
// Register a Uniswap V3 factory with fee tiers to probe
// feeTiers_: e.g., [100, 500, 3000, 10000]
function addUniV3Factory(address factory_, uint24[] calldata feeTiers_) external onlyOwnerOrFactory;

// Register an Aerodrome Slipstream factory with tick spacings to probe
// tickSpacings_: e.g., [1, 50, 100, 200]
function addSlipstreamFactory(address factory_, int24[] calldata tickSpacings_) external onlyOwnerOrFactory;

// Register an Aerodrome V2 factory (probes both stable and volatile)
function addV2Factory(address factory_) external onlyOwnerOrFactory;

// Remove factories by index (uses swap-and-pop)
function removeCLFactory(uint256 index_) external onlyOwnerOrFactory;
function removeV2Factory(uint256 index_) external onlyOwnerOrFactory;

// View factory registry
function clFactoryCount() external view returns (uint256);
function v2FactoryCount() external view returns (uint256);
function getCLFactory(uint256 index_) external view returns (
    address factory_, bool isSlipstream_, int24[] memory tickSpacings_, uint24[] memory feeTiers_
);
function getV2Factory(uint256 index_) external view returns (address factory_);

// Reset non-pool cache for an address (if pool was created after caching)
function resetNonPoolCache(address addr_) external onlyOwnerOrFactory;
```

### New Events

```solidity
event CLPoolAdded(address indexed pool);
event CLPoolRemoved(address indexed pool);
event CLFactoryAdded(address indexed factory, bool isSlipstream);
event CLFactoryRemoved(address indexed factory);
event V2FactoryAdded(address indexed factory);
event V2FactoryRemoved(address indexed factory);
event PoolAutoDetected(address indexed pool, address indexed factory);
```

### New Errors

```solidity
error InsufficientBalanceForCLTax();         // Sender can't cover amount + tax
error CLPoolCannotBeAddressZero();
error CLPoolMustBeAContractAddress();
error FactoryCannotBeAddressZero();
error FactoryMustBeAContractAddress();
error FactoryIndexOutOfBounds();
error MustProvideAtLeastOneTierOrSpacing();
```

---

## Upgrade Guide for Virtuals Team

### Step 1: Review the Diff

The only files that matter are:

| File | Action | Description |
|---|---|---|
| `src/AgentTokenV3.sol` | **REPLACE** implementation | New implementation contract with CL + auto-detect |
| `src/interfaces/IAgentTokenV3.sol` | **ADD** | V3 interface with new functions/events |
| `src/interfaces/ICLFactory.sol` | **ADD** | Uniswap V3 + Slipstream factory interfaces |
| `src/interfaces/IAeroV2Factory.sol` | **ADD** | Aerodrome V2 factory interface |

All other files (IAgentFactory, IERC20Config, IErrors, IUniswapV2*) are **unchanged from V2**.

### Step 2: Compile & Verify

```bash
forge build
```

Expected: clean compilation, 0 warnings.

### Step 3: Run Tests

```bash
# Full suite — 88 tests
forge test -v

# Or individually:
forge test --match-path test/AgentTokenV3.t.sol -v           # 48 unit tests (incl. fuzz)
forge test --match-path test/AgentTokenV3AutoDetect.t.sol -v  # 22 auto-detect unit tests
forge test --match-path test/AgentTokenV3Fork.t.sol -v        # 10 fork tests (AIXBT + FUTURE on Base)
forge test --match-path test/AgentTokenV3AutoDetectFork.t.sol -v  # 8 fork tests (real factories)
```

Fork tests require `ETH_RPC_URL` pointing to a Base mainnet RPC:

```bash
export ETH_RPC_URL=https://mainnet.base.org
```

### Step 4: Deploy New Implementation

Deploy `AgentTokenV3` as a new implementation contract. It will be used by existing proxies via `upgradeTo()` / `upgradeToAndCall()`.

```bash
forge create src/AgentTokenV3.sol:AgentTokenV3 \
  --rpc-url $ETH_RPC_URL \
  --private-key $DEPLOYER_KEY \
  --verify
```

### Step 5: Upgrade Existing Agent Token Proxies

For each agent token proxy you want to upgrade:

```solidity
// From the proxy admin / factory:
proxy.upgradeTo(newImplementationAddress);
```

**No re-initialization is needed.** V3 storage is append-only — all existing state (balances, tax rates, LP pools, blacklists) is preserved. New V3 storage variables start with safe zero/empty defaults.

### Step 6: Register Factories (Post-Upgrade)

After upgrading, register the DEX factories for auto-detection. See [Factory Registration](#factory-registration-post-deploy) below.

---

## Deployment Checklist

- [ ] Compile with `forge build` — no errors, no warnings
- [ ] Run all 88 tests with `forge test -v` — all green
- [ ] Run fork tests with a live Base RPC — all green
- [ ] Deploy new implementation contract
- [ ] Verify implementation on Basescan
- [ ] Upgrade agent token proxy(ies) to new implementation
- [ ] Register Uniswap V3 factory (with fee tiers `[100, 500, 3000, 10000]`)
- [ ] Register Aerodrome Slipstream CLFactory (with tick spacings `[1, 50, 100, 200]`)
- [ ] Register Aerodrome V2 PoolFactory
- [ ] Test: create a CL pool for an upgraded agent token, swap through it
- [ ] Verify `PoolAutoDetected` event fires on first swap
- [ ] Verify V2 pools still work identically (no regression)

---

## Factory Registration (Post-Deploy)

After upgrading, the owner (or factory contract) should register DEX factories. This only needs to be done **once per agent token**.

### Base Mainnet Factories

```solidity
// 1. Uniswap V3 Factory
uint24[] memory feeTiers = new uint24[](4);
feeTiers[0] = 100;     // 0.01%
feeTiers[1] = 500;     // 0.05%
feeTiers[2] = 3000;    // 0.30%
feeTiers[3] = 10000;   // 1.00%
token.addUniV3Factory(
    0x33128a8fC17869897dcE68Ed026d694621f6FDfD,
    feeTiers
);

// 2. Aerodrome Slipstream CLFactory
int24[] memory tickSpacings = new int24[](4);
tickSpacings[0] = 1;
tickSpacings[1] = 50;
tickSpacings[2] = 100;
tickSpacings[3] = 200;
token.addSlipstreamFactory(
    0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A,
    tickSpacings
);

// 3. Aerodrome V2 PoolFactory
token.addV2Factory(
    0x420DD381b31aEf6683db6B902084cB0FFECe40Da
);
```

### If the Virtuals AgentFactory Deploys New Tokens

The factory can call these registration functions during `initialize()` or immediately after, since they are gated by `onlyOwnerOrFactory`.

---

## Build & Test

### Prerequisites

- [Foundry](https://book.getfoundry.sh/) (`forge`, `cast`, `anvil`)
- Solidity `^0.8.20`
- For fork tests: Base mainnet RPC URL

### Install Dependencies

```bash
forge install OpenZeppelin/openzeppelin-contracts@v5.1.0
forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.1.0
forge install foundry-rs/forge-std
```

### Build

```bash
forge build
```

### Run All Tests (88 tests)

```bash
# Unit tests only (70 tests — no RPC needed)
forge test --match-path "test/AgentTokenV3.t.sol" -v
forge test --match-path "test/AgentTokenV3AutoDetect.t.sol" -v

# Fork tests (18 tests — requires Base RPC)
export ETH_RPC_URL=https://mainnet.base.org
forge test --match-path "test/AgentTokenV3Fork.t.sol" -v
forge test --match-path "test/AgentTokenV3AutoDetectFork.t.sol" -v

# Everything
forge test -v
```

### Test Coverage Breakdown

| Test File | Tests | Type | What It Covers |
|---|---|---|---|
| `AgentTokenV3.t.sol` | 48 | Unit + Fuzz | Core dual-mode tax: V2 sells, CL sells, buys, zero-tax, edge cases, 256-run fuzz |
| `AgentTokenV3AutoDetect.t.sol` | 22 | Unit | Factory registration, auto-detection with mock factories, caching, edge cases |
| `AgentTokenV3Fork.t.sol` | 10 | Fork (Base) | Real AIXBT (V1) + FUTURE (V2) token storage, swap through real pools |
| `AgentTokenV3AutoDetectFork.t.sol` | 8 | Fork (Base) | Auto-detection against real UniV3 Factory, Slipstream CLFactory, Aero V2 Factory |

---

## Gas Impact

Measured on Base mainnet fork with 3 registered factories (UniV3 + Slipstream + Aero V2):

| Scenario | Gas | Notes |
|---|---|---|
| Transfer to known LP (already registered) | ~65k | Same as V2 |
| Transfer to cached non-pool address | ~65k | Same as V2 (SLOAD check) |
| Transfer to unknown contract (first time, probes 3 factories) | ~127k | +62k for factory probes |
| Transfer to same unknown contract (second time, cached) | ~10k | Cached as non-pool |
| **Gas saved by caching** | **~117k** | After first transfer, no more probes |

The auto-detection overhead only occurs on the **first transfer** involving an unrecognized contract address. All subsequent transfers to/from that address are cached.

---

## File Structure

```
AgentTokenV3/
├── src/
│   ├── AgentTokenV3.sol                    # Main contract (~1200 lines)
│   └── interfaces/
│       ├── IAgentTokenV3.sol               # V3 interface (extends V2)
│       ├── ICLFactory.sol                  # UniV3 + Slipstream factory interfaces (NEW)
│       ├── IAeroV2Factory.sol              # Aerodrome V2 factory interface (NEW)
│       ├── IAgentFactory.sol               # Virtuals factory interface (unchanged)
│       ├── IERC20Config.sol                # ERC20 config structs (unchanged)
│       ├── IErrors.sol                     # Custom errors (unchanged)
│       ├── IUniswapV2Router02.sol          # Uniswap V2 router (unchanged)
│       ├── IUniswapV2Factory.sol           # Uniswap V2 factory (unchanged)
│       └── IUniswapV2Pair.sol              # Uniswap V2 pair (unchanged)
├── test/
│   ├── AgentTokenV3.t.sol                  # 48 unit tests (incl. fuzz)
│   ├── AgentTokenV3AutoDetect.t.sol        # 22 auto-detection unit tests
│   ├── AgentTokenV3Fork.t.sol              # 10 fork tests (AIXBT + FUTURE on Base)
│   └── AgentTokenV3AutoDetectFork.t.sol    # 8 fork tests (real factories on Base)
├── reference/
│   ├── AgentToken_original.sol             # V1 source (AIXBT impl)
│   └── AgentTokenV2_original.sol           # V2 source (AgentTokenV2 impl)
├── foundry.toml
├── remappings.txt
└── .gitignore
```

---

## Key Addresses (Base Mainnet)

### DEX Infrastructure

| Contract | Address |
|---|---|
| Uniswap V3 Factory | `0x33128a8fC17869897dcE68Ed026d694621f6FDfD` |
| Uniswap V3 SwapRouter | `0x2626664c2603336E57B271c5C0b26F421741e481` |
| Aerodrome Slipstream CLFactory | `0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A` |
| Aerodrome V2 PoolFactory | `0x420DD381b31aEf6683db6B902084cB0FFECe40Da` |

### Reference Tokens

| Token | Proxy | Implementation | Version |
|---|---|---|---|
| AIXBT | `0x4F9Fd6Be4a90f2620860d680c0d4d5Fb53d1A825` | `0x082Cb6e892Dd0699B5f0d22f7D2e638BBAdA5D94` | V1 |
| FUTURE | `0x810e903C667e02D901f8A70413161629068e6EC5` | `0x7BaB5D2e3EbdE7293888B3f4c022aAAAD88Ae2db` | V2 |

### Core Virtuals Contracts

| Contract | Address |
|---|---|
| VIRTUAL token | `0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b` |
| WETH | `0x4200000000000000000000000000000000000006` |

---

## Dependencies

| Package | Version | Purpose |
|---|---|---|
| Solidity | `^0.8.20` | Compiler |
| OpenZeppelin Contracts | `v5.1.0` | ERC20, SafeERC20, EnumerableSet |
| OpenZeppelin Upgradeable | `v5.1.0` | Initializable, Ownable2Step, Context |
| forge-std | latest | Test framework |

---

## Security Considerations

### What's Safe

- **Storage layout is append-only** — no existing slots are moved or reinterpreted
- **V2 behavior is preserved** — all existing V2 pool interactions work identically
- **Factory probes are wrapped in try/catch** — if a factory call reverts, it's silently skipped
- **Auto-detected pools are permanently registered** — once detected, they behave like manually added pools
- **onlyOwnerOrFactory** gating on all admin functions — same access control as V2
- **Non-pool cache prevents gas griefing** — unknown addresses are only probed once

### What to Watch

- **CL sell requires `amount + tax` balance** — if a user has exactly `amount` tokens, a CL sell will revert with `InsufficientBalanceForCLTax()`. This is by design (the tax has to come from somewhere).
- **Auto-detection is limited to registered factories** — if a new DEX factory launches, it must be registered via `addUniV3Factory()`, `addSlipstreamFactory()`, or `addV2Factory()`.
- **`resetNonPoolCache()` is admin-only** — if a pool is created after an address was cached as non-pool, the admin must explicitly reset it.
- **Factory removal uses swap-and-pop** — removing a factory by index changes the index of the last factory. Read `clFactoryCount()`/`v2FactoryCount()` before removing.

---

## Based On

- [AgentToken V1](https://basescan.org/address/0x082Cb6e892Dd0699B5f0d22f7D2e638BBAdA5D94#code) — AIXBT implementation (audited)
- [AgentToken V2](https://basescan.org/address/0x7BaB5D2e3EbdE7293888B3f4c022aAAAD88Ae2db#code) — V2 implementation (audited)

---

## License

MIT
