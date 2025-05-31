// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol"; // For OwnableInvalidOwner error

/**
 * @title GSHIBToken
 * @notice An ERC20 token with pausable functionality to be used by the WatchdogRegistry for staking, fees, and rewards.
 * @dev Implements ERC20Pausable and Ownable2Step. Fixed initial supply minted to the initialOwner.
 * The owner can pause and unpause token transfers. Ownership is managed via a two-step process.
 */
contract GSHIBToken is ERC20Pausable, Ownable2Step {
    // --- Custom Errors ---
    error ZeroTotalSupply(); // Custom error for gas efficiency

    /**
     * @notice Constructor to create the GSHIB token.
     * @param initialOwner The address that will receive the initial total supply and become the contract owner
     * (after accepting ownership via Ownable2Step).
     * @param name_ The name of the token (e.g., "GSHIB Token").
     * @param symbol_ The symbol of the token (e.g., "GSHIB").
     * @param initialTotalSupply The total amount of tokens to be minted, expressed in the smallest unit
     * (e.g., wei for 18 decimals). Ensure this value accounts for the desired
     * number of decimal places. For 1,000,000 tokens with 18 decimals,
     * pass 1000000 * (10**18).
     */
    constructor(
        address initialOwner,
        string memory name_,
        string memory symbol_,
        uint256 initialTotalSupply
    )
        ERC20(name_, symbol_) // Initialize ERC20 basic properties
        Ownable2Step(initialOwner) // Initialize Ownable2Step, setting initialOwner as pending owner or direct owner
    {
        // --- Checks ---
        // The check for initialOwner == address(0) is handled by Ownable's constructor,
        // which will revert with OwnableInvalidOwner(address(0)).

        if (initialTotalSupply == 0) {
            revert ZeroTotalSupply();
        }

        // --- Effects ---
        // Mint the initial total supply to the initialOwner's address.
        _mint(initialOwner, initialTotalSupply);

        // Note on ownership:
        // Ownable2Step(initialOwner) in the inheritance list means:
        // - If initialOwner is msg.sender, msg.sender becomes the owner immediately.
        // - If initialOwner is not msg.sender, initialOwner becomes the pending owner,
        //   and msg.sender is the initial owner until initialOwner calls acceptOwnership().
        // For a typical deployment where the deployer sets up another address as owner,
        // the deployer (msg.sender) will be the first owner, and will then need to call
        // `transferOwnership(initialOwner)` on the deployed contract, after which `initialOwner`
        // calls `acceptOwnership()`.
        // If the intent is for `initialOwner` specified in constructor to be the one who has to accept,
        // and `msg.sender` (deployer) to be the one who can renounce ownership immediately after deployment if needed,
        // then `Ownable2Step(msg.sender)` should be called, followed by `transferOwnership(initialOwner);` in the constructor body.
        // However, if `initialOwner` _is_ the intended first owner (potentially deployer itself or a designated EOA/multisig),
        // `Ownable2Step(initialOwner)` correctly sets them as the owner (if `initialOwner == msg.sender`) or pending owner.
        // The provided `Ownable2Step(initialOwner)` directly sets `initialOwner` as the target for ownership.
        // If `initialOwner` is not the `msg.sender`, they will need to call `acceptOwnership()`. `msg.sender` will be temporary owner.
        // This is a common setup.
    }

    /**
     * @notice Pauses all token transfers.
     * @dev Can only be called by the current owner (after ownership transfer is accepted, if applicable).
     * This function utilizes the _pause() internal function from OpenZeppelin's Pausable contract.
     * Emits a {Paused} event.
     * Requirements:
     * - The contract must not be paused.
     * - Caller must be the owner.
     */
    function pause() public virtual onlyOwner {
        _pause(); // Internal Pausable function
    }

    /**
     * @notice Unpauses all token transfers.
     * @dev Can only be called by the current owner.
     * This function utilizes the _unpause() internal function from OpenZeppelin's Pausable contract.
     * Emits an {Unpaused} event.
     * Requirements:
     * - The contract must be paused.
     * - Caller must be the owner.
     */
    function unpause() public virtual onlyOwner {
        _unpause(); // Internal Pausable function
    }

    /**
     * @dev The ERC20 standard typically uses 18 decimals.
     * OpenZeppelin's ERC20 implementation defaults to 18 decimals.
     * If a different number of decimals is required, you can override the `decimals()` function:
     * function decimals() public view virtual override returns (uint8) {
     * return YOUR_DESIRED_DECIMALS; // e.g., 6
     * }
     * However, for consistency with common DeFi practices, 18 is recommended unless
     * there's a specific reason for another value. The `WatchdogRegistry` does not
     * impose a specific decimal requirement other than what's standard for ERC20 interactions.
     */

    // No additional minting functions are provided by default to ensure a fixed total supply
    // after initial minting. If minting capabilities are needed post-deployment,
    // an `onlyOwner` mint function would need to be added, along with careful consideration
    // of supply cap management.

    // No burning functions are provided by default. If burning is desired,
    // consider using OpenZeppelin's `ERC20Burnable.sol` extension.
}