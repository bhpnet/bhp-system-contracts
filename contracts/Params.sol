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

    // 基金会地址
    address
        public BurnAddr = 0x94dCb4d5C84c6dA477A7481aC86EC65EA8F8c62A;

    // 管理员地址
    address
        public ManagerAddr = 0x0941A01ab7B3A39Ed6f55d6a4907778a3f15E5c9;

    // System params
    uint16 public constant MaxValidators = 21;
    // Validator have to wait StakingLockPeriod blocks to withdraw staking
    uint64 public constant StakingLockPeriod = 86400;
    // Validator have to wait WithdrawProfitPeriod blocks to withdraw his profits
    uint64 public constant WithdrawProfitPeriod = 28800;
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
