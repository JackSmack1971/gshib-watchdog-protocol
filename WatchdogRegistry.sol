// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WatchdogRegistry
 * @notice A decentralized registry for flagging and verifying potentially malicious smart contracts.
 * @dev GSHIB token holders stake to participate as verifiers.
 * Employs checks-effects-interactions, access control, and reentrancy guards.
 * All percentages are represented in basis points (e.g., 1% = 100, 100% = 10000).
 * Uses stakeAtVoteTime for fair reward/slashing.
 * Implements pull-over-push for processing report outcomes by verifiers to avoid gas limits.
 * Critical Operational Note: The `treasuryAddress` must hold sufficient GSHIB tokens
 * AND must have approved this WatchdogRegistry contract as a spender for those tokens
 * to successfully pay out reporter and verifier rewards. Failed treasury transfers
 * are event-logged but do not revert core finalization logic for reporter rewards,
 * but will revert for verifier reward claims.
 */
contract WatchdogRegistry is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Custom Errors ---
    error InvalidAddress();
    error NotStakenOrInsufficientStake();
    error NotStaked();
    error ReportNotFound();
    error AlreadyVoted();
    error VotingPeriodOver();
    error VotingPeriodNotOver();
    error ReportNotFinalized();
    error InvalidVoteOption();
    error NothingToClaim();
    error MinStakeNotMet();
    error ReportAlreadyFinalized();
    error CannotUnstakeWithActiveVotes();
    error InvalidThreshold();
    error ReporterCannotVoteOnOwnReport();
    error ReportReasonTooLong();
    error VoteRecordNotFound();
    error RewardsNotFundedByTreasury();
    error InvalidRewardPercentage();
    error ReportFeeIsZero();
    error InvalidStakeAmount();
    error ContractAlreadyVerifiedMalicious();
    error InvalidVerificationPeriod();
    error InvalidMaxReasonLength();
    error MinStakeCannotBeZero();


    // --- Events ---
    event ReportSubmitted(uint256 indexed reportId, address indexed reporter, address indexed reportedContract, string reason, uint256 submissionTimestamp, uint256 verificationDeadline);
    event Staked(address indexed verifier, uint256 amountAdded, uint256 newTotalStake);
    event Unstaked(address indexed verifier, uint256 amount);
    event Voted(uint256 indexed reportId, address indexed verifier, VoteOption vote, uint256 stakeWeightAtVoteTime);
    event ReportFinalized(uint256 indexed reportId, ReportStatus status, uint256 maliciousStakeWeight, uint256 safeStakeWeight, uint256 uncertainStakeWeight);
    event RewardsClaimed(address indexed user, uint256 reportId, uint256 rewardAmount);
    event ReporterRewardPaid(uint256 indexed reportId, address indexed reporter, uint256 rewardAmount);
    event Slashed(address indexed verifier, uint256 reportId, uint256 amountSlashed);
    event MinStakeAmountUpdated(uint256 newMinStakeAmount);
    event ReportFeeUpdated(uint256 newReportFee);
    event VerificationPeriodUpdated(uint256 newVerificationPeriod);
    event ConsensusThresholdUpdated(uint256 newConsensusThreshold);
    event TreasuryAddressUpdated(address newTreasuryAddress);
    event MaxReasonLengthUpdated(uint256 newMaxReasonLength);
    event ReporterRewardPercentageUpdated(uint256 newPercentage);
    event SlashPercentageUpdated(uint256 newPercentage);
    event VerifierRewardPoolPercentageUpdated(uint256 newPercentage);
    event VerifierVoteOutcomeProcessed(uint256 indexed reportId, address indexed verifier, bool activeCountDecremented, bool wasSlashed, uint256 slashAmount);
    event ReporterRewardTransferFailed(uint256 indexed reportId, address indexed reporter, uint256 amount);


    // --- Structs ---
    enum VoteOption { None, Malicious, Safe, Uncertain }
    enum ReportStatus { Pending, VerifiedMalicious, VerifiedSafe, DisputedByNoConsensus, DisputedByNoVotes }

    struct VoteRecord {
        VoteOption vote;
        uint256 stakeAtVoteTime;
    }

    struct Report {
        address reporter;
        address reportedContract;
        string reason;
        uint256 submissionTimestamp;
        uint256 verificationDeadline;
        mapping(address => VoteRecord) voteRecordsByVerifier;
        uint256 maliciousStakeWeight;
        uint256 safeStakeWeight;
        uint256 uncertainStakeWeight;
        ReportStatus status;
        bool finalized;
        mapping(address => bool) financiallyProcessedVerifiers;
    }

    struct Verifier {
        uint256 stakedAmount;
        uint256 activeVotesCount;
    }

    // --- State Variables ---
    IERC20 public immutable GSHIB_TOKEN;

    uint256 public reportFee;
    uint256 public minStakeAmount;
    uint256 public verificationPeriod;
    uint256 public consensusThreshold;
    uint256 public reporterRewardPercentage;
    uint256 public slashPercentage;
    uint256 public verifierRewardPoolPercentage;
    uint256 public maxReasonLength;

    mapping(address => Verifier) public verifiersData;
    mapping(uint256 => Report) public reports;
    uint256 public reportCounter;

    mapping(address => bool) public isEverVerifiedMalicious;
    address public treasuryAddress;

    mapping(uint256 => mapping(address => bool)) public activeVoteCountAdjustedForReport;


    // --- Constants ---
    uint256 private constant BASIS_POINTS_MAX = 10000;

    // --- Constructor ---
    constructor(
        address _gshibTokenAddress,
        uint256 _initialReportFee,
        uint256 _initialMinStakeAmount,
        uint256 _initialVerificationPeriod,
        uint256 _initialConsensusThreshold,
        address _initialTreasuryAddress,
        uint256 _initialReporterRewardPercentage,
        uint256 _initialSlashPercentage,
        uint256 _initialVerifierRewardPoolPercentage,
        uint256 _initialMaxReasonLength
    ) {
        if (_gshibTokenAddress == address(0)) revert InvalidAddress();
        if (_initialTreasuryAddress == address(0)) revert InvalidAddress();
        if (_initialConsensusThreshold == 0 || _initialConsensusThreshold > BASIS_POINTS_MAX) revert InvalidThreshold();
        if (_initialReporterRewardPercentage > BASIS_POINTS_MAX) revert InvalidRewardPercentage();
        if (_initialSlashPercentage > BASIS_POINTS_MAX) revert InvalidRewardPercentage();
        if (_initialVerifierRewardPoolPercentage > BASIS_POINTS_MAX) revert InvalidRewardPercentage();
        if (_initialVerificationPeriod == 0) revert InvalidVerificationPeriod();
        if (_initialMaxReasonLength == 0) revert InvalidMaxReasonLength();
        if (_initialMinStakeAmount == 0) revert MinStakeCannotBeZero();

        GSHIB_TOKEN = IERC20(_gshibTokenAddress);
        reportFee = _initialReportFee;
        minStakeAmount = _initialMinStakeAmount;
        verificationPeriod = _initialVerificationPeriod;
        consensusThreshold = _initialConsensusThreshold;
        treasuryAddress = _initialTreasuryAddress;
        reporterRewardPercentage = _initialReporterRewardPercentage;
        slashPercentage = _initialSlashPercentage;
        verifierRewardPoolPercentage = _initialVerifierRewardPoolPercentage;
        maxReasonLength = _initialMaxReasonLength;
        reportCounter = 1;
    }

    // --- Configuration Functions (Owner Controlled) ---
    function setReportFee(uint256 _newFee) external onlyOwner {
        reportFee = _newFee;
        emit ReportFeeUpdated(_newFee);
    }

    function setMinStakeAmount(uint256 _newMinStake) external onlyOwner {
        if (_newMinStake == 0) revert MinStakeCannotBeZero();
        minStakeAmount = _newMinStake;
        emit MinStakeAmountUpdated(_newMinStake);
    }

    function setVerificationPeriod(uint256 _newPeriod) external onlyOwner {
        if (_newPeriod == 0) revert InvalidVerificationPeriod();
        verificationPeriod = _newPeriod;
        emit VerificationPeriodUpdated(_newPeriod);
    }

    function setConsensusThreshold(uint256 _newThreshold) external onlyOwner {
        if (_newThreshold == 0 || _newThreshold > BASIS_POINTS_MAX) revert InvalidThreshold();
        consensusThreshold = _newThreshold;
        emit ConsensusThresholdUpdated(_newThreshold);
    }

    function setTreasuryAddress(address _newTreasury) external onlyOwner {
        if (_newTreasury == address(0)) revert InvalidAddress();
        treasuryAddress = _newTreasury;
        emit TreasuryAddressUpdated(_newTreasury);
    }

    function setReporterRewardPercentage(uint256 _newPercentage) external onlyOwner {
        if (_newPercentage > BASIS_POINTS_MAX) revert InvalidRewardPercentage();
        reporterRewardPercentage = _newPercentage;
        emit ReporterRewardPercentageUpdated(_newPercentage);
    }

    function setSlashPercentage(uint256 _newPercentage) external onlyOwner {
        if (_newPercentage > BASIS_POINTS_MAX) revert InvalidRewardPercentage();
        slashPercentage = _newPercentage;
        emit SlashPercentageUpdated(_newPercentage);
    }

    function setVerifierRewardPoolPercentage(uint256 _newPercentage) external onlyOwner {
        if (_newPercentage > BASIS_POINTS_MAX) revert InvalidRewardPercentage();
        verifierRewardPoolPercentage = _newPercentage;
        emit VerifierRewardPoolPercentageUpdated(_newPercentage);
    }

    function setMaxReasonLength(uint256 _newMaxReasonLength) external onlyOwner {
        if (_newMaxReasonLength == 0) revert InvalidMaxReasonLength();
        maxReasonLength = _newMaxReasonLength;
        emit MaxReasonLengthUpdated(_newMaxReasonLength);
    }

    // --- Staking Functions ---
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidStakeAmount();
        Verifier storage verifier = verifiersData[msg.sender];
        if (verifier.stakedAmount == 0 && amount < minStakeAmount) revert MinStakeNotMet();
        
        verifier.stakedAmount += amount;
        GSHIB_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount, verifier.stakedAmount);
    }

    function unstake() external nonReentrant whenNotPaused {
        Verifier storage verifier = verifiersData[msg.sender];
        uint256 amountToReturn = verifier.stakedAmount;

        if (amountToReturn == 0) revert NotStaked();
        if (verifier.activeVotesCount > 0) revert CannotUnstakeWithActiveVotes();

        verifier.stakedAmount = 0;
        GSHIB_TOKEN.safeTransfer(msg.sender, amountToReturn);
        emit Unstaked(msg.sender, amountToReturn);
    }

    // --- Reporting Functions ---
    function submitReport(address _contractToReport, string calldata _reason) external nonReentrant whenNotPaused returns (uint256 reportId) {
        if (_contractToReport == address(0)) revert InvalidAddress();
        if (bytes(_reason).length > maxReasonLength) revert ReportReasonTooLong();
        if (isEverVerifiedMalicious[_contractToReport]) revert ContractAlreadyVerifiedMalicious();
        if (reportFee == 0) revert ReportFeeIsZero();
        
        reportId = reportCounter;
        Report storage newReport = reports[reportId];
        newReport.reporter = msg.sender;
        newReport.reportedContract = _contractToReport;
        newReport.reason = _reason;
        newReport.submissionTimestamp = block.timestamp;
        newReport.verificationDeadline = block.timestamp + verificationPeriod;
        newReport.status = ReportStatus.Pending;
        newReport.finalized = false;
        reportCounter++;

        GSHIB_TOKEN.safeTransferFrom(msg.sender, treasuryAddress, reportFee);
        emit ReportSubmitted(reportId, msg.sender, _contractToReport, _reason, newReport.submissionTimestamp, newReport.verificationDeadline);
        return reportId;
    }

    // --- Voting Functions ---
    function voteOnReport(uint256 _reportId, VoteOption _vote) external nonReentrant whenNotPaused {
        Verifier storage verifier = verifiersData[msg.sender];
        Report storage currentReport = reports[_reportId];
        uint256 stakeAtVoteTime = verifier.stakedAmount;

        if (currentReport.reporter == address(0)) revert ReportNotFound();
        if (stakeAtVoteTime < minStakeAmount) revert NotStakenOrInsufficientStake();
        if (currentReport.reporter == msg.sender) revert ReporterCannotVoteOnOwnReport();
        if (block.timestamp > currentReport.verificationDeadline) revert VotingPeriodOver();
        if (currentReport.voteRecordsByVerifier[msg.sender].stakeAtVoteTime > 0) revert AlreadyVoted();
        if (uint8(_vote) == 0 || uint8(_vote) > 3) revert InvalidVoteOption();

        currentReport.voteRecordsByVerifier[msg.sender] = VoteRecord(_vote, stakeAtVoteTime);

        if (_vote == VoteOption.Malicious) {
            currentReport.maliciousStakeWeight += stakeAtVoteTime;
        } else if (_vote == VoteOption.Safe) {
            currentReport.safeStakeWeight += stakeAtVoteTime;
        } else { // VoteOption.Uncertain
            currentReport.uncertainStakeWeight += stakeAtVoteTime;
        }

        verifier.activeVotesCount++;
        emit Voted(_reportId, msg.sender, _vote, stakeAtVoteTime);
    }

    // --- Finalization ---
    function finalizeReport(uint256 _reportId) external whenNotPaused nonReentrant {
        Report storage currentReport = reports[_reportId];

        if (currentReport.reporter == address(0)) revert ReportNotFound();
        if (block.timestamp <= currentReport.verificationDeadline) revert VotingPeriodNotOver();
        if (currentReport.finalized) revert ReportAlreadyFinalized();

        currentReport.finalized = true;
        uint256 totalConsensusSeekingStake = currentReport.maliciousStakeWeight + currentReport.safeStakeWeight;

        if (totalConsensusSeekingStake == 0) {
            currentReport.status = ReportStatus.DisputedByNoVotes;
        } else if ((currentReport.maliciousStakeWeight * BASIS_POINTS_MAX) / totalConsensusSeekingStake >= consensusThreshold) {
            currentReport.status = ReportStatus.VerifiedMalicious;
            isEverVerifiedMalicious[currentReport.reportedContract] = true;

            if (reporterRewardPercentage > 0 && currentReport.reporter != address(0) && reportFee > 0) {
                uint256 reporterReward = (reportFee * reporterRewardPercentage) / BASIS_POINTS_MAX;
                if (reporterReward > 0) {
                    try GSHIB_TOKEN.safeTransferFrom(treasuryAddress, currentReport.reporter, reporterReward) {
                        emit ReporterRewardPaid(_reportId, currentReport.reporter, reporterReward);
                    } catch {
                        emit ReporterRewardTransferFailed(_reportId, currentReport.reporter, reporterReward);
                    }
                }
            }
        } else if ((currentReport.safeStakeWeight * BASIS_POINTS_MAX) / totalConsensusSeekingStake >= consensusThreshold) {
            currentReport.status = ReportStatus.VerifiedSafe;
        } else {
            currentReport.status = ReportStatus.DisputedByNoConsensus;
        }

        emit ReportFinalized(_reportId, currentReport.status, currentReport.maliciousStakeWeight, currentReport.safeStakeWeight, currentReport.uncertainStakeWeight);
    }

    // --- Post-Finalization Processing by Verifiers (Pull Pattern) ---
    function processVoteOutcome(uint256 _reportId) external nonReentrant whenNotPaused {
        Report storage currentReport = reports[_reportId];
        Verifier storage verifier = verifiersData[msg.sender];
        VoteRecord memory voterRecord = currentReport.voteRecordsByVerifier[msg.sender];

        if (!currentReport.finalized) revert ReportNotFinalized();
        if (voterRecord.stakeAtVoteTime == 0) revert VoteRecordNotFound();

        bool countAdjusted = false;
        bool slashed = false;
        uint256 slashAmount = 0;

        if (!activeVoteCountAdjustedForReport[_reportId][msg.sender]) {
            if (verifier.activeVotesCount > 0) {
                verifier.activeVotesCount--;
            }
            activeVoteCountAdjustedForReport[_reportId][msg.sender] = true;
            countAdjusted = true;
        }

        if (!currentReport.financiallyProcessedVerifiers[msg.sender]) {
            if (currentReport.status == ReportStatus.VerifiedMalicious && slashPercentage > 0) {
                if (voterRecord.vote == VoteOption.Safe) {
                    // uint256 stakeAtTimeOfVote = voterRecord.stakeAtVoteTime; // Redundant, already in voterRecord
                    // The check `if (stakeAtTimeOfVote > 0)` was removed here as `voterRecord.stakeAtVoteTime` is guaranteed > 0 by `VoteRecordNotFound`
                    slashAmount = (voterRecord.stakeAtVoteTime * slashPercentage) / BASIS_POINTS_MAX;
                    if (slashAmount > 0) {
                        if (slashAmount > verifier.stakedAmount) {
                            slashAmount = verifier.stakedAmount;
                        }
                        verifier.stakedAmount -= slashAmount;
                        currentReport.financiallyProcessedVerifiers[msg.sender] = true;
                        slashed = true;
                        GSHIB_TOKEN.safeTransfer(treasuryAddress, slashAmount);
                        emit Slashed(msg.sender, _reportId, slashAmount);
                    }
                }
            }
        }
        emit VerifierVoteOutcomeProcessed(_reportId, msg.sender, countAdjusted, slashed, slashAmount);
    }

    // --- Claiming Rewards (Pull Pattern) ---
    function claimRewards(uint256 _reportId) external nonReentrant whenNotPaused {
        Report storage currentReport = reports[_reportId];
        VoteRecord memory userVoteRecord = currentReport.voteRecordsByVerifier[msg.sender];

        if (currentReport.reporter == address(0)) revert ReportNotFound();
        if (!currentReport.finalized) revert ReportNotFinalized();
        if (userVoteRecord.stakeAtVoteTime == 0) revert VoteRecordNotFound();
        if (currentReport.financiallyProcessedVerifiers[msg.sender]) revert NothingToClaim();

        uint256 rewardAmount = 0;

        if (currentReport.status == ReportStatus.VerifiedMalicious && userVoteRecord.vote == VoteOption.Malicious) {
            if (reportFee > 0 && verifierRewardPoolPercentage > 0 && currentReport.maliciousStakeWeight > 0) {
                uint256 poolNumerator = BASIS_POINTS_MAX - reporterRewardPercentage;
                uint256 basePoolForVerifiers = (reportFee * poolNumerator) / BASIS_POINTS_MAX;
                uint256 actualVerifierRewardPool = (basePoolForVerifiers * verifierRewardPoolPercentage) / BASIS_POINTS_MAX;
                
                if (actualVerifierRewardPool > 0) {
                    rewardAmount = (userVoteRecord.stakeAtVoteTime * actualVerifierRewardPool) / currentReport.maliciousStakeWeight;
                }
            }
        }

        if (rewardAmount == 0) revert NothingToClaim();

        currentReport.financiallyProcessedVerifiers[msg.sender] = true;

        try GSHIB_TOKEN.safeTransferFrom(treasuryAddress, msg.sender, rewardAmount) {
            emit RewardsClaimed(msg.sender, _reportId, rewardAmount);
        } catch {
            currentReport.financiallyProcessedVerifiers[msg.sender] = false;
            revert RewardsNotFundedByTreasury();
        }
    }

    // --- View Functions ---
    function getReportDetails(uint256 _reportId) external view returns (
        address reporter,
        address reportedContract,
        string memory reason,
        uint256 submissionTimestamp,
        uint256 verificationDeadline,
        ReportStatus status,
        bool finalized,
        uint256 maliciousStakeWeight,
        uint256 safeStakeWeight,
        uint256 uncertainStakeWeight
    ) {
        Report storage r = reports[_reportId];
        if (r.reporter == address(0)) revert ReportNotFound();
        return (
            r.reporter,
            r.reportedContract,
            r.reason,
            r.submissionTimestamp,
            r.verificationDeadline,
            r.status,
            r.finalized,
            r.maliciousStakeWeight,
            r.safeStakeWeight,
            r.uncertainStakeWeight
        );
    }

    function getVerifierInfo(address _verifierAddress) external view returns (uint256 stakedAmount, uint256 activeVotes) {
        Verifier storage verifier = verifiersData[_verifierAddress];
        return (verifier.stakedAmount, verifier.activeVotesCount);
    }

    function getVoteOfVerifier(uint256 _reportId, address _verifierAddress) external view returns (VoteOption vote, uint256 stakeAtVoteTime) {
        if (reports[_reportId].reporter == address(0)) revert ReportNotFound();
        VoteRecord storage record = reports[_reportId].voteRecordsByVerifier[_verifierAddress];
        return (record.vote, record.stakeAtVoteTime);
    }

    function isContractVerifiedMalicious(address _contractAddress) external view returns (bool) {
        return isEverVerifiedMalicious[_contractAddress];
    }

    // --- Pausable Functions ---
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}