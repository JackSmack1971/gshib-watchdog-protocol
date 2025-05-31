// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/**
 * @title EnhancedGSHIBToken
 * @notice Enhanced GSHIB token with governance capabilities and security improvements
 * @dev Implements:
 * - ERC20Votes for governance participation
 * - ERC20Permit for gasless approvals
 * - Enhanced pausable functionality with timelock integration
 * - Transfer restrictions and anti-manipulation features
 * - Upgradeable design considerations
 */
contract EnhancedGSHIBToken is ERC20, ERC20Pausable, ERC20Permit, ERC20Votes, Ownable2Step {
    
    // --- Custom Errors ---
    error ZeroTotalSupply();
    error InvalidAddress();
    error TransferToZeroAddress();
    error TransferExceedsBalance();
    error OnlyTimelock();
    error TransferAmountTooLarge();
    error TooManyTransfersInBlock();

    // --- Events ---
    event TimelockUpdated(address indexed oldTimelock, address indexed newTimelock);
    event MaxTransferPercentUpdated(uint256 oldPercent, uint256 newPercent);
    event AntiWhaleEnabled(bool enabled);
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
    event DelegateVotesChanged(address indexed delegate, uint256 previousBalance, uint256 newBalance);

    // --- State Variables ---
    address public timelockController;
    
    // Anti-manipulation features
    uint256 public maxTransferPercent; // Max % of total supply that can be transferred in one tx
    bool public antiWhaleEnabled;
    mapping(address => uint256) public transfersInBlock;
    mapping(address => uint256) public lastTransferBlock;
    uint256 public constant MAX_TRANSFERS_PER_BLOCK = 5;

    // Governance participation tracking
    mapping(address => bool) public hasEverDelegated;
    uint256 public totalDelegated; // Track how many tokens are actively delegated

    // --- Modifiers ---
    modifier onlyTimelock() {
        if (msg.sender != timelockController && timelockController != address(0)) {
            revert OnlyTimelock();
        }
        _;
    }

    modifier onlyOwnerOrTimelock() {
        if (msg.sender != owner() && msg.sender != timelockController) {
            revert OnlyTimelock();
        }
        _;
    }

    /**
     * @notice Constructor for EnhancedGSHIBToken
     * @param initialOwner The address that will receive the initial total supply and become the contract owner
     * @param name_ The name of the token (e.g., "Enhanced GSHIB Token")
     * @param symbol_ The symbol of the token (e.g., "GSHIB")
     * @param initialTotalSupply The total amount of tokens to be minted
     * @param _timelockController Address of the timelock controller for governance
     */
    constructor(
        address initialOwner,
        string memory name_,
        string memory symbol_,
        uint256 initialTotalSupply,
        address _timelockController
    )
        ERC20(name_, symbol_)
        ERC20Permit(name_)
        Ownable2Step(initialOwner)
    {
        // Validation
        if (initialOwner == address(0)) revert InvalidAddress();
        if (initialTotalSupply == 0) revert ZeroTotalSupply();

        // Set timelock (can be zero initially)
        timelockController = _timelockController;

        // Initialize anti-whale protection (5% of total supply max transfer)
        maxTransferPercent = 500; // 5% in basis points
        antiWhaleEnabled = true;

        // Mint initial supply
        _mint(initialOwner, initialTotalSupply);

        // Auto-delegate to self for governance participation
        _delegate(initialOwner, initialOwner);
        hasEverDelegated[initialOwner] = true;
        totalDelegated += initialTotalSupply;
    }

    // --- Governance Configuration ---

    /**
     * @notice Set the timelock controller address
     * @param _newTimelock New timelock controller address
     */
    function setTimelockController(address _newTimelock) external onlyOwner {
        address oldTimelock = timelockController;
        timelockController = _newTimelock;
        emit TimelockUpdated(oldTimelock, _newTimelock);
    }

    /**
     * @notice Enable or disable anti-whale protection
     * @param _enabled Whether anti-whale protection should be enabled
     */
    function setAntiWhaleEnabled(bool _enabled) external onlyTimelock {
        antiWhaleEnabled = _enabled;
        emit AntiWhaleEnabled(_enabled);
    }

    /**
     * @notice Set maximum transfer percentage
     * @param _newPercent New maximum transfer percentage in basis points
     */
    function setMaxTransferPercent(uint256 _newPercent) external onlyTimelock {
        require(_newPercent <= 10000, "Percent cannot exceed 100%");
        uint256 oldPercent = maxTransferPercent;
        maxTransferPercent = _newPercent;
        emit MaxTransferPercentUpdated(oldPercent, _newPercent);
    }

    // --- Enhanced Transfer Logic ---

    /**
     * @dev Override transfer to include anti-manipulation checks
     */
    function _update(address from, address to, uint256 amount) internal override(ERC20, ERC20Pausable, ERC20Votes) {
        // Call parent implementations
        super._update(from, to, amount);

        // Apply anti-manipulation checks for non-mint/burn operations
        if (from != address(0) && to != address(0)) {
            _applyAntiManipulationChecks(from, to, amount);
        }
    }

    /**
     * @dev Apply anti-manipulation checks
     */
    function _applyAntiManipulationChecks(address from, address to, uint256 amount) internal {
        if (!antiWhaleEnabled) return;

        // Check max transfer amount (anti-whale)
        if (maxTransferPercent > 0) {
            uint256 maxTransferAmount = (totalSupply() * maxTransferPercent) / 10000;
            if (amount > maxTransferAmount) {
                revert TransferAmountTooLarge();
            }
        }

        // Check transfer frequency (anti-spam/manipulation)
        if (lastTransferBlock[from] == block.number) {
            transfersInBlock[from]++;
            if (transfersInBlock[from] > MAX_TRANSFERS_PER_BLOCK) {
                revert TooManyTransfersInBlock();
            }
        } else {
            transfersInBlock[from] = 1;
            lastTransferBlock[from] = block.number;
        }
    }

    // --- Enhanced Governance Features ---

    /**
     * @dev Override delegate to track participation
     */
    function _delegate(address delegator, address delegatee) internal override {
        address currentDelegate = delegates(delegator);
        
        // Update delegation tracking
        if (!hasEverDelegated[delegator] && delegatee != address(0)) {
            hasEverDelegated[delegator] = true;
            totalDelegated += balanceOf(delegator);
        }
        
        super._delegate(delegator, delegatee);
    }

    /**
     * @notice Get governance participation rate
     * @return Percentage of tokens actively delegated (in basis points)
     */
    function getParticipationRate() external view returns (uint256) {
        if (totalSupply() == 0) return 0;
        return (totalDelegated * 10000) / totalSupply();
    }

    /**
     * @notice Delegate votes to another address
     * @param delegatee Address to delegate votes to
     */
    function delegate(address delegatee) public override {
        if (!hasEverDelegated[msg.sender] && delegatee != address(0)) {
            hasEverDelegated[msg.sender] = true;
            totalDelegated += balanceOf(msg.sender);
        }
        super.delegate(delegatee);
    }

    /**
     * @notice Delegate votes using a signature
     * @param delegatee Address to delegate votes to
     * @param nonce Nonce for the signature
     * @param expiry Expiry timestamp for the signature
     * @param v Signature component
     * @param r Signature component
     * @param s Signature component
     */
    function delegateBySig(
        address delegatee,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public override {
        super.delegateBySig(delegatee, nonce, expiry, v, r, s);
    }

    // --- Pausable Functions ---

    /**
     * @notice Pause all token transfers (emergency only)
     * @dev Can be called by owner or timelock
     */
    function pause() public onlyOwnerOrTimelock {
        _pause();
    }

    /**
     * @notice Unpause all token transfers
     * @dev Can be called by owner or timelock
     */
    function unpause() public onlyOwnerOrTimelock {
        _unpause();
    }

    // --- View Functions ---

    /**
     * @notice Check if an address has ever participated in governance
     * @param account Address to check
     * @return Whether the address has ever delegated votes
     */
    function hasParticipatedInGovernance(address account) external view returns (bool) {
        return hasEverDelegated[account];
    }

    /**
     * @notice Get the maximum transfer amount currently allowed
     * @return Maximum transfer amount in tokens
     */
    function getMaxTransferAmount() external view returns (uint256) {
        if (!antiWhaleEnabled || maxTransferPercent == 0) {
            return totalSupply();
        }
        return (totalSupply() * maxTransferPercent) / 10000;
    }

    /**
     * @notice Get transfer information for an address in current block
     * @param account Address to check
     * @return transferCount Number of transfers in current block
     * @return canTransfer Whether the account can make more transfers this block
     */
    function getTransferInfo(address account) external view returns (uint256 transferCount, bool canTransfer) {
        if (lastTransferBlock[account] == block.number) {
            transferCount = transfersInBlock[account];
            canTransfer = transferCount < MAX_TRANSFERS_PER_BLOCK;
        } else {
            transferCount = 0;
            canTransfer = true;
        }
    }

    // --- Required Overrides ---

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    function _increaseBalance(address account, uint256 value) internal override(ERC20, ERC20Votes) {
        super._increaseBalance(account, value);
    }

    // --- Emergency Functions ---

    /**
     * @notice Emergency function to recover accidentally sent tokens
     * @param token Address of the token to recover (cannot be this token)
     * @param amount Amount to recover
     */
    function emergencyTokenRecovery(address token, uint256 amount) external onlyOwner {
        require(token != address(this), "Cannot recover own token");
        IERC20(token).transfer(owner(), amount);
    }

    /**
     * @notice Get contract version for upgrade tracking
     * @return Version string
     */
    function version() external pure returns (string memory) {
        return "2.0.0";
    }
}
