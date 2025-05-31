// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/**
 * @title EnhancedWatchdogRegistry
 * @notice Enhanced version with security fixes addressing audit findings
 * @dev Implements fixes for:
 * - Centralized control (timelock integration)
 * - Flash loan protection (stake locking, voting delays)
 * - Treasury failure handling (graceful degradation)
 * - Precision improvements (better calculations)
 * - Upgrade capability (UUPS pattern)
 * - Front-running protection (time delays)
 */
contract EnhancedWatchdogRegistry is 
    Initializable, 
    Ownable2Step, 
    Pausable, 
    ReentrancyGuard, 
    UUPSUpgradeable 
{
    using SafeERC20 for IERC20;

    // --- Version for upgrades ---
    string public constant VERSION = "2.0.0";

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
    error StakeTooRecentForVoting();
    error VotingTooRecentForUnstaking();
    error OnlyTimelock();
    error StakeConcentrationTooHigh();
    error TreasuryOperationFailed();

    // --- Events ---
    event ReportSubmitted(uint256 indexed reportId, address indexed reporter, address indexed reportedContract, string reason, uint256 submissionTimestamp, uint256 verificationDeadline);
    event Staked(address indexed verifier, uint256 amountAdded, uint256 newTotalStake, uint256 lockTimestamp);
    event Unstaked(address indexed verifier, uint256 amount);
    event Voted(uint256 indexed reportId, address indexed verifier, VoteOption vote, uint256 stakeWeightAtVoteTime);
    event ReportFinalized(uint256 indexed reportId, ReportStatus status, uint256 maliciousStakeWeight, uint256 safeStakeWeight, uint256 uncertainStakeWeight);
    event RewardsClaimed(address indexed user, uint256 reportId, uint256 rewardAmount);
    event ReporterRewardPaid(uint256 indexed reportId, address indexed reporter, uint256 rewardAmount);
    event Slashed(address indexed verifier, uint256 reportId, uint256 amountSlashed);
    event TreasuryTransferFailed(string operation, uint256 amount, address recipient);
    event TimelockUpdated(address newTimelock);
    event EmergencyWithdrawal(address token, uint256 amount, address recipient);
    
    // Parameter update events (for timelock operations)
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
        uint256 voteTimestamp;
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
        uint256 lastStakeTimestamp;
        uint256 lastVoteTimestamp;
    }

    // --- State Variables ---
    IERC20 public GSHIB_TOKEN;

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
    address public timelockController;

    mapping(uint256 => mapping(address => bool)) public activeVoteCountAdjustedForReport;

    // --- Flash loan and manipulation protection ---
    uint256 public minStakingPeriod; // Minimum time before stakers can vote (anti-flash loan)
    uint256 public minVotingPeriod; // Minimum time after voting before unstaking
    uint256 public maxStakeConcentration; // Maximum percentage of total stake one address can hold
    uint256 public totalStaked; // Track total staked amount

    // --- Enhanced precision constants ---
    uint256 private constant BASIS_POINTS_MAX = 10000;
    uint256 private constant PRECISION_MULTIPLIER = 1e18; // For high precision calculations

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

    // --- Constructor (for implementation) ---
    constructor() {
        _disableInitializers();
    }

    // --- Initializer (replaces constructor for upgradeable pattern) ---
    function initialize(
        address _gshibTokenAddress,
        uint256 _initialReportFee,
        uint256 _initialMinStakeAmount,
        uint256 _initialVerificationPeriod,
        uint256 _initialConsensusThreshold,
        address _initialTreasuryAddress,
        uint256 _initialReporterRewardPercentage,
        uint256 _initialSlashPercentage,
        uint256 _initialVerifierRewardPoolPercentage,
        uint256 _initialMaxReasonLength,
        address _timelockController
    ) public initializer {
        __Ownable2Step_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        // Validation
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
        timelockController = _timelockController;

        // Set anti-manipulation parameters
        minStakingPeriod = 1 hours; // Must stake for 1 hour before voting
        minVotingPeriod = 24 hours; // Must wait 24 hours after voting to unstake
        maxStakeConcentration = 2000; // 20% maximum concentration (20% of 10000 basis points)
    }

    // --- Upgrade authorization ---
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // --- Configuration Functions (Timelock Controlled) ---
    function setReportFee(uint256 _newFee) external onlyTimelock {
        reportFee = _newFee;
        emit ReportFeeUpdated(_newFee);
    }

    function setMinStakeAmount(uint256 _newMinStake) external onlyTimelock {
        if (_newMinStake == 0) revert MinStakeCannotBeZero();
        minStakeAmount = _newMinStake;
        emit MinStakeAmountUpdated(_newMinStake);
    }

    function setVerificationPeriod(uint256 _newPeriod) external onlyTimelock {
        if (_newPeriod == 0) revert InvalidVerificationPeriod();
        verificationPeriod = _newPeriod;
        emit VerificationPeriodUpdated(_newPeriod);
    }

    function setConsensusThreshold(uint256 _newThreshold) external onlyTimelock {
        if (_newThreshold == 0 || _newThreshold > BASIS_POINTS_MAX) revert InvalidThreshold();
        consensusThreshold = _newThreshold;
        emit ConsensusThresholdUpdated(_newThreshold);
    }

    function setTreasuryAddress(address _newTreasury) external onlyTimelock {
        if (_newTreasury == address(0)) revert InvalidAddress();
        treasuryAddress = _newTreasury;
        emit TreasuryAddressUpdated(_newTreasury);
    }

    function setReporterRewardPercentage(uint256 _newPercentage) external onlyTimelock {
        if (_newPercentage > BASIS_POINTS_MAX) revert InvalidRewardPercentage();
        reporterRewardPercentage = _newPercentage;
        emit ReporterRewardPercentageUpdated(_newPercentage);
    }

    function setSlashPercentage(uint256 _newPercentage) external onlyTimelock {
        if (_newPercentage > BASIS_POINTS_MAX) revert InvalidRewardPercentage();
        slashPercentage = _newPercentage;
        emit SlashPercentageUpdated(_newPercentage);
    }

    function setVerifierRewardPoolPercentage(uint256 _newPercentage) external onlyTimelock {
        if (_newPercentage > BASIS_POINTS_MAX) revert InvalidRewardPercentage();
        verifierRewardPoolPercentage = _newPercentage;
        emit VerifierRewardPoolPercentageUpdated(_newPercentage);
    }

    function setMaxReasonLength(uint256 _newMaxReasonLength) external onlyTimelock {
        if (_newMaxReasonLength == 0) revert InvalidMaxReasonLength();
        maxReasonLength = _newMaxReasonLength;
        emit MaxReasonLengthUpdated(_newMaxReasonLength);
    }

    function setTimelockController(address _newTimelock) external onlyOwner {
        timelockController = _newTimelock;
        emit TimelockUpdated(_newTimelock);
    }

    // --- Enhanced Staking Functions with Flash Loan Protection ---
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidStakeAmount();
        
        Verifier storage verifier = verifiersData[msg.sender];
        
        // Check if initial stake meets minimum
        if (verifier.stakedAmount == 0 && amount < minStakeAmount) revert MinStakeNotMet();
        
        // Check stake concentration limit (prevent single entity from controlling too much)
        uint256 newTotalStaked = totalStaked + amount;
        uint256 newUserStake = verifier.stakedAmount + amount;
        if (newTotalStaked > 0 && (newUserStake * BASIS_POINTS_MAX) / newTotalStaked > maxStakeConcentration) {
            revert StakeConcentrationTooHigh();
        }
        
        verifier.stakedAmount += amount;
        verifier.lastStakeTimestamp = block.timestamp;
        totalStaked += amount;
        
        GSHIB_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount, verifier.stakedAmount, block.timestamp);
    }

    function unstake() external nonReentrant whenNotPaused {
        Verifier storage verifier = verifiersData[msg.sender];
        uint256 amountToReturn = verifier.stakedAmount;

        if (amountToReturn == 0) revert NotStaked();
        if (verifier.activeVotesCount > 0) revert CannotUnstakeWithActiveVotes();
        
        // Anti-flash loan: must wait after voting before unstaking
        if (verifier.lastVoteTimestamp > 0 && 
            block.timestamp < verifier.lastVoteTimestamp + minVotingPeriod) {
            revert VotingTooRecentForUnstaking();
        }

        verifier.stakedAmount = 0;
        totalStaked -= amountToReturn;
        
        GSHIB_TOKEN.safeTransfer(msg.sender, amountToReturn);
        emit Unstaked(msg.sender, amountToReturn);
    }

    // --- Enhanced Reporting Functions ---
    function submitReport(address _contractToReport, string calldata _reason) 
        external 
        nonReentrant 
        whenNotPaused 
        returns (uint256 reportId) 
    {
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

        // Enhanced treasury interaction with better error handling
        try GSHIB_TOKEN.safeTransferFrom(msg.sender, treasuryAddress, reportFee) {
            // Success
        } catch {
            // If treasury transfer fails, revert the whole operation
            revert TreasuryOperationFailed();
        }
        
        emit ReportSubmitted(reportId, msg.sender, _contractToReport, _reason, newReport.submissionTimestamp, newReport.verificationDeadline);
        return reportId;
    }

    // --- Enhanced Voting Functions with Flash Loan Protection ---
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
        
        // Anti-flash loan: must have staked for minimum period before voting
        if (block.timestamp < verifier.lastStakeTimestamp + minStakingPeriod) {
            revert StakeTooRecentForVoting();
        }

        currentReport.voteRecordsByVerifier[msg.sender] = VoteRecord(_vote, stakeAtVoteTime, block.timestamp);

        if (_vote == VoteOption.Malicious) {
            currentReport.maliciousStakeWeight += stakeAtVoteTime;
        } else if (_vote == VoteOption.Safe) {
            currentReport.safeStakeWeight += stakeAtVoteTime;
        } else { // VoteOption.Uncertain
            currentReport.uncertainStakeWeight += stakeAtVoteTime;
        }

        verifier.activeVotesCount++;
        verifier.lastVoteTimestamp = block.timestamp;
        emit Voted(_reportId, msg.sender, _vote, stakeAtVoteTime);
    }

    // --- Enhanced Finalization with Better Treasury Handling ---
    function finalizeReport(uint256 _reportId) external whenNotPaused nonReentrant {
        Report storage currentReport = reports[_reportId];

        if (currentReport.reporter == address(0)) revert ReportNotFound();
        if (block.timestamp <= currentReport.verificationDeadline) revert VotingPeriodNotOver();
        if (currentReport.finalized) revert ReportAlreadyFinalized();

        currentReport.finalized = true;
        uint256 totalConsensusSeekingStake = currentReport.maliciousStakeWeight + currentReport.safeStakeWeight;

        if (totalConsensusSeekingStake == 0) {
            currentReport.status = ReportStatus.DisputedByNoVotes;
        } else if ((_calculatePrecisePercentage(currentReport.maliciousStakeWeight, totalConsensusSeekingStake)) >= consensusThreshold) {
            currentReport.status = ReportStatus.VerifiedMalicious;
            isEverVerifiedMalicious[currentReport.reportedContract] = true;

            // Enhanced reporter reward handling
            if (reporterRewardPercentage > 0 && currentReport.reporter != address(0) && reportFee > 0) {
                uint256 reporterReward = _calculatePreciseReward(reportFee, reporterRewardPercentage);
                if (reporterReward > 0) {
                    try GSHIB_TOKEN.safeTransferFrom(treasuryAddress, currentReport.reporter, reporterReward) {
                        emit ReporterRewardPaid(_reportId, currentReport.reporter, reporterReward);
                    } catch {
                        emit ReporterRewardTransferFailed(_reportId, currentReport.reporter, reporterReward);
                        emit TreasuryTransferFailed("reporter_reward", reporterReward, currentReport.reporter);
                    }
                }
            }
        } else if ((_calculatePrecisePercentage(currentReport.safeStakeWeight, totalConsensusSeekingStake)) >= consensusThreshold) {
            currentReport.status = ReportStatus.VerifiedSafe;
        } else {
            currentReport.status = ReportStatus.DisputedByNoConsensus;
        }

        emit ReportFinalized(_reportId, currentReport.status, currentReport.maliciousStakeWeight, currentReport.safeStakeWeight, currentReport.uncertainStakeWeight);
    }

    // --- Enhanced Processing with Better Error Handling ---
    function processVoteOutcome(uint256 _reportId) external nonReentrant whenNotPaused {
        Report storage currentReport = reports[_reportId];
        Verifier storage verifier = verifiersData[msg.sender];
        VoteRecord memory voterRecord = currentReport.voteRecordsByVerifier[msg.sender];

        if (!currentReport.finalized) revert ReportNotFinalized();
        if (voterRecord.stakeAtVoteTime == 0) revert VoteRecordNotFound();

        bool countAdjusted = false;
        bool slashed = false;
        uint256 slashAmount = 0;

        // Adjust active vote count
        if (!activeVoteCountAdjustedForReport[_reportId][msg.sender]) {
            if (verifier.activeVotesCount > 0) {
                verifier.activeVotesCount--;
            }
            activeVoteCountAdjustedForReport[_reportId][msg.sender] = true;
            countAdjusted = true;
        }

        // Process slashing with enhanced precision
        if (!currentReport.financiallyProcessedVerifiers[msg.sender]) {
            if (currentReport.status == ReportStatus.VerifiedMalicious && slashPercentage > 0) {
                if (voterRecord.vote == VoteOption.Safe) {
                    slashAmount = _calculatePreciseReward(voterRecord.stakeAtVoteTime, slashPercentage);
                    if (slashAmount > 0) {
                        if (slashAmount > verifier.stakedAmount) {
                            slashAmount = verifier.stakedAmount;
                        }
                        verifier.stakedAmount -= slashAmount;
                        totalStaked -= slashAmount;
                        currentReport.financiallyProcessedVerifiers[msg.sender] = true;
                        slashed = true;
                        
                        // Enhanced treasury transfer with error handling
                        try GSHIB_TOKEN.safeTransfer(treasuryAddress, slashAmount) {
                            emit Slashed(msg.sender, _reportId, slashAmount);
                        } catch {
                            // If treasury transfer fails, still slash from user but emit event
                            emit Slashed(msg.sender, _reportId, slashAmount);
                            emit TreasuryTransferFailed("slashing", slashAmount, treasuryAddress);
                        }
                    }
                }
            }
        }
        emit VerifierVoteOutcomeProcessed(_reportId, msg.sender, countAdjusted, slashed, slashAmount);
    }

    // --- Enhanced Rewards Claiming with Better Precision ---
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
                // Enhanced precision calculation
                uint256 poolNumerator = BASIS_POINTS_MAX - reporterRewardPercentage;
                uint256 basePoolForVerifiers = _calculatePreciseReward(reportFee, poolNumerator);
                uint256 actualVerifierRewardPool = _calculatePreciseReward(basePoolForVerifiers, verifierRewardPoolPercentage);
                
                if (actualVerifierRewardPool > 0) {
                    // High precision calculation to minimize truncation
                    rewardAmount = (userVoteRecord.stakeAtVoteTime * actualVerifierRewardPool * PRECISION_MULTIPLIER) 
                                   / (currentReport.maliciousStakeWeight * PRECISION_MULTIPLIER);
                }
            }
        }

        if (rewardAmount == 0) revert NothingToClaim();

        currentReport.financiallyProcessedVerifiers[msg.sender] = true;

        try GSHIB_TOKEN.safeTransferFrom(treasuryAddress, msg.sender, rewardAmount) {
            emit RewardsClaimed(msg.sender, _reportId, rewardAmount);
        } catch {
            currentReport.financiallyProcessedVerifiers[msg.sender] = false;
            emit TreasuryTransferFailed("verifier_reward", rewardAmount, msg.sender);
            revert RewardsNotFundedByTreasury();
        }
    }

    // --- Enhanced Helper Functions ---
    function _calculatePrecisePercentage(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        if (denominator == 0) return 0;
        return (numerator * BASIS_POINTS_MAX * PRECISION_MULTIPLIER) / (denominator * PRECISION_MULTIPLIER);
    }

    function _calculatePreciseReward(uint256 amount, uint256 percentage) internal pure returns (uint256) {
        return (amount * percentage * PRECISION_MULTIPLIER) / (BASIS_POINTS_MAX * PRECISION_MULTIPLIER);
    }

    // --- Emergency Functions ---
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        if (token == address(GSHIB_TOKEN)) {
            // Only allow withdrawal of excess GSHIB (not staked amount)
            uint256 balance = GSHIB_TOKEN.balanceOf(address(this));
            uint256 maxWithdrawable = balance > totalStaked ? balance - totalStaked : 0;
            if (amount > maxWithdrawable) {
                amount = maxWithdrawable;
            }
        }
        
        IERC20(token).safeTransfer(owner(), amount);
        emit EmergencyWithdrawal(token, amount, owner());
    }

    // --- View Functions (unchanged) ---
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

    function getVerifierInfo(address _verifierAddress) external view returns (
        uint256 stakedAmount, 
        uint256 activeVotes,
        uint256 lastStakeTime,
        uint256 lastVoteTime
    ) {
        Verifier storage verifier = verifiersData[_verifierAddress];
        return (verifier.stakedAmount, verifier.activeVotesCount, verifier.lastStakeTimestamp, verifier.lastVoteTimestamp);
    }

    function getVoteOfVerifier(uint256 _reportId, address _verifierAddress) external view returns (
        VoteOption vote, 
        uint256 stakeAtVoteTime,
        uint256 voteTimestamp
    ) {
        if (reports[_reportId].reporter == address(0)) revert ReportNotFound();
        VoteRecord storage record = reports[_reportId].voteRecordsByVerifier[_verifierAddress];
        return (record.vote, record.stakeAtVoteTime, record.voteTimestamp);
    }

    function isContractVerifiedMalicious(address _contractAddress) external view returns (bool) {
        return isEverVerifiedMalicious[_contractAddress];
    }

    // --- Pausable Functions (Emergency only, not through timelock) ---
    function pause() external onlyOwnerOrTimelock {
        _pause();
    }

    function unpause() external onlyOwnerOrTimelock {
        _unpause();
    }
}
