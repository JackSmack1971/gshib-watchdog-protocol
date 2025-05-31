# GuardianShib (GSHIB) Watchdog Protocol

## Overview

The GuardianShib (GSHIB) Watchdog Protocol is a decentralized system designed to enhance blockchain ecosystem security by enabling the identification, reporting, and collective verification of potentially malicious smart contracts. The protocol centers around two core smart contracts:

1.  `GSHIBToken.sol`: An ERC20 utility token that facilitates participation, fee payments, and reward distribution within the ecosystem.
2.  `WatchdogRegistry.sol`: The main operational contract where users can report suspicious contracts and GSHIB token holders (Verifiers) can stake their tokens to vote on the validity of these reports.

The protocol aims to create a community-driven mechanism for flagging threats, incentivizing truthful participation through rewards, and penalizing malicious or negligent behavior through slashing.

## Contracts

### 1. `GSHIBToken.sol`

The `GSHIBToken` is the backbone utility token for the Watchdog Protocol.

* **Type:** ERC20 Standard Token
* **Features:**
    * **Pausable (`ERC20Pausable`):** The contract owner can pause all token transfers in critical situations, providing a safeguard mechanism.
    * **Ownable (`Ownable2Step`):** Ownership is managed through a secure two-step transfer process, requiring the prospective owner to accept ownership, thus preventing accidental transfers to incorrect addresses.
    * **Fixed Initial Supply:** The total supply of GSHIB tokens is minted once during contract deployment to a designated `initialOwner`. No further minting capabilities are included by default to maintain a predictable supply.
    * **Custom Error:** Uses `ZeroTotalSupply` for clarity if an attempt is made to deploy with no initial supply.
* **Primary Uses:**
    * Staking by Verifiers to participate in the `WatchdogRegistry`.
    * Paying fees for submitting reports to the `WatchdogRegistry`.
    * Distributing rewards to successful Reporters and diligent Verifiers.

### 2. `WatchdogRegistry.sol`

This contract is the heart of the protocol, managing the lifecycle of smart contract reporting and verification.

* **Core Functionality:** Enables a decentralized process for flagging and adjudicating the status of potentially malicious contracts.
* **Key Features:**
    * **Staking Mechanism:** Users must stake GSHIB tokens to become 'Verifiers'. A `minStakeAmount` is required for initial staking and to be eligible to vote.
    * **Reporting System:** Any address can submit a report on a `_contractToReport`, providing a `_reason` (up to `maxReasonLength`), by paying a `reportFee` in GSHIB tokens. Reports on contracts already verified as malicious are disallowed.
    * **Voting Process:** Staked Verifiers vote on submitted reports using one of three options: `Malicious`, `Safe`, or `Uncertain`. Votes must be cast before the `verificationDeadline`. A Verifier's influence (`stakeWeightAtVoteTime`) is based on their staked amount at the moment they vote. Reporters cannot vote on their own submissions.
    * **Report Finalization:** After the `verificationPeriod` ends, any address can trigger `finalizeReport`. The outcome is determined by comparing the weighted votes for `Malicious` or `Safe` against a `consensusThreshold`. Possible statuses: `Pending`, `VerifiedMalicious`, `VerifiedSafe`, `DisputedByNoConsensus`, `DisputedByNoVotes`. If a contract is `VerifiedMalicious`, it's recorded in `isEverVerifiedMalicious`.
    * **Reward System:**
        * **Reporters:** If a report leads to a `VerifiedMalicious` status, the original reporter receives a reward, calculated as `reporterRewardPercentage` of the `reportFee`.
        * **Verifiers:** Verifiers who vote correctly (i.e., `Malicious`) on a report that becomes `VerifiedMalicious` share a reward pool. This pool is funded by a `verifierRewardPoolPercentage` of the `reportFee` (net of reporter's reward). Rewards are claimed via a pull pattern (`claimRewards`).
    * **Slashing Mechanism:** Verifiers who vote `Safe` on a report that is ultimately finalized as `VerifiedMalicious` are penalized. A `slashPercentage` of their stake at the time of the vote (`stakeAtVoteTime`) is slashed. Slashed funds are transferred to the `treasuryAddress`. This is processed via `processVoteOutcome`.
    * **Treasury (`treasuryAddress`):** A designated address that collects all `reportFee`s and slashed tokens. It is also the source of funds for reporter and verifier rewards. **Critical Note:** The `treasuryAddress` must hold sufficient GSHIB tokens and must have approved the `WatchdogRegistry` contract as a spender for these tokens to successfully pay out rewards. Failed treasury transfers for reporter rewards are event-logged but do not revert finalization; failed transfers for verifier rewards will revert the claim.
    * **Pull-Over-Push Pattern:** Verifier interactions for slashing (`processVoteOutcome`) and reward claiming (`claimRewards`) are designed as pull mechanisms. This prevents `finalizeReport` from becoming too gas-intensive and gives verifiers control over when they trigger these transactions.
    * **Configurable Parameters:** The contract owner can adjust critical parameters like `reportFee`, `minStakeAmount`, `verificationPeriod`, `consensusThreshold`, reward/slash percentages, `treasuryAddress`, and `maxReasonLength` post-deployment.
    * **Security Implementations:** Inherits from OpenZeppelin's `Ownable2Step` (for access control), `Pausable` (to halt operations), and `ReentrancyGuard` (to prevent reentrancy attacks on key functions). Uses `SafeERC20` for secure token transfers.
    * **Custom Errors & Events:** Employs custom errors for gas efficiency and clear revert reasons and emits events for all significant state changes. Percentages are managed in basis points (1% = 100).

## Actors and Roles

* **Owner (`Ownable2Step`):**
    * Deploys and configures both `GSHIBToken` and `WatchdogRegistry`.
    * Manages system-wide parameters (fees, thresholds, etc.).
    * Can pause/unpause token transfers (`GSHIBToken`) and registry operations (`WatchdogRegistry`).
    * Manages ownership transfers securely.
* **Reporters:**
    * Any entity that identifies a potentially malicious smart contract.
    * Submits a report by paying the `reportFee` with GSHIB tokens.
    * Receives a reward if their report is confirmed as `VerifiedMalicious`.
* **Verifiers:**
    * GSHIB token holders who stake their tokens in the `WatchdogRegistry` to participate in the verification process.
    * Vote on the legitimacy of reported contracts.
    * Are rewarded for consensus-aligned votes on `VerifiedMalicious` reports.
    * Face slashing of their stake for voting against the consensus on `VerifiedMalicious` reports (e.g., voting `Safe` when the outcome is `Malicious`).
    * Cannot unstake tokens if they have `activeVotesCount` > 0 (i.e., unresolved votes).
* **Treasury (`treasuryAddress`):**
    * An address (EOA or contract) that serves as the financial hub for report fees, slashed tokens, and reward payouts.
    * **Must be adequately funded with GSHIB and grant allowance to the `WatchdogRegistry` contract to disburse rewards.**

## Core Workflow

1.  **Deployment & Initial Setup:**
    * Owner deploys `GSHIBToken.sol`, minting the `initialTotalSupply` to the `initialOwner`.
    * Owner deploys `WatchdogRegistry.sol`, linking the `GSHIBToken` address and setting initial operational parameters.
    * The `treasuryAddress` is funded with GSHIB tokens, and it approves the `WatchdogRegistry` contract to spend these tokens for reward payouts.
2.  **Staking (`stake`):**
    * Users stake GSHIB (>= `minStakeAmount`) to become Verifiers. Their `stakedAmount` and `activeVotesCount` are tracked.
3.  **Report Submission (`submitReport`):**
    * A Reporter pays the `reportFee` (in GSHIB, sent to `treasuryAddress`) to submit details of a `_contractToReport` and a `_reason`.
    * A new `Report` struct is created, assigned a `reportId`, and its `verificationDeadline` is set.
4.  **Voting (`voteOnReport`):**
    * Staked Verifiers cast their votes (`Malicious`, `Safe`, `Uncertain`) on the report before the `verificationDeadline`.
    * The Verifier's `stakeAtVoteTime` (current `stakedAmount`) is recorded with their vote, and their `activeVotesCount` increments.
5.  **Report Finalization (`finalizeReport`):**
    * After the `verificationDeadline` passes, anyone can call `finalizeReport`.
    * The contract tallies `maliciousStakeWeight` and `safeStakeWeight`.
    * Based on `consensusThreshold`:
        * **`VerifiedMalicious`**: Malicious votes meet threshold. Reporter is rewarded from treasury.
        * **`VerifiedSafe`**: Safe votes meet threshold.
        * **`DisputedByNoConsensus`**: Neither threshold met.
        * **`DisputedByNoVotes`**: No consensus-seeking votes were cast.
    * `ReportFinalized` event is emitted.
6.  **Post-Finalization - Verifier Actions (Pull):**
    * **`processVoteOutcome`:** Each Verifier who voted calls this.
        * Decrements `activeVotesCount` (if not already done for this report).
        * If report was `VerifiedMalicious` and Verifier voted `Safe`, their stake is slashed by `slashPercentage`, and funds go to treasury.
    * **`claimRewards`:** If report was `VerifiedMalicious` and Verifier voted `Malicious`.
        * Calculates and transfers their share of the verifier reward pool from treasury. Reverts if treasury cannot fulfill.
        * Verifier marked as financially processed to prevent double claims.
7.  **Unstaking (`unstake`):**
    * Verifiers can withdraw their entire stake if their `activeVotesCount` is 0.

## Security Considerations

Security is a paramount concern for the GuardianShib Watchdog Protocol. The following measures and patterns are employed:

* **Trusted OpenZeppelin Libraries:** Extensive use of OpenZeppelin Contracts for robust and audited implementations of:
    * `ERC20Pausable` for the token.
    * `Ownable2Step` for secure ownership management.
    * `Pausable` for emergency stops in the registry.
    * `ReentrancyGuard` to protect against common reentrancy exploits.
    * `SafeERC20` for safer token interactions, mitigating issues with some ERC20 implementations.
* **Reentrancy Protection:** All critical external functions involving state changes and potential external calls (e.g., `stake`, `unstake`, `submitReport`, `voteOnReport`, `finalizeReport`, `processVoteOutcome`, `claimRewards`) are guarded by the `nonReentrant` modifier.
* **Checks-Effects-Interactions Pattern:** Functions are generally structured to perform checks first, then apply effects (state changes), and finally interact with external contracts/addresses. This is a key pattern for preventing reentrancy. (e.g., `finalizeReport` sets `currentReport.finalized = true` before attempting reporter reward transfers).
* **Pausability:** Both contracts can be paused by their respective owners, providing a mechanism to halt activity if a vulnerability is discovered or suspected.
* **Access Control (`onlyOwner`):** Sensitive configuration functions are strictly limited to the contract owner.
* **Custom Errors:** For gas efficiency and clearer debugging, custom errors are used over string-based `require` messages.
* **Input Validation:** Rigorous checks on input parameters for addresses (non-zero), amounts (non-zero where appropriate), percentages (within bounds), and lengths.
* **Pull Payments for Rewards/Slashing:** Verifiers must actively call `claimRewards` and `processVoteOutcome`. This avoids complex, gas-heavy loops within a single transaction and shifts gas costs to individual users, enhancing system robustness.
* **Treasury Operational Security:** Explicitly notes the operational requirement for the `treasuryAddress` to be funded and to have approved the `WatchdogRegistry` for token spending. Failures in this setup can impair reward distribution.
* **Event Emission:** Comprehensive events are emitted for all significant actions, allowing for off-chain monitoring and system state tracking.

## Development & Testing

* **Solidity Version:** `^0.8.24`
* **Dependencies:** OpenZeppelin Contracts.
* **Recommendations for Robustness:**
    * **Comprehensive Test Suite:**
        * Unit tests for every function, covering all paths (happy and revert paths).
        * Fuzz testing for all functions accepting numerical inputs to uncover edge cases.
        * Invariant testing to ensure core protocol properties always hold true (e.g., total staked GSHIB in registry + treasury holdings + user balances should relate correctly to total supply after accounting for fees/rewards).
        * Integration tests simulating the full lifecycle of reports and user interactions.
    * **Static Analysis:** Regularly run tools like Slither and Mythril to automatically detect potential vulnerabilities and code quality issues.
    * **Test Coverage:** Aim for 100% test coverage on critical paths.
    * **Formal Verification:** For core invariants and high-value operations, consider formal verification.

### Deployment Steps Outline:

1.  **Deploy `GSHIBToken.sol`**:
    * Provide parameters: `initialOwner` (address), `name_` (string), `symbol_` (string), `initialTotalSupply` (uint256, ensure correct decimal precision).
    * The `initialOwner` will receive the `initialTotalSupply`.
2.  **Fund Treasury & Set Allowance**:
    * Transfer a substantial amount of GSHIB tokens to the designated `treasuryAddress`.
    * The `treasuryAddress` (or its controller) must call `approve()` on the `GSHIBToken` contract, granting an allowance to the *yet-to-be-deployed* `WatchdogRegistry` contract's future address (or update later if deploying registry first with a placeholder/deployer as temporary treasury). For simplicity, it's often easier to deploy the registry, get its address, and then set the allowance. Or use a predictable deployment address.
3.  **Deploy `WatchdogRegistry.sol`**:
    * Provide parameters:
        * `_gshibTokenAddress`: Address of the deployed `GSHIBToken`.
        * `_initialReportFee`.
        * `_initialMinStakeAmount`.
        * `_initialVerificationPeriod`.
        * `_initialConsensusThreshold` (basis points).
        * `_initialTreasuryAddress`.
        * `_initialReporterRewardPercentage` (basis points).
        * `_initialSlashPercentage` (basis points).
        * `_initialVerifierRewardPoolPercentage` (basis points).
        * `_initialMaxReasonLength`.
    * Ensure the `_initialTreasuryAddress` provided here has been funded and has set the allowance for this `WatchdogRegistry` contract on the `GSHIBToken`.
4.  **Ownership Verification**:
    * If `Ownable2Step` was used with a `pendingOwner` different from `msg.sender` during deployment, the `pendingOwner` must call `acceptOwnership()`.

## License

This project is licensed under the **MIT License**.
