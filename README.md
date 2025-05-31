# GuardianShib (GSHIB) Watchdog Protocol

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Solidity Version](https://img.shields.io/badge/Solidity-0.8.24-brightgreen)
![OpenZeppelin](https://img.shields.io/badge/uses-OpenZeppelin-9cf)
![Build Status](https://img.shields.io/badge/build-passing-brightgreen)
![Contributions](https://img.shields.io/badge/contributions-welcome-ff69b4)

A decentralized protocol designed to safeguard blockchain ecosystems by enabling the community to report, verify, and flag potentially malicious smart contracts. The protocol uses staking, rewards, and penalties to encourage active participation and honest behavior.

---

## ✨ Overview

The GuardianShib Watchdog Protocol revolves around two core smart contracts:

1. **`GSHIBToken.sol`** — An ERC20 utility token used for staking, fees, and rewards.
2. **`WatchdogRegistry.sol`** — A decentralized registry for reporting, verifying, and adjudicating smart contract safety.

By combining these contracts, the system empowers GSHIB holders (Verifiers) and community reporters to collaboratively identify and respond to security threats.

---

## 🛠️ Core Smart Contracts

### 1️⃣ `GSHIBToken.sol`

An ERC20-compliant utility token with the following features:

- **Pausable** — Emergency stop for token transfers.
- **Ownable** — Secure two-step ownership transfer.
- **Fixed Supply** — Immutable initial supply minted at deployment.
- **Utility**:
  - Staking for Verifier participation.
  - Fee payments for report submissions.
  - Rewards for active and honest participation.

### 2️⃣ `WatchdogRegistry.sol`

The central protocol contract for lifecycle management of reported smart contracts:

- **Reporting** — Submit a contract report with a reason and fee.
- **Staking & Voting** — Verifiers stake GSHIB to participate and vote (`Malicious`, `Safe`, or `Uncertain`).
- **Finalization** — Weighted vote tallies determine if the contract is `VerifiedMalicious`, `VerifiedSafe`, or `Disputed`.
- **Rewards & Slashing**:
  - Reporters rewarded if reports are confirmed as malicious.
  - Verifiers rewarded for consensus-aligned votes.
  - Slashing for Verifiers voting against consensus.
- **Treasury** — Collects fees and slashed funds, and pays out rewards.
- **Pull-Over-Push** — Rewards and slashing processed via user-initiated calls for better gas efficiency.

---

## 👥 Roles

| Role      | Description |
|-----------|-------------|
| **Owner** | Deploys, configures, and manages the protocol contracts. Can pause operations if needed. |
| **Reporters** | Submit reports for suspicious smart contracts by paying fees in GSHIB. Earn rewards for verified malicious reports. |
| **Verifiers** | Stake GSHIB to participate in report verification. Vote on reports and earn rewards for aligned votes. Face slashing for incorrect votes. |
| **Treasury** | Holds collected fees and slashed funds, and pays out rewards to Reporters and Verifiers. |

---

## 🔄 Protocol Lifecycle

1. **Deployment & Setup**  
   - Deploy `GSHIBToken` and mint initial supply.  
   - Deploy `WatchdogRegistry` with treasury and operational parameters.  
   - Fund the treasury and approve it to spend GSHIB.

2. **Staking**  
   - Verifiers stake GSHIB (`minStakeAmount`) to participate in voting.

3. **Reporting**  
   - Reporters submit a report and pay `reportFee` to flag suspicious contracts.

4. **Voting**  
   - Verifiers cast votes based on stake weight before the `verificationDeadline`.

5. **Finalization**  
   - Once the `verificationDeadline` ends, anyone can finalize the report.  
   - Outcome determined by weighted votes and `consensusThreshold`.

6. **Rewards & Slashing**  
   - Reporters and Verifiers receive rewards for aligned outcomes.  
   - Verifiers voting incorrectly are slashed.  
   - All reward and slashing actions are user-triggered (`processVoteOutcome`, `claimRewards`).

7. **Unstaking**  
   - Verifiers can withdraw if they have no active votes.

---

## 🔒 Security Considerations

- **OpenZeppelin Libraries**: Uses robust, audited implementations for token and contract security (`ERC20Pausable`, `Ownable2Step`, `Pausable`, `ReentrancyGuard`, `SafeERC20`).
- **Reentrancy Protection**: All critical functions are protected by `nonReentrant`.
- **Checks-Effects-Interactions**: Standard pattern to reduce vulnerabilities.
- **Custom Errors**: Save gas and provide clear error reasons.
- **Rigorous Input Validation**: Prevent invalid interactions.
- **Treasury Security**: Treasury must be properly funded and grant allowances for reward payouts.

---

## 🧪 Development & Testing

- **Solidity:** `^0.8.24`
- **Dependencies:** OpenZeppelin Contracts.
- **Recommended Testing:**  
  - Unit tests for all logic paths.  
  - Fuzz testing for edge cases.  
  - Invariant tests for consistency.  
  - Integration tests for end-to-end flows.  
- **Static Analysis & Formal Verification:**  
  - Use tools like Slither, Mythril.  
  - Formal verification for critical logic.

---

## 🚀 Deployment Steps

1️⃣ **Deploy `GSHIBToken.sol`**  
- Parameters: `initialOwner`, `name`, `symbol`, `initialTotalSupply`.

2️⃣ **Fund Treasury & Approve Spending**  
- Fund `treasuryAddress` with GSHIB tokens.  
- Treasury grants allowance to `WatchdogRegistry` for reward distribution.

3️⃣ **Deploy `WatchdogRegistry.sol`**  
- Parameters:  
  - `_gshibTokenAddress`  
  - `_initialReportFee`, `_initialMinStakeAmount`, `_initialVerificationPeriod`, `_initialConsensusThreshold`, `_initialTreasuryAddress`, `_initialReporterRewardPercentage`, `_initialSlashPercentage`, `_initialVerifierRewardPoolPercentage`, `_initialMaxReasonLength`.

4️⃣ **Ownership Acceptance**  
- If `Ownable2Step` is configured with a `pendingOwner`, accept ownership.

---

## 📜 License

This project is licensed under the **MIT License**.

---

**Ready to deploy?** 🚀 Let’s secure the blockchain together! 💪

---

> 📢 **Contributions and feedback are welcome!** Please feel free to open issues or pull requests. Let’s build a safer DeFi ecosystem together.
