// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IntentContract - Immutable Layer 1 of Autonomous Capital Allocation
 * @notice Encodes treasury constraints without decision logic. Serves as verifiable boundary.
 * @dev No admin functions - contract is immutable after deployment.
 */
contract IntentContract {
    // ============ STATE VARIABLES ============
    address public immutable treasury;
    uint256 public constant MIN_TVL = 10_000_000 * 10**18; // $10M in wei
    uint256 public constant MIN_AUDIT_SCORE = 8; // 8/10 minimum
    uint256 public constant MAX_EXPOSURE_PERCENT = 30; // 30% max to single protocol
    uint256 public constant MAX_GAS_RATIO = 100; // 1% = 100 basis points
    uint256 public constant EMERGENCY_DELAY = 24 hours;
    uint256 public constant SOLVER_STAKE = 10 * 10**18; // 10 MATIC
    
    struct Proposal {
        address solver;
        address targetPool;
        uint256 expectedNetAPY; // In basis points (0.01%)
        uint256 dataRoot; // Merkle root of attested data
        uint256 timestamp;
        uint256 stakeAmount;
        bool executed;
    }
    
    Proposal[] public proposals;
    mapping(address => uint256) public solverReputation;
    mapping(address => uint256) public emergencyWithdrawTimestamps;
    
    // ============ EVENTS ============
    event ProposalSubmitted(uint256 indexed proposalId, address solver, address targetPool);
    event ProposalExecuted(uint256 indexed proposalId, address solver, uint256 actualGasUsed);
    event EmergencyWithdrawalInitiated(address indexed solver, uint256 unlockTime);
    event SolverSlashed(address indexed solver, uint256 amount);
    event PerformanceNFTMinted(uint256 indexed proposalId, string metadataURI);
    
    // ============ MODIFIERS ============
    modifier onlyTreasury() {
        require(msg.sender == treasury, "Only treasury");
        _;
    }
    
    // ============ CONSTRUCTOR ============
    constructor(address _treasury) {
        treasury = _treasury;
    }
    
    // ============ CORE FUNCTIONS ============
    /**
     * @dev Submit allocation proposal with staked MATIC
     * @param targetPool Address of DeFi pool
     * @param expectedNetAPY Expected net APY in basis points (after gas)
     * @param dataRoot Merkle root of attested data from multiple sources
     */
    function submitProposal(
        address targetPool,
        uint256 expectedNetAPY,
        uint256 dataRoot
    ) external payable returns (uint256) {
        require(msg.value == SOLVER_STAKE, "Incorrect stake amount");
        require(targetPool != address(0), "Invalid pool address");
        
        // Basic constraint validation (detailed validation off-chain)
        require(expectedNetAPY > 0, "APY must be positive");
        
        uint256 proposalId = proposals.length;
        proposals.push(Proposal({
            solver: msg.sender,
            targetPool: targetPool,
            expectedNetAPY: expectedNetAPY,
            dataRoot: dataRoot,
            timestamp: block.timestamp,
            stakeAmount: msg.value,
            executed: false
        }));
        
        emit ProposalSubmitted(proposalId, msg.sender, targetPool);
        return proposalId;
    }
    
    /**
     * @dev Execute winning proposal after off-chain selection
     * @param proposalId ID of proposal to execute
     * @param gasUsed Actual gas used for execution tracking
     */
    function executeProposal(uint256 proposalId, uint256 gasUsed) external onlyTreasury {
        require(proposalId < proposals.length, "Invalid proposal ID");
        Proposal storage proposal = proposals[proposalId];
        require(!proposal.executed, "Already executed");
        
        proposal.executed = true;
        
        // Return stake to solver plus small reward (1 MATIC)
        uint256 reward = proposal.stakeAmount + 1 * 10**18;
        payable(proposal.solver).transfer(reward);
        
        // Increment reputation
        solverReputation[proposal.solver] += 1;
        
        emit ProposalExecuted(proposalId, proposal.solver, gasUsed);
    }
    
    /**
     * @dev Initiate emergency withdrawal from a pool
     */
    function initiateEmergencyWithdrawal() external onlyTreasury {
        emergencyWithdrawTimestamps[msg.sender] = block.timestamp + EMERGENCY_DELAY;
        emit EmergencyWithdrawalInitiated(msg.sender, block.timestamp + EMERGENCY_DELAY);
    }
    
    /**
     * @dev Complete emergency withdrawal after delay
     */
    function completeEmergencyWithdrawal() external onlyTreasury {
        require(
            emergencyWithdrawTimestamps[msg.sender] > 0 &&
            block.timestamp >= emergencyWithdrawTimestamps[msg.sender],
            "Withdrawal not ready"
        );
        emergencyWithdrawTimestamps[msg.sender] = 0;
        // In production, this would interact with the actual pool
    }
    
    /**
     * @dev Slash solver for invalid proposal
     */
    function slashSolver(uint256 proposalId) external onlyTreasury {
        require(proposalId < proposals.length, "Invalid proposal ID");
        Proposal storage proposal = proposals[proposalId];
        require(!proposal.executed, "Cannot slash executed proposal");
        
        proposal.executed = true; // Mark as invalid
        // Stake is burned (stays in contract)
        
        if (solverReputation[proposal.solver] > 0) {
            solverReputation[proposal.solver] -= 1;
        }
        
        emit SolverSlashed(proposal.solver, proposal.stakeAmount);
    }
    
    // ============ VIEW FUNCTIONS ============
    /**
     * @dev Get all active (unexecuted) proposals
     */
    function getActiveProposals() external view returns (uint256[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < proposals.length; i++) {
            if (!proposals[i].executed) count++;
        }
        
        uint256[] memory active = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < proposals.length; i++) {
            if (!proposals[i].executed) {
                active[index] = i;
                index++;
            }
        }
        return active;
    }
    
    /**
     * @dev Calculate score for proposal (replicable off-chain)
     */
    function calculateProposalScore(uint256 proposalId) external view returns (uint256) {
        require(proposalId < proposals.length, "Invalid proposal ID");
        Proposal memory proposal = proposals[proposalId];
        
        // Score = 70% APY + 30% consistency - gas ratio
        // Simulated - real implementation uses verified data
        uint256 apyComponent = proposal.expectedNetAPY * 70;
        uint256 consistencyComponent = 100 * 30; // Placeholder
        uint256 gasComponent = 0; // Would be calculated based on gas estimate
        
        return (apyComponent + consistencyComponent) - gasComponent;
    }
    
    // Receive MATIC for staking
    receive() external payable {}
}