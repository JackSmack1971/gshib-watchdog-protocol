// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {GovernorVotesQuorumFraction} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title GSHIBGovernor
 * @notice Governance contract for the GuardianShib protocol using GSHIB tokens
 * @dev Implements decentralized governance to address centralization concerns from audit
 * Features:
 * - Token-based voting power using GSHIB tokens
 * - Configurable voting delay, voting period, and proposal threshold
 * - Quorum requirement (4% of total supply by default)
 * - Integration with TimelockController for delayed execution
 * - Protection against governance attacks through proper configuration
 */
contract GSHIBGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    // --- Events ---
    event ProposalThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event EmergencyActionExecuted(address indexed target, bytes data);

    // --- Custom Errors ---
    error InvalidProposalThreshold();
    error EmergencyActionFailed();

    // --- Constructor ---
    constructor(
        IVotes _token,
        TimelockController _timelock,
        uint256 _initialVotingDelay,    // e.g., 1 day (in blocks)
        uint256 _initialVotingPeriod,   // e.g., 1 week (in blocks)  
        uint256 _initialProposalThreshold, // e.g., 1% of total supply
        uint256 _quorumPercentage       // e.g., 4 (represents 4%)
    )
        Governor("GSHIBGovernor")
        GovernorSettings(_initialVotingDelay, _initialVotingPeriod, _initialProposalThreshold)
        GovernorVotes(_token)
        GovernorVotesQuorumFraction(_quorumPercentage)
        GovernorTimelockControl(_timelock)
    {
        // Additional validation can be added here if needed
    }

    // --- Core Governance Functions ---

    /**
     * @notice Create a new governance proposal
     * @param targets Array of target addresses to call
     * @param values Array of ETH values to send (usually 0)
     * @param calldatas Array of encoded function calls
     * @param description Human-readable description of the proposal
     * @return proposalId The ID of the created proposal
     */
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override(Governor) returns (uint256) {
        // Add any additional validation for proposals here
        return super.propose(targets, values, calldatas, description);
    }

    /**
     * @notice Create a proposal to update protocol parameters
     * @param target The WatchdogRegistry contract address
     * @param functionSig The function signature (e.g., "setReportFee(uint256)")
     * @param newValue The new parameter value
     * @param description Description of the parameter change
     */
    function proposeParameterChange(
        address target,
        string memory functionSig,
        uint256 newValue,
        string memory description
    ) external returns (uint256) {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);

        targets[0] = target;
        values[0] = 0;
        calldatas[0] = abi.encodeWithSignature(functionSig, newValue);

        return propose(targets, values, calldatas, description);
    }

    /**
     * @notice Create a proposal to update the treasury address
     * @param target The WatchdogRegistry contract address
     * @param newTreasury The new treasury address
     * @param description Description of the treasury change
     */
    function proposeTreasuryChange(
        address target,
        address newTreasury,
        string memory description
    ) external returns (uint256) {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);

        targets[0] = target;
        values[0] = 0;
        calldatas[0] = abi.encodeWithSignature("setTreasuryAddress(address)", newTreasury);

        return propose(targets, values, calldatas, description);
    }

    /**
     * @notice Create a proposal for emergency pause
     * @param target The contract to pause
     * @param description Description of why emergency pause is needed
     */
    function proposeEmergencyPause(
        address target,
        string memory description
    ) external returns (uint256) {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);

        targets[0] = target;
        values[0] = 0;
        calldatas[0] = abi.encodeWithSignature("pause()");

        return propose(targets, values, calldatas, description);
    }

    // --- Enhanced Security Features ---

    /**
     * @notice Emergency function for critical security issues (bypasses normal timelock)
     * @dev Only for extreme circumstances, requires very high threshold
     * @param target Target contract
     * @param data Encoded function call
     */
    function executeEmergencyAction(
        address target,
        bytes calldata data
    ) external {
        // Require very high voting power (e.g., 10% of total supply)
        uint256 requiredVotingPower = (token().getPastTotalSupply(block.number - 1) * 1000) / 10000; // 10%
        
        if (token().getPastVotes(msg.sender, block.number - 1) < requiredVotingPower) {
            revert EmergencyActionFailed();
        }

        // Execute the emergency action
        (bool success, ) = target.call(data);
        if (!success) {
            revert EmergencyActionFailed();
        }

        emit EmergencyActionExecuted(target, data);
    }

    // --- Configuration Functions ---

    /**
     * @notice Update the proposal threshold through governance
     * @param newProposalThreshold New threshold for creating proposals
     */
    function setProposalThreshold(uint256 newProposalThreshold) external onlyGovernance {
        uint256 oldThreshold = proposalThreshold();
        _setProposalThreshold(newProposalThreshold);
        emit ProposalThresholdUpdated(oldThreshold, newProposalThreshold);
    }

    // --- Overrides for Multiple Inheritance ---

    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    function quorum(uint256 blockNumber)
        public
        view
        override(Governor, GovernorVotesQuorumFraction)
        returns (uint256)
    {
        return super.quorum(blockNumber);
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }

    function _execute(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._execute(proposalId, targets, values, calldatas, descriptionHash);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function state(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    // --- View Functions ---

    /**
     * @notice Get voting power of an account at a specific block
     * @param account The account to check
     * @param blockNumber The block number to check at
     * @return The voting power of the account
     */
    function getVotingPower(address account, uint256 blockNumber) external view returns (uint256) {
        return token().getPastVotes(account, blockNumber);
    }

    /**
     * @notice Get the total supply of governance tokens at a specific block
     * @param blockNumber The block number to check at
     * @return The total supply at that block
     */
    function getTotalSupply(uint256 blockNumber) external view returns (uint256) {
        return token().getPastTotalSupply(blockNumber);
    }

    /**
     * @notice Check if a proposer has enough tokens to create proposals
     * @param proposer The address to check
     * @return Whether the proposer meets the threshold
     */
    function hasProposalThreshold(address proposer) external view returns (bool) {
        return token().getPastVotes(proposer, block.number - 1) >= proposalThreshold();
    }

    /**
     * @notice Get the current quorum required for proposals to pass
     * @return The current quorum amount
     */
    function getCurrentQuorum() external view returns (uint256) {
        return quorum(block.number - 1);
    }
}
