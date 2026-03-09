// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IERC20Config.sol";
import "./IErrors.sol";

/**
 * @title IAgentTokenV3
 * @notice Interface for AgentTokenV3 — extends V2 with CL pool support.
 */
interface IAgentTokenV3 is IERC20, IERC20Config, IERC20Metadata, IErrors {
    // =========================================================================
    //                           EVENTS (from V1/V2)
    // =========================================================================

    event AutoSwapThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event ExternalCallError(uint256 identifier);
    event InitialLiquidityAdded(uint256 tokenA, uint256 tokenB, uint256 lpToken);
    event LimitsUpdated(
        uint256 oldMaxTokensPerTransaction,
        uint256 newMaxTokensPerTransaction,
        uint256 oldMaxTokensPerWallet,
        uint256 newMaxTokensPerWallet
    );
    event LiquidityPoolCreated(address addedPool);
    event LiquidityPoolAdded(address addedPool);
    event LiquidityPoolRemoved(address removedPool);
    event ProjectTaxBasisPointsChanged(
        uint256 oldBuyBasisPoints,
        uint256 newBuyBasisPoints,
        uint256 oldSellBasisPoints,
        uint256 newSellBasisPoints
    );
    event RevenueAutoSwap();
    event ProjectTaxRecipientUpdated(address treasury);
    event ValidCallerAdded(bytes32 addedValidCaller);
    event ValidCallerRemoved(bytes32 removedValidCaller);

    // =========================================================================
    //                       EVENTS (new in V3)
    // =========================================================================

    event CLPoolAdded(address indexed pool);
    event CLPoolRemoved(address indexed pool);
    event CLFactoryAdded(address indexed factory, bool isSlipstream);
    event CLFactoryRemoved(address indexed factory);
    event V2FactoryAdded(address indexed factory);
    event V2FactoryRemoved(address indexed factory);
    event PoolAutoDetected(address indexed pool, address indexed factory);

    // =========================================================================
    //                        FUNCTIONS (from V1/V2)
    // =========================================================================

    function addInitialLiquidity(address lpOwner) external;
    function isLiquidityPool(address queryAddress_) external view returns (bool);
    function liquidityPools() external view returns (address[] memory liquidityPools_);
    function addLiquidityPool(address newLiquidityPool_) external;
    function removeLiquidityPool(address removedLiquidityPool_) external;
    function isValidCaller(bytes32 queryHash_) external view returns (bool);
    function validCallers() external view returns (bytes32[] memory validCallerHashes_);
    function addValidCaller(bytes32 newValidCallerHash_) external;
    function removeValidCaller(bytes32 removedValidCallerHash_) external;
    function setProjectTaxRecipient(address projectTaxRecipient_) external;
    function setSwapThresholdBasisPoints(uint16 swapThresholdBasisPoints_) external;
    function setProjectTaxRates(uint16 newProjectBuyTaxBasisPoints_, uint16 newProjectSellTaxBasisPoints_) external;
    function totalBuyTaxBasisPoints() external view returns (uint256);
    function totalSellTaxBasisPoints() external view returns (uint256);
    function distributeTaxTokens() external;
    function sweepExcessTaxTokens() external;
    function withdrawETH(uint256 amount_) external;
    function withdrawERC20(address token_, uint256 amount_) external;
    function burn(uint256 value) external;
    function burnFrom(address account, uint256 value) external;
    function initialize(
        address[3] memory integrationAddresses_,
        bytes memory baseParams_,
        bytes memory supplyParams_,
        bytes memory taxParams_
    ) external;
    function addBlacklistAddress(address addr) external;
    function removeBlacklistAddress(address addr) external;

    // =========================================================================
    //                    FUNCTIONS (new in V3)
    // =========================================================================

    /**
     * @dev Return if an address is a concentrated liquidity pool
     */
    function isCLPool(address queryAddress_) external view returns (bool);

    /**
     * @dev Returns a list of all registered CL pools
     */
    function clPools() external view returns (address[] memory clPools_);

    /**
     * @dev Register a CL pool (adds to both LP set and CL set)
     */
    function addCLPool(address newCLPool_) external;

    /**
     * @dev Remove a CL pool (removes from both LP set and CL set)
     */
    function removeCLPool(address removedCLPool_) external;

    // =========================================================================
    //                FUNCTIONS (auto-detection, new in V3)
    // =========================================================================

    function addUniV3Factory(address factory_, uint24[] calldata feeTiers_) external;
    function addSlipstreamFactory(address factory_, int24[] calldata tickSpacings_) external;
    function addV2Factory(address factory_) external;
    function removeCLFactory(uint256 index_) external;
    function removeV2Factory(uint256 index_) external;
    function clFactoryCount() external view returns (uint256);
    function v2FactoryCount() external view returns (uint256);
    function getCLFactory(uint256 index_) external view returns (
        address factory_, bool isSlipstream_, int24[] memory tickSpacings_, uint24[] memory feeTiers_
    );
    function getV2Factory(uint256 index_) external view returns (address factory_);
    function resetNonPoolCache(address addr_) external;
}
