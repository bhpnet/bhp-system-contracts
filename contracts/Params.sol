pragma solidity >=0.6.0 <0.8.0;

contract Params {
    bool public initialized;

    // System contracts
    address
        public constant ValidatorContractAddr = 0x000000000000000000000000000000000000f000;
    address
        public constant PunishContractAddr = 0x000000000000000000000000000000000000F001;
    address
        public constant ProposalAddr = 0x000000000000000000000000000000000000F002;

    // System params
    uint16 public constant MaxValidators = 21;
    // Validator have to wait StakingLockPeriod blocks to withdraw staking
    // 3day
    uint64 public constant StakingLockPeriod = 17280;
    // Validator have to wait WithdrawProfitPeriod blocks to withdraw his profits
    // 1day
    uint64 public constant WithdrawProfitPeriod = 5760;
    uint256 public constant MinimalStakingCoin = 32 ether;

    modifier onlyMiner() {
        require(msg.sender == block.coinbase, "Miner only");
        _;
    }

    modifier onlyNotInitialized() {
        require(!initialized, "Already initialized");
        _;
    }

    modifier onlyInitialized() {
        require(initialized, "Not init yet");
        _;
    }

    modifier onlyPunishContract() {
        require(msg.sender == PunishContractAddr, "Punish contract only");
        _;
    }

    modifier onlyBlockEpoch(uint256 epoch) {
        require(block.number % epoch == 0, "Block epoch only");
        _;
    }

    modifier onlyValidatorsContract() {
        require(
            msg.sender == ValidatorContractAddr,
            "Validators contract only"
        );
        _;
    }

    modifier onlyProposalContract() {
        require(msg.sender == ProposalAddr, "Proposal contract only");
        _;
    }

    modifier onlyManagerAddr(){
        require(msg.sender == ManagerAddr, "Only by manage");
        _;
    }

    function setBurnAddr(address addr) external onlyManagerAddr {
        BurnAddr = addr;
    }

    function setManager(address addr) external onlyManagerAddr {
        ManagerAddr = addr;
    }
}
