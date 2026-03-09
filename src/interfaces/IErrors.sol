// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Error definitions matching the Virtuals Protocol AgentToken contracts.
 * Only errors actually used by AgentTokenV3 are included.
 */
interface IErrors {
    error AllowanceDecreasedBelowZero();
    error ApproveFromTheZeroAddress();
    error ApproveToTheZeroAddress();
    error BurnExceedsBalance();
    error BurnFromTheZeroAddress();
    error CallerIsNotAdminNorFactory();
    error CannotWithdrawThisToken();
    error InitialLiquidityAlreadyAdded();
    error InitialLiquidityNotYetAdded();
    error InsufficientAllowance();
    error LiquidityPoolCannotBeAddressZero();
    error LiquidityPoolMustBeAContractAddress();
    error MaxSupplyTooHigh();
    error MintToZeroAddress();
    error NoTokenForLiquidityPair();
    error SupplyTotalMismatch();
    error TransferAmountExceedsBalance();
    error TransferFailed();
    error TransferFromZeroAddress();
    error TransferToZeroAddress();
    error TransferToBlacklistedAddress();
}
