// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IAgentTokenV3.sol";
import "./interfaces/IAgentFactory.sol";
import "./interfaces/ICLFactory.sol";
import "./interfaces/IAeroV2Factory.sol";

/**
 * @title AgentTokenV3
 * @notice Upgraded AgentToken with native concentrated liquidity (CL) pool compatibility.
 *
 * ## Problem
 * CL pools (Uniswap V3, Aerodrome Slipstream) verify exact token amounts received
 * via balance checks: `balanceBefore + expectedAmount <= balanceAfter`. The original
 * AgentToken tax model skims tokens from the delivered amount, causing CL pools to
 * revert with 'IIA' (Insufficient Input Amount) on sells.
 *
 * ## Solution: Dual-Mode Tax
 * - **V2 pools (AMM)**: Tax is deducted from the delivered amount (original behavior).
 *   Pool receives `amount - tax`. V2 doesn't verify received amounts.
 * - **CL pools (V3/Slipstream)**: Tax is debited from the sender's remaining balance
 *   SEPARATELY from the transfer. Pool receives the full `amount`. The sender pays
 *   `amount + tax` total from their balance.
 *
 * Buy-side tax works identically for both pool types (pool sends tokens out, user
 * receives amount - tax, pool doesn't verify what recipient got).
 *
 * ## Transfer Event Semantics (M-09)
 * CL sell path emits Transfer(from, to, amount) for the full amount sent to the pool,
 * plus a separate Transfer(from, this, tax) for the tax portion.
 * V2 sell path emits Transfer(from, to, amountMinusTax) — net of tax.
 * Both are correct per ERC-20 spec. Indexers should account for the separate tax
 * Transfer event when tracking CL pool interactions.
 *
 * ## Storage Layout
 * This contract extends AgentTokenV2's storage layout. New storage variables are
 * appended at the end to maintain proxy compatibility. The existing storage slots
 * (inherited from AgentToken → AgentTokenV2) are NOT modified.
 *
 * @dev Based on the audited AgentTokenV2 at 0x7BaB5D2e3EbdE7293888B3f4c022aAAAD88Ae2db
 */
contract AgentTokenV3 is
    ContextUpgradeable,
    IAgentTokenV3,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable  // [H-02/M-06] Added for CEI safety
{
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using SafeERC20 for IERC20;

    // =========================================================================
    //                           CONSTANTS
    // =========================================================================

    uint256 internal constant BP_DENOM = 10000;
    // [Audit-v2 I-04] Removed unused ROUND_DEC = 100000000000
    uint256 internal constant CALL_GAS_LIMIT = 50000;
    uint256 internal constant MAX_SWAP_THRESHOLD_MULTIPLE = 20;

    // [H-03/M-10] Maximum factory and tier counts to prevent gas griefing
    // [Audit-v2 I-02] Actual caps: 5 CL factories, 3 V2 factories, 8 tiers each
    uint256 internal constant MAX_CL_FACTORIES = 5;
    uint256 internal constant MAX_V2_FACTORIES = 3;
    uint256 internal constant MAX_TIERS_PER_FACTORY = 8;

    // [M-01] Minimum slippage for autoswap (95% = 500 BPS tolerance)
    uint256 internal constant AUTOSWAP_SLIPPAGE_BPS = 500;

    // [Audit-v2 M-01] Maximum tax rate cap: 10% (1000 basis points)
    // Previously capped at BP_DENOM (100%) which allowed ruinous tax rates.
    uint256 internal constant MAX_TAX_BP = 1000;

    // =========================================================================
    //                  STORAGE — INHERITED FROM AgentToken V1
    //                  (DO NOT reorder, remove, or insert above)
    // =========================================================================

    address public uniswapV2Pair;
    uint256 public botProtectionDurationInSeconds;
    bool internal _tokenHasTax;
    IUniswapV2Router02 internal _uniswapRouter;

    uint32 public fundedDate;
    uint16 public projectBuyTaxBasisPoints;
    uint16 public projectSellTaxBasisPoints;
    uint16 public swapThresholdBasisPoints;
    address public pairToken; // The token used to trade for this token, $Virtual

    bool private _autoSwapInProgress;

    address public projectTaxRecipient;
    uint128 public projectTaxPendingSwap; // [M-03] kept uint128 for storage compat, overflow-checked below
    address public vault; // Project supply vault

    string private _name;
    string private _symbol;
    uint256 private _totalSupply;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    EnumerableSet.Bytes32Set private _validCallerCodeHashes;
    EnumerableSet.AddressSet private _liquidityPools;

    IAgentFactory private _factory;

    // =========================================================================
    //                  STORAGE — INHERITED FROM AgentTokenV2
    //                  (DO NOT reorder, remove, or insert above)
    // =========================================================================

    mapping(address => bool) public blacklists;

    // =========================================================================
    //                  STORAGE — NEW IN AgentTokenV3
    //                  (Appended below existing storage for proxy safety)
    // =========================================================================

    /** @dev {_clPools} Enumerable set for concentrated liquidity pool addresses.
     *  These pools require the "debit-from-sender" tax model on sells. */
    EnumerableSet.AddressSet private _clPools;

    // --- Auto-detection factory registry ---

    /// @dev Struct holding a CL factory address and the fee tiers / tick spacings to probe.
    struct CLFactoryEntry {
        address factory;
        bool isSlipstream;      // true = int24 tickSpacing lookup, false = uint24 fee lookup
        int24[] tickSpacings;   // used when isSlipstream == true
        uint24[] feeTiers;      // used when isSlipstream == false
    }

    /// @dev Struct holding an Aerodrome V2 factory address.
    struct V2FactoryEntry {
        address factory;
    }

    /// @dev Array of registered CL factories for auto-detection.
    CLFactoryEntry[] private _clFactories;

    /// @dev Array of registered Aerodrome V2 factories for auto-detection.
    V2FactoryEntry[] private _v2Factories;

    /// @dev Addresses that have already been checked and are NOT pools.
    ///      Avoids repeated external calls for known non-pool addresses.
    mapping(address => bool) private _checkedNonPool;

    /// @dev [Audit-v2 L-04] Storage gap reserve for future V4 implementations.
    /// Prevents storage collisions if new variables need to be inserted.
    uint256[50] private __gapV3;

    // =========================================================================
    //                           ERRORS — NEW IN V3
    // =========================================================================

    error InsufficientBalanceForCLTax();
    error CLPoolCannotBeAddressZero();
    error CLPoolMustBeAContractAddress();
    error FactoryCannotBeAddressZero();
    error FactoryMustBeAContractAddress();
    error FactoryIndexOutOfBounds();
    error MustProvideAtLeastOneTierOrSpacing();
    // [H-01/L-01] Tax rate exceeds maximum
    error TaxRateExceedsMaximum();
    // [H-03/M-10] Factory or tier limit reached
    error MaxCLFactoriesReached();
    error MaxV2FactoriesReached();
    error MaxTiersPerFactoryReached();
    // [M-07] Block renounceOwnership
    error RenounceOwnershipDisabled();
    // [L-02] Swap threshold cannot be zero
    error SwapThresholdCannotBeZero();
    // [M-08] Blacklist on send
    error TransferFromBlacklistedAddress();
    // [M-05] Invalid pool address from factory
    error InvalidPoolAddress();
    // [L-07] Caller not authorized
    error CallerIsNotOwner();
    // [Audit-v2 M-04] Duplicate factory
    error FactoryAlreadyRegistered();

    // =========================================================================
    //                           MODIFIERS
    // =========================================================================

    modifier onlyOwnerOrFactory() {
        if (owner() != _msgSender() && address(_factory) != _msgSender()) {
            revert CallerIsNotAdminNorFactory();
        }
        _;
    }

    // [H-04] Separate modifier for sensitive operations — owner only, no factory
    modifier onlyOwnerStrict() {
        if (owner() != _msgSender()) {
            revert CallerIsNotOwner();
        }
        _;
    }

    // =========================================================================
    //                           CONSTRUCTOR
    // =========================================================================

    constructor() {
        _disableInitializers();
    }

    // =========================================================================
    //                        INITIALIZATION
    // =========================================================================

    /**
     * @dev [Audit-v2 L-07] For CREATE2 clones with predictable addresses, an attacker
     * could theoretically front-run initialize() with malicious parameters. Impact is
     * minimal: attacker controls a token with no LP (gated behind addInitialLiquidity)
     * and the factory retries with a fresh address. No funds at risk.
     */
    function initialize(
        address[3] memory integrationAddresses_,
        bytes memory baseParams_,
        bytes memory supplyParams_,
        bytes memory taxParams_
    ) external initializer {
        _decodeBaseParams(integrationAddresses_[0], baseParams_);
        _uniswapRouter = IUniswapV2Router02(integrationAddresses_[1]);
        pairToken = integrationAddresses_[2];

        ERC20SupplyParameters memory supplyParams = abi.decode(
            supplyParams_,
            (ERC20SupplyParameters)
        );

        ERC20TaxParameters memory taxParams = abi.decode(
            taxParams_,
            (ERC20TaxParameters)
        );

        _processSupplyParams(supplyParams);

        uint256 lpSupply = supplyParams.lpSupply * (10 ** decimals());
        uint256 vaultSupply = supplyParams.vaultSupply * (10 ** decimals());

        botProtectionDurationInSeconds = supplyParams
            .botProtectionDurationInSeconds;

        _tokenHasTax = _processTaxParams(taxParams);
        swapThresholdBasisPoints = uint16(
            taxParams.taxSwapThresholdBasisPoints
        );
        // [L-02] Validate swap threshold at initialization
        if (_tokenHasTax && swapThresholdBasisPoints == 0) {
            revert SwapThresholdCannotBeZero();
        }
        projectTaxRecipient = taxParams.projectTaxRecipient;

        _mintBalances(lpSupply, vaultSupply);

        uniswapV2Pair = _createPair();

        _factory = IAgentFactory(_msgSender());
        // [Audit-v2 I-05] _autoSwapInProgress starts true and is only set false
        // when addInitialLiquidity() is called. Until then, NO tax is collected.
        // This is a deployment prerequisite, not a bug.
        _autoSwapInProgress = true;

        // [H-02/M-06] Initialize reentrancy guard
        __ReentrancyGuard_init();
    }

    // =========================================================================
    //                        INTERNAL HELPERS
    // =========================================================================

    function _decodeBaseParams(
        address projectOwner_,
        bytes memory encodedBaseParams_
    ) internal {
        // [Audit-v2 L-01] Proper OZ initialization before transferring ownership
        __Context_init();
        __Ownable_init(projectOwner_);
        (_name, _symbol) = abi.decode(encodedBaseParams_, (string, string));
    }

    function _processSupplyParams(
        ERC20SupplyParameters memory erc20SupplyParameters_
    ) internal {
        if (
            erc20SupplyParameters_.maxSupply !=
            (erc20SupplyParameters_.vaultSupply +
                erc20SupplyParameters_.lpSupply)
        ) {
            revert SupplyTotalMismatch();
        }

        if (erc20SupplyParameters_.maxSupply > type(uint128).max) {
            revert MaxSupplyTooHigh();
        }

        vault = erc20SupplyParameters_.vault;
    }

    function _processTaxParams(
        ERC20TaxParameters memory erc20TaxParameters_
    ) internal returns (bool tokenHasTax_) {
        if (
            erc20TaxParameters_.projectBuyTaxBasisPoints == 0 &&
            erc20TaxParameters_.projectSellTaxBasisPoints == 0
        ) {
            return false;
        } else {
            // [Audit-v2 M-01] Validate tax rates at initialization — capped at 10%
            if (erc20TaxParameters_.projectBuyTaxBasisPoints > MAX_TAX_BP) {
                revert TaxRateExceedsMaximum();
            }
            if (erc20TaxParameters_.projectSellTaxBasisPoints > MAX_TAX_BP) {
                revert TaxRateExceedsMaximum();
            }
            projectBuyTaxBasisPoints = uint16(
                erc20TaxParameters_.projectBuyTaxBasisPoints
            );
            projectSellTaxBasisPoints = uint16(
                erc20TaxParameters_.projectSellTaxBasisPoints
            );
            return true;
        }
    }

    function _mintBalances(uint256 lpMint_, uint256 vaultMint_) internal {
        if (lpMint_ > 0) {
            _mint(address(this), lpMint_);
        }
        if (vaultMint_ > 0) {
            _mint(vault, vaultMint_);
        }
    }

    function _createPair() internal returns (address uniswapV2Pair_) {
        uniswapV2Pair_ = IUniswapV2Factory(_uniswapRouter.factory()).getPair(
            address(this),
            pairToken
        );

        if (uniswapV2Pair_ == address(0)) {
            uniswapV2Pair_ = IUniswapV2Factory(_uniswapRouter.factory())
                .createPair(address(this), pairToken);

            emit LiquidityPoolCreated(uniswapV2Pair_);
        }

        _liquidityPools.add(uniswapV2Pair_);

        return (uniswapV2Pair_);
    }

    // =========================================================================
    //                        LIQUIDITY & POOL MANAGEMENT
    // =========================================================================

    function addInitialLiquidity(address lpOwner) external onlyOwnerOrFactory {
        _addInitialLiquidity(lpOwner);
    }

    function _addInitialLiquidity(address lpOwner) internal {
        if (fundedDate != 0) {
            revert InitialLiquidityAlreadyAdded();
        }

        fundedDate = uint32(block.timestamp);

        if (balanceOf(address(this)) == 0) {
            revert NoTokenForLiquidityPair();
        }

        _approve(address(this), address(_uniswapRouter), type(uint256).max);
        IERC20(pairToken).approve(address(_uniswapRouter), type(uint256).max);

        address pairAddr = IUniswapV2Factory(_uniswapRouter.factory()).getPair(
            address(this),
            pairToken
        );

        uint256 amountA = balanceOf(address(this));
        uint256 amountB = IERC20(pairToken).balanceOf(address(this));

        _transfer(address(this), pairAddr, amountA, false);
        IERC20(pairToken).transfer(pairAddr, amountB);

        uint256 lpTokens = IUniswapV2Pair(pairAddr).mint(address(this));

        emit InitialLiquidityAdded(amountA, amountB, lpTokens);

        _autoSwapInProgress = false;

        IERC20(uniswapV2Pair).transfer(lpOwner, lpTokens);
    }

    /**
     * @dev Return if an address is a liquidity pool (V2 or CL)
     */
    function isLiquidityPool(address queryAddress_) public view returns (bool) {
        return (queryAddress_ == uniswapV2Pair ||
            _liquidityPools.contains(queryAddress_));
    }

    function liquidityPools()
        external
        view
        returns (address[] memory liquidityPools_)
    {
        return (_liquidityPools.values());
    }

    function addLiquidityPool(
        address newLiquidityPool_
    ) public onlyOwnerOrFactory {
        if (newLiquidityPool_ == address(0)) {
            revert LiquidityPoolCannotBeAddressZero();
        }
        if (newLiquidityPool_.code.length == 0) {
            revert LiquidityPoolMustBeAContractAddress();
        }
        _liquidityPools.add(newLiquidityPool_);
        emit LiquidityPoolAdded(newLiquidityPool_);
    }

    function removeLiquidityPool(
        address removedLiquidityPool_
    ) external onlyOwnerOrFactory {
        _liquidityPools.remove(removedLiquidityPool_);
        emit LiquidityPoolRemoved(removedLiquidityPool_);
    }

    // =========================================================================
    //                   CL POOL MANAGEMENT — NEW IN V3
    // =========================================================================

    /**
     * @dev Return if an address is a concentrated liquidity pool.
     * CL pools use the "debit-from-sender" tax model on sells.
     */
    function isCLPool(address queryAddress_) public view returns (bool) {
        return _clPools.contains(queryAddress_);
    }

    /**
     * @dev Returns a list of all registered CL pools.
     */
    function clPools() external view returns (address[] memory clPools_) {
        return (_clPools.values());
    }

    /**
     * @dev Register a concentrated liquidity pool. This adds it to BOTH the
     * liquidity pool set (so tax applies) AND the CL pool set (so the
     * CL-compatible tax model is used on sells).
     *
     * @param newCLPool_ The address of the CL pool (UniV3, Slipstream, etc.)
     */
    function addCLPool(address newCLPool_) external onlyOwnerOrFactory {
        if (newCLPool_ == address(0)) {
            revert CLPoolCannotBeAddressZero();
        }
        if (newCLPool_.code.length == 0) {
            revert CLPoolMustBeAContractAddress();
        }
        // Add to both sets: liquidity pool (for tax trigger) + CL pool (for CL tax mode)
        _liquidityPools.add(newCLPool_);
        _clPools.add(newCLPool_);
        emit LiquidityPoolAdded(newCLPool_);
        emit CLPoolAdded(newCLPool_);
    }

    /**
     * @dev Remove a concentrated liquidity pool from CL registry.
     * Also removes from the liquidity pool set.
     *
     * @param removedCLPool_ The CL pool address to remove
     */
    function removeCLPool(address removedCLPool_) external onlyOwnerOrFactory {
        _liquidityPools.remove(removedCLPool_);
        _clPools.remove(removedCLPool_);
        // [Audit-v2 M-05] Mark as non-pool to prevent auto re-detection
        // Without this, _autoDetectAndRegister would re-add it on the next transfer.
        _checkedNonPool[removedCLPool_] = true;
        emit LiquidityPoolRemoved(removedCLPool_);
        emit CLPoolRemoved(removedCLPool_);
    }

    // =========================================================================
    //               FACTORY REGISTRY — AUTO-DETECTION (NEW IN V3)
    // =========================================================================

    /**
     * @dev Register a Uniswap V3 factory for auto-detection.
     * @param factory_ The UniswapV3Factory address
     * @param feeTiers_ Array of fee tiers to probe (e.g., [100, 500, 3000, 10000])
     */
    // [Audit-v2 M-03] Factory management restricted to owner only (was onlyOwnerOrFactory)
    // A compromised factory could register arbitrary pools for tax evasion.
    function addUniV3Factory(
        address factory_,
        uint24[] calldata feeTiers_
    ) external onlyOwnerStrict {
        _validateFactory(factory_);
        if (feeTiers_.length == 0) revert MustProvideAtLeastOneTierOrSpacing();
        // [H-03/M-10] Enforce factory and tier caps
        if (_clFactories.length >= MAX_CL_FACTORIES) revert MaxCLFactoriesReached();
        if (feeTiers_.length > MAX_TIERS_PER_FACTORY) revert MaxTiersPerFactoryReached();
        // [Audit-v2 M-04] Prevent duplicate factory registration
        if (_isCLFactoryDuplicate(factory_)) revert FactoryAlreadyRegistered();
        CLFactoryEntry storage entry = _clFactories.push();
        entry.factory = factory_;
        entry.isSlipstream = false;
        for (uint256 i = 0; i < feeTiers_.length; i++) {
            entry.feeTiers.push(feeTiers_[i]);
        }
        emit CLFactoryAdded(factory_, false);
    }

    /**
     * @dev Register an Aerodrome Slipstream CLFactory for auto-detection.
     * @param factory_ The Slipstream CLFactory address
     * @param tickSpacings_ Array of tick spacings to probe (e.g., [1, 50, 100, 200])
     */
    // [Audit-v2 M-03] Factory management restricted to owner only
    function addSlipstreamFactory(
        address factory_,
        int24[] calldata tickSpacings_
    ) external onlyOwnerStrict {
        _validateFactory(factory_);
        if (tickSpacings_.length == 0) revert MustProvideAtLeastOneTierOrSpacing();
        // [H-03/M-10] Enforce factory and tier caps
        if (_clFactories.length >= MAX_CL_FACTORIES) revert MaxCLFactoriesReached();
        if (tickSpacings_.length > MAX_TIERS_PER_FACTORY) revert MaxTiersPerFactoryReached();
        // [Audit-v2 M-04] Prevent duplicate factory registration
        if (_isCLFactoryDuplicate(factory_)) revert FactoryAlreadyRegistered();
        CLFactoryEntry storage entry = _clFactories.push();
        entry.factory = factory_;
        entry.isSlipstream = true;
        for (uint256 i = 0; i < tickSpacings_.length; i++) {
            entry.tickSpacings.push(tickSpacings_[i]);
        }
        emit CLFactoryAdded(factory_, true);
    }

    /**
     * @dev Register an Aerodrome V2 factory for auto-detection.
     * @param factory_ The Aerodrome V2 PoolFactory address
     */
    // [Audit-v2 M-03] Factory management restricted to owner only
    function addV2Factory(address factory_) external onlyOwnerStrict {
        _validateFactory(factory_);
        // [H-03/M-10] Enforce factory cap
        if (_v2Factories.length >= MAX_V2_FACTORIES) revert MaxV2FactoriesReached();
        // [Audit-v2 M-04] Prevent duplicate factory registration
        if (_isV2FactoryDuplicate(factory_)) revert FactoryAlreadyRegistered();
        _v2Factories.push(V2FactoryEntry({factory: factory_}));
        emit V2FactoryAdded(factory_);
    }

    /**
     * @dev Remove a CL factory by index.
     */
    // [Audit-v2 M-03] Factory management restricted to owner only
    function removeCLFactory(uint256 index_) external onlyOwnerStrict {
        if (index_ >= _clFactories.length) revert FactoryIndexOutOfBounds();
        address removed = _clFactories[index_].factory;
        // Swap with last and pop
        _clFactories[index_] = _clFactories[_clFactories.length - 1];
        _clFactories.pop();
        emit CLFactoryRemoved(removed);
    }

    /**
     * @dev Remove a V2 factory by index.
     */
    // [Audit-v2 M-03] Factory management restricted to owner only
    function removeV2Factory(uint256 index_) external onlyOwnerStrict {
        if (index_ >= _v2Factories.length) revert FactoryIndexOutOfBounds();
        address removed = _v2Factories[index_].factory;
        _v2Factories[index_] = _v2Factories[_v2Factories.length - 1];
        _v2Factories.pop();
        emit V2FactoryRemoved(removed);
    }

    /**
     * @dev Returns the number of registered CL factories.
     */
    function clFactoryCount() external view returns (uint256) {
        return _clFactories.length;
    }

    /**
     * @dev Returns the number of registered V2 factories.
     */
    function v2FactoryCount() external view returns (uint256) {
        return _v2Factories.length;
    }

    /**
     * @dev Returns CL factory info at index.
     */
    function getCLFactory(uint256 index_) external view returns (
        address factory_,
        bool isSlipstream_,
        int24[] memory tickSpacings_,
        uint24[] memory feeTiers_
    ) {
        if (index_ >= _clFactories.length) revert FactoryIndexOutOfBounds();
        CLFactoryEntry storage entry = _clFactories[index_];
        return (entry.factory, entry.isSlipstream, entry.tickSpacings, entry.feeTiers);
    }

    /**
     * @dev Returns V2 factory address at index.
     */
    function getV2Factory(uint256 index_) external view returns (address factory_) {
        if (index_ >= _v2Factories.length) revert FactoryIndexOutOfBounds();
        return _v2Factories[index_].factory;
    }

    /**
     * @dev Reset the non-pool cache for an address (e.g., if a pool is created later).
     * [L-06] Restricted to owner only — factory cannot grief high-traffic addresses.
     */
    function resetNonPoolCache(address addr_) external onlyOwnerStrict {
        _checkedNonPool[addr_] = false;
    }

    function _validateFactory(address factory_) internal view {
        if (factory_ == address(0)) revert FactoryCannotBeAddressZero();
        if (factory_.code.length == 0) revert FactoryMustBeAContractAddress();
    }

    /// @dev [Audit-v2 M-04] Check if a CL factory address is already registered
    function _isCLFactoryDuplicate(address factory_) internal view returns (bool) {
        for (uint256 i = 0; i < _clFactories.length; i++) {
            if (_clFactories[i].factory == factory_) return true;
        }
        return false;
    }

    /// @dev [Audit-v2 M-04] Check if a V2 factory address is already registered
    function _isV2FactoryDuplicate(address factory_) internal view returns (bool) {
        for (uint256 i = 0; i < _v2Factories.length; i++) {
            if (_v2Factories[i].factory == factory_) return true;
        }
        return false;
    }

    // =========================================================================
    //               AUTO-DETECTION LOGIC (NEW IN V3)
    // =========================================================================

    /**
     * @dev Attempt to auto-detect if `candidate_` is a liquidity pool on any
     *      registered factory. If found, auto-registers it.
     *
     *      This is called from `_transfer` for addresses not already in the
     *      liquidity pool set and not in the non-pool cache.
     *
     *      Returns true if the candidate was detected and registered as a pool.
     *
     *      [Audit-v2 I-08] Gas cost: Up to 5 CL factories * 8 tiers = 40 CL probes
     *      + 3 V2 factories * 2 modes = 6 V2 probes = 46 calls * 50k gas = ~2.3M gas.
     *      One-time per address; subsequent transfers use cache.
     *
     *      [Audit-v2 L-05] CL detection probes hardcoded fee tiers only. Non-standard
     *      tiers must be registered manually via addCLPool().
     *
     *      [Audit-v2 L-06] V2 probes both stable=true and stable=false. If a factory
     *      returns different pools, both are registered (harmless but slightly wasteful).
     */
    function _autoDetectAndRegister(address candidate_) internal returns (bool) {
        // Skip if no factories registered or candidate has no code
        if ((_clFactories.length + _v2Factories.length) == 0) return false;
        // [M-04] Don't cache and don't probe addresses with no code —
        // they might have code deployed later via CREATE2
        if (candidate_.code.length == 0) return false;

        address self = address(this);

        // Check CL factories (UniV3 + Slipstream)
        for (uint256 i = 0; i < _clFactories.length; i++) {
            CLFactoryEntry storage entry = _clFactories[i];
            if (entry.isSlipstream) {
                // Slipstream: getPool(tokenA, tokenB, int24 tickSpacing)
                for (uint256 j = 0; j < entry.tickSpacings.length; j++) {
                    try ISlipstreamCLFactory(entry.factory).getPool{gas: CALL_GAS_LIMIT}(
                        self, pairToken, entry.tickSpacings[j]
                    ) returns (address pool) {
                        // [M-05] Validate factory return — must match candidate AND be a contract
                        if (pool == candidate_ && pool != address(0) && pool != self && pool != projectTaxRecipient) {
                            _liquidityPools.add(candidate_);
                            _clPools.add(candidate_);
                            emit LiquidityPoolAdded(candidate_);
                            emit CLPoolAdded(candidate_);
                            emit PoolAutoDetected(candidate_, entry.factory);
                            return true;
                        }
                    } catch {}
                }
            } else {
                // UniV3: getPool(tokenA, tokenB, uint24 fee)
                for (uint256 j = 0; j < entry.feeTiers.length; j++) {
                    try ICLFactory(entry.factory).getPool{gas: CALL_GAS_LIMIT}(
                        self, pairToken, entry.feeTiers[j]
                    ) returns (address pool) {
                        // [M-05] Validate factory return — must match candidate AND be a contract
                        if (pool == candidate_ && pool != address(0) && pool != self && pool != projectTaxRecipient) {
                            _liquidityPools.add(candidate_);
                            _clPools.add(candidate_);
                            emit LiquidityPoolAdded(candidate_);
                            emit CLPoolAdded(candidate_);
                            emit PoolAutoDetected(candidate_, entry.factory);
                            return true;
                        }
                    } catch {}
                }
            }
        }

        // Check V2 factories (Aerodrome V2)
        for (uint256 i = 0; i < _v2Factories.length; i++) {
            address factoryAddr = _v2Factories[i].factory;
            // Check both stable and volatile pools
            for (uint256 s = 0; s < 2; s++) {
                bool stable = (s == 0);
                try IAeroV2Factory(factoryAddr).getPool{gas: CALL_GAS_LIMIT}(
                    self, pairToken, stable
                ) returns (address pool) {
                    // [M-05] Validate factory return
                    if (pool == candidate_ && pool != address(0) && pool != self && pool != projectTaxRecipient) {
                        _liquidityPools.add(candidate_);
                        // V2 pools use original tax model, NOT CL
                        emit LiquidityPoolAdded(candidate_);
                        emit PoolAutoDetected(candidate_, factoryAddr);
                        return true;
                    }
                } catch {}
            }
        }

        // [M-04] Only cache as non-pool if address has code.
        // Zero-code addresses are not cached because a CL pool may be deployed
        // there later via CREATE2.
        if (candidate_.code.length > 0) {
            _checkedNonPool[candidate_] = true;
        }
        return false;
    }

    /**
     * @dev Returns true if `addr_` is an already-registered liquidity pool,
     *      OR if it is auto-detected as one on a registered factory.
     *
     *      Fast path: if already in the LP set, return immediately.
     *      Slow path: if not in cache and factories are registered, probe factories.
     */
    function _isOrDetectPool(address addr_) internal returns (bool) {
        // Fast path: already registered
        if (addr_ == uniswapV2Pair || _liquidityPools.contains(addr_)) {
            return true;
        }
        // Already checked and not a pool
        if (_checkedNonPool[addr_]) {
            return false;
        }
        // Try auto-detection
        return _autoDetectAndRegister(addr_);
    }

    // =========================================================================
    //                        BLACKLIST (from V2)
    // =========================================================================

    function addBlacklistAddress(
        address blacklistAddress
    ) external onlyOwnerOrFactory {
        blacklists[blacklistAddress] = true;
    }

    function removeBlacklistAddress(
        address blacklistAddress
    ) external onlyOwnerOrFactory {
        delete blacklists[blacklistAddress];
    }

    // =========================================================================
    //                    VALID CALLER MANAGEMENT
    //   [Audit-v2 I-01] These functions are LEGACY from V1. The code hashes
    //   are never enforced in transfer logic or any modifier. Maintained for
    //   interface compatibility and external integrator queries only.
    //   The storage slot (_validCallerCodeHashes) MUST remain to preserve
    //   proxy storage layout.
    // =========================================================================

    function isValidCaller(bytes32 queryHash_) public view returns (bool) {
        return (_validCallerCodeHashes.contains(queryHash_));
    }

    function validCallers()
        external
        view
        returns (bytes32[] memory validCallerHashes_)
    {
        return (_validCallerCodeHashes.values());
    }

    function addValidCaller(
        bytes32 newValidCallerHash_
    ) external onlyOwnerOrFactory {
        _validCallerCodeHashes.add(newValidCallerHash_);
        emit ValidCallerAdded(newValidCallerHash_);
    }

    function removeValidCaller(
        bytes32 removedValidCallerHash_
    ) external onlyOwnerOrFactory {
        _validCallerCodeHashes.remove(removedValidCallerHash_);
        emit ValidCallerRemoved(removedValidCallerHash_);
    }

    // =========================================================================
    //                    TAX CONFIGURATION
    // =========================================================================

    // [H-04] Tax rate changes are owner-only (sensitive operation)
    function setProjectTaxRecipient(
        address projectTaxRecipient_
    ) external onlyOwnerStrict {
        projectTaxRecipient = projectTaxRecipient_;
        emit ProjectTaxRecipientUpdated(projectTaxRecipient_);
    }

    function setSwapThresholdBasisPoints(
        uint16 swapThresholdBasisPoints_
    ) external onlyOwnerOrFactory {
        // [L-02] Prevent zero threshold — would trigger autoswap on every transfer
        if (swapThresholdBasisPoints_ == 0) revert SwapThresholdCannotBeZero();
        uint256 oldswapThresholdBasisPoints = swapThresholdBasisPoints;
        swapThresholdBasisPoints = swapThresholdBasisPoints_;
        emit AutoSwapThresholdUpdated(
            oldswapThresholdBasisPoints,
            swapThresholdBasisPoints_
        );
    }

    // [Audit-v2 M-01] Tax rates capped at MAX_TAX_BP (10%)
    // [H-04] Tax rate changes are owner-only (sensitive operation)
    function setProjectTaxRates(
        uint16 newProjectBuyTaxBasisPoints_,
        uint16 newProjectSellTaxBasisPoints_
    ) external onlyOwnerStrict {
        // [Audit-v2 M-01] Enforce 10% maximum tax rate cap
        if (newProjectBuyTaxBasisPoints_ > MAX_TAX_BP) revert TaxRateExceedsMaximum();
        if (newProjectSellTaxBasisPoints_ > MAX_TAX_BP) revert TaxRateExceedsMaximum();

        uint16 oldBuyTaxBasisPoints = projectBuyTaxBasisPoints;
        uint16 oldSellTaxBasisPoints = projectSellTaxBasisPoints;

        projectBuyTaxBasisPoints = newProjectBuyTaxBasisPoints_;
        projectSellTaxBasisPoints = newProjectSellTaxBasisPoints_;

        _tokenHasTax =
            (projectBuyTaxBasisPoints + projectSellTaxBasisPoints) > 0;

        emit ProjectTaxBasisPointsChanged(
            oldBuyTaxBasisPoints,
            newProjectBuyTaxBasisPoints_,
            oldSellTaxBasisPoints,
            newProjectSellTaxBasisPoints_
        );
    }

    // =========================================================================
    //                        ERC-20 VIEW FUNCTIONS
    // =========================================================================

    function name() public view virtual override returns (string memory) {
        return _name;
    }

    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    function decimals() public view virtual override returns (uint8) {
        return 18;
    }

    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    function totalBuyTaxBasisPoints() public view returns (uint256) {
        return projectBuyTaxBasisPoints;
    }

    function totalSellTaxBasisPoints() public view returns (uint256) {
        return projectSellTaxBasisPoints;
    }

    function balanceOf(
        address account
    ) public view virtual override returns (uint256) {
        return _balances[account];
    }

    // =========================================================================
    //                     ERC-20 TRANSFER FUNCTIONS
    // =========================================================================

    // [Audit-v2 H-01] Removed nonReentrant — it blocks the V2 router's transferFrom
    // callback during autoSwap, permanently breaking tax conversion. CEI pattern
    // (balance updates before _autoSwap) + _autoSwapInProgress flag provide
    // sufficient reentrancy protection. See audit report H-NEW-01.
    function transfer(
        address to,
        uint256 amount
    ) public virtual override(IERC20) returns (bool) {
        address owner = _msgSender();
        _transfer(
            owner,
            to,
            amount,
            (_isOrDetectPool(owner) || _isOrDetectPool(to))
        );
        return true;
    }

    function allowance(
        address owner,
        address spender
    ) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(
        address spender,
        uint256 amount
    ) public virtual override returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, amount);
        return true;
    }

    // [Audit-v2 H-01] Removed nonReentrant — same reason as transfer() above.
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _transfer(
            from,
            to,
            amount,
            (_isOrDetectPool(from) || _isOrDetectPool(to))
        );
        return true;
    }

    function increaseAllowance(
        address spender,
        uint256 addedValue
    ) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, allowance(owner, spender) + addedValue);
        return true;
    }

    function decreaseAllowance(
        address spender,
        uint256 subtractedValue
    ) public virtual returns (bool) {
        address owner = _msgSender();
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance < subtractedValue) {
            revert AllowanceDecreasedBelowZero();
        }
        unchecked {
            _approve(owner, spender, currentAllowance - subtractedValue);
        }
        return true;
    }

    // =========================================================================
    //                      CORE TRANSFER LOGIC
    // =========================================================================

    /**
     * @dev Internal transfer with dual-mode tax support.
     *
     * For CL pool sells: the full `amount` is delivered to the pool, and the tax
     * is debited separately from the sender's remaining balance. This ensures the
     * CL pool's balance check passes.
     *
     * For all other transfers: original V2 behavior (tax deducted from delivery).
     *
     * [H-02] _autoSwap is called AFTER balance updates to maintain CEI pattern.
     */
    function _transfer(
        address from,
        address to,
        uint256 amount,
        bool applyTax
    ) internal virtual {
        _beforeTokenTransfer(from, to, amount);

        uint256 fromBalance = _pretaxValidationAndLimits(from, to, amount);

        // Determine if this is a CL pool sell
        bool isCLSell = applyTax &&
            _tokenHasTax &&
            !_autoSwapInProgress &&
            isLiquidityPool(to) &&
            isCLPool(to) &&
            totalSellTaxBasisPoints() > 0;

        if (isCLSell) {
            // ============================================================
            // CL POOL SELL: "Debit-from-sender" tax model
            // Pool receives full `amount`. Tax debited from sender separately.
            //
            // [M-09] Note: This emits Transfer(from, to, amount) for the full
            // amount, plus Transfer(from, this, tax) for tax. V2 path emits
            // Transfer(from, to, amountMinusTax). Both are ERC-20 compliant.
            // ============================================================
            uint256 tax;
            if (projectSellTaxBasisPoints > 0) {
                tax = (amount * projectSellTaxBasisPoints) / BP_DENOM;
                // [M-03] Overflow-safe accumulation for uint128
                _safeAccumulateTax(tax);
            }

            // Sender must have enough balance for amount + tax
            uint256 totalDebit = amount + tax;
            if (fromBalance < totalDebit) {
                revert InsufficientBalanceForCLTax();
            }

            // [H-02] Effects BEFORE interactions — update balances first
            _balances[from] = fromBalance - totalDebit;
            _balances[to] += amount; // Pool receives FULL amount

            if (tax > 0) {
                _balances[address(this)] += tax;
                emit Transfer(from, address(this), tax);
            }

            emit Transfer(from, to, amount);
        } else {
            // ============================================================
            // ORIGINAL V2 BEHAVIOR: Tax deducted from delivery
            // Covers: V2 sells, all buys, non-pool transfers
            // ============================================================
            uint256 amountMinusTax = _taxProcessing(applyTax, to, from, amount);

            // [H-02] Effects BEFORE interactions — update balances first
            _balances[from] = fromBalance - amount;
            _balances[to] += amountMinusTax;

            emit Transfer(from, to, amountMinusTax);
        }

        // [H-02] Interaction AFTER effects — autoswap now happens after balance updates
        // [Audit-v2 I-03] autoSwap fires on ALL pool sells (V2 and CL), not V2 only.
        // The V2 router swap inside _swapTax will handle the token conversion.
        if (applyTax && isLiquidityPool(to)) {
            _autoSwap(from, to);
        }

        _afterTokenTransfer(from, to, amount);
    }

    // =========================================================================
    //                     PRE-TAX VALIDATION
    // =========================================================================

    function _pretaxValidationAndLimits(
        address from_,
        address to_,
        uint256 amount_
    ) internal view returns (uint256 fromBalance_) {
        if (to_ == uniswapV2Pair && from_ != address(this) && fundedDate == 0) {
            revert InitialLiquidityNotYetAdded();
        }

        if (from_ == address(0)) {
            revert TransferFromZeroAddress();
        }

        if (to_ == address(0)) {
            revert TransferToZeroAddress();
        }

        fromBalance_ = _balances[from_];

        if (fromBalance_ < amount_) {
            revert TransferAmountExceedsBalance();
        }

        return (fromBalance_);
    }

    // =========================================================================
    //                    TAX PROCESSING (V2-style, unchanged)
    // =========================================================================

    /**
     * @dev Original V2 tax processing. Used for V2 pool sells, all buys, and
     * non-pool transfers. CL pool sells are handled in _transfer() directly.
     *
     * [H-01] Removed `unchecked` block — tax is now bounds-checked at
     * setProjectTaxRates, but we remove unchecked for defense-in-depth.
     */
    function _taxProcessing(
        bool applyTax_,
        address to_,
        address from_,
        uint256 sentAmount_
    ) internal returns (uint256 amountLessTax_) {
        amountLessTax_ = sentAmount_;
        // [H-01] Removed `unchecked` block for defense-in-depth
        if (_tokenHasTax && applyTax_ && !_autoSwapInProgress) {
            uint256 tax;

            // on sell (V2 pools only — CL sells are handled in _transfer)
            if (isLiquidityPool(to_) && !isCLPool(to_) && totalSellTaxBasisPoints() > 0) {
                if (projectSellTaxBasisPoints > 0) {
                    uint256 projectTax = ((sentAmount_ *
                        projectSellTaxBasisPoints) / BP_DENOM);
                    // [M-03] Overflow-safe accumulation
                    _safeAccumulateTax(projectTax);
                    tax += projectTax;
                }
            }
            // on buy (all pool types — buy tax works the same everywhere)
            else if (
                isLiquidityPool(from_) && totalBuyTaxBasisPoints() > 0
            ) {
                if (projectBuyTaxBasisPoints > 0) {
                    uint256 projectTax = ((sentAmount_ *
                        projectBuyTaxBasisPoints) / BP_DENOM);
                    // [M-03] Overflow-safe accumulation
                    _safeAccumulateTax(projectTax);
                    tax += projectTax;
                }
            }

            if (tax > 0) {
                _balances[address(this)] += tax;
                emit Transfer(from_, address(this), tax);
                amountLessTax_ -= tax;
            }
        }
        return (amountLessTax_);
    }

    /**
     * @dev [M-03] Safe accumulation for projectTaxPendingSwap (uint128).
     * Caps at type(uint128).max instead of silently wrapping.
     * Excess tokens remain in _balances[address(this)] and can be
     * recovered via distributeTaxTokens.
     *
     * [Audit-v2 I-07] Note: If autoSwap fails repeatedly, projectTaxPendingSwap
     * can desync from actual contract balance. The sweepExcessTaxTokens()
     * function (Audit-v2 L-02) allows the owner to recover any excess.
     */
    function _safeAccumulateTax(uint256 tax_) internal {
        uint256 newPending = uint256(projectTaxPendingSwap) + tax_;
        if (newPending > type(uint128).max) {
            projectTaxPendingSwap = type(uint128).max;
        } else {
            projectTaxPendingSwap = uint128(newPending);
        }
    }

    // =========================================================================
    //                     AUTO-SWAP TAX TO PAIR TOKEN
    // =========================================================================

    function _autoSwap(address from_, address to_) internal {
        if (_tokenHasTax) {
            uint256 contractBalance = balanceOf(address(this));
            uint256 swapBalance = contractBalance;

            uint256 swapThresholdInTokens = (_totalSupply *
                swapThresholdBasisPoints) / BP_DENOM;

            if (
                _eligibleForSwap(from_, to_, swapBalance, swapThresholdInTokens)
            ) {
                _autoSwapInProgress = true;
                if (
                    swapBalance >
                    swapThresholdInTokens * MAX_SWAP_THRESHOLD_MULTIPLE
                ) {
                    swapBalance =
                        swapThresholdInTokens *
                        MAX_SWAP_THRESHOLD_MULTIPLE;
                }
                _swapTax(swapBalance, contractBalance);
                _autoSwapInProgress = false;
            }
        }
    }

    function _eligibleForSwap(
        address from_,
        address to_,
        uint256 taxBalance_,
        uint256 swapThresholdInTokens_
    ) internal view returns (bool) {
        return (taxBalance_ >= swapThresholdInTokens_ &&
            !_autoSwapInProgress &&
            !isLiquidityPool(from_) &&
            from_ != address(_uniswapRouter) &&
            to_ != address(_uniswapRouter) &&
            from_ != address(this));
    }

    /**
     * @dev [M-01] Added slippage protection via on-chain price estimation.
     * Uses getAmountsOut to estimate expected output and applies a slippage tolerance.
     * [L-03] Removed meaningless `block.timestamp + 600` deadline —
     * on L2 this provides no MEV protection. Using block.timestamp is sufficient.
     */
    function _swapTax(uint256 swapBalance_, uint256 contractBalance_) internal {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = pairToken;

        // [M-01] Calculate minimum output with slippage protection
        // [Audit-v2 M-02] If getAmountsOut fails, skip the swap entirely
        // instead of proceeding with amountOutMin=0 (which is a 100% sandwich vulnerability).
        uint256 amountOutMin;
        try _uniswapRouter.getAmountsOut(swapBalance_, path) returns (uint256[] memory amounts) {
            // Apply slippage tolerance: (100% - AUTOSWAP_SLIPPAGE_BPS%)
            amountOutMin = (amounts[1] * (BP_DENOM - AUTOSWAP_SLIPPAGE_BPS)) / BP_DENOM;
        } catch {
            // [Audit-v2 M-02] Price unavailable — skip swap to avoid zero-slippage exploit
            return;
        }

        try
            _uniswapRouter
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    swapBalance_,
                    amountOutMin,
                    path,
                    projectTaxRecipient,
                    block.timestamp  // [L-03] L2 deadline: current block is sufficient
                )
        {
            if (swapBalance_ < contractBalance_) {
                projectTaxPendingSwap -= uint128(
                    (projectTaxPendingSwap * swapBalance_) / contractBalance_
                );
            } else {
                projectTaxPendingSwap = 0;
            }
        } catch {
            emit ExternalCallError(5);
        }
    }

    /**
     * @dev Distribute accumulated tax tokens directly to the tax recipient.
     * [L-07] Restricted to owner only — prevents griefing by forcing raw distribution.
     * [Audit-v2 L-03] Reverts early if tax recipient is blacklisted.
     */
    function distributeTaxTokens() external onlyOwnerStrict {
        // [Audit-v2 L-03] Check recipient is not blacklisted before attempting transfer
        if (blacklists[projectTaxRecipient]) revert TransferToBlacklistedAddress();
        if (projectTaxPendingSwap > 0) {
            uint256 projectDistribution = projectTaxPendingSwap;
            projectTaxPendingSwap = 0;
            _transfer(
                address(this),
                projectTaxRecipient,
                projectDistribution,
                false
            );
        }
    }

    /**
     * @dev [Audit-v2 L-02] Sweep excess tax tokens stuck in contract.
     * Tokens sent directly to address(this) beyond projectTaxPendingSwap are
     * otherwise unrecoverable since withdrawERC20 blocks this token.
     */
    function sweepExcessTaxTokens() external onlyOwnerStrict {
        uint256 contractBalance = balanceOf(address(this));
        uint256 excess = contractBalance - uint256(projectTaxPendingSwap);
        if (excess > 0) {
            _transfer(address(this), projectTaxRecipient, excess, false);
        }
    }

    // =========================================================================
    //                       WITHDRAW FUNCTIONS
    // =========================================================================

    // [H-04] Withdrawals are owner-only (sensitive operation)
    function withdrawETH(uint256 amount_) external onlyOwnerStrict {
        (bool success, ) = _msgSender().call{value: amount_}("");
        if (!success) {
            revert TransferFailed();
        }
    }

    // [H-04] Withdrawals are owner-only (sensitive operation)
    function withdrawERC20(
        address token_,
        uint256 amount_
    ) external onlyOwnerStrict {
        if (token_ == address(this)) {
            revert CannotWithdrawThisToken();
        }
        IERC20(token_).safeTransfer(_msgSender(), amount_);
    }

    // =========================================================================
    //                     MINT / BURN
    // =========================================================================

    function _mint(address account, uint256 amount) internal virtual {
        if (account == address(0)) {
            revert MintToZeroAddress();
        }

        _beforeTokenTransfer(address(0), account, amount);

        // [L-05] Safe cast — maxSupply is already validated <= uint128.max in _processSupplyParams
        require(amount <= type(uint128).max, "Mint exceeds uint128");
        _totalSupply += amount;
        unchecked {
            _balances[account] += amount;
        }
        emit Transfer(address(0), account, amount);

        _afterTokenTransfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal virtual {
        if (account == address(0)) {
            revert BurnFromTheZeroAddress();
        }

        _beforeTokenTransfer(account, address(0), amount);

        uint256 accountBalance = _balances[account];
        if (accountBalance < amount) {
            revert BurnExceedsBalance();
        }

        unchecked {
            _balances[account] = accountBalance - amount;
        }
        // [L-05] Safe subtraction — _totalSupply >= amount is guaranteed since
        // _balances[account] >= amount and totalSupply >= all balances
        _totalSupply -= amount;

        emit Transfer(account, address(0), amount);

        _afterTokenTransfer(account, address(0), amount);
    }

    // =========================================================================
    //                        ALLOWANCES
    // =========================================================================

    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) internal virtual {
        if (owner == address(0)) {
            revert ApproveFromTheZeroAddress();
        }
        if (spender == address(0)) {
            revert ApproveToTheZeroAddress();
        }
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(
        address owner,
        address spender,
        uint256 amount
    ) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) {
                revert InsufficientAllowance();
            }
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }

    // =========================================================================
    //                       BURN PUBLIC
    // =========================================================================

    function burn(uint256 value) public virtual {
        _burn(_msgSender(), value);
    }

    function burnFrom(address account, uint256 value) public virtual {
        _spendAllowance(account, _msgSender(), value);
        _burn(account, value);
    }

    // =========================================================================
    //                     OWNERSHIP OVERRIDES
    // =========================================================================

    /**
     * @dev [M-07] Override renounceOwnership to revert.
     * Prevents permanently bricking all admin functions.
     */
    function renounceOwnership() public view override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    // =========================================================================
    //                         HOOKS
    // =========================================================================

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {
        // [Audit-v2 I-06] Blacklist checks now cover mint (to) and burn (from) as well,
        // future-proofing against a public mint function being added later.
        // Skip only the zero-address side of mint/burn (address(0) cannot be blacklisted).
        if (from != address(0) && blacklists[from]) {
            revert TransferFromBlacklistedAddress();
        }
        if (to != address(0) && blacklists[to]) {
            revert TransferToBlacklistedAddress();
        }
    }

    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}

    // =========================================================================
    //                         RECEIVE
    // =========================================================================

    receive() external payable {}
}
