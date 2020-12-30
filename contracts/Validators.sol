pragma solidity >=0.6.0 <0.8.0;

import "./Params.sol";
import "./Proposal.sol";
import "./Punish.sol";
import "./library/SafeMath.sol";

contract Validators is Params {
    using SafeMath for uint256;


    // 基金会地址
    address public foundationAddr;
    // 质押奖励地址
    address public stakeAddr;
    // 管理员地址
    address public managerAddr;

    // 奖励分配规则
    // 提供给验证者，收取节点维护费
    uint256 public r1;
    // 提供给用户质押收益
    uint256 public r2;
    // 提供给基金会
    uint256 public r3;
    // 最大比例
    uint256 public r;

    // 验证者掉线惩罚
    uint256 public offLinePenalty;
    // 最大比例
    uint256  public offLinePenaltyMax;

    enum Status {
        // validator not exist, default status
        NotExist,
        // validator created
        Created,
        // anyone has staked for the validator
        Staked,
        // validator's staked coins < MinimalStakingCoin
        Unstaked,
        // validator is jailed by system(validator have to repropose)
        Jailed
    }

    struct Description {
        string moniker;
        string identity;
        string website;
        string email;
        string details;
    }

    struct Validator {
        address payable feeAddr;
        Status status;
        uint256 coins;
        Description description;
        uint256 bhpIncoming;
        uint256 offLineNumber;
        uint256 totalJailedBHP;
        uint256 lastWithdrawProfitsBlock;
        // Address list of user who has staked for this validator
        address[] stakers;
    }

    struct StakingInfo {
        uint256 coins;
        // unstakeBlock != 0 means that you are unstaking your stake, so you can't
        // stake or unstake
        uint256 unstakeBlock;
        // index of the staker list in validator
        uint256 index;
    }

    // 每个区块，staking的奖励
    mapping(uint256 => uint256) public stakeRewardByBlockNumber;
    mapping(address => Validator) validatorInfo;
    // staker => validator => info
    mapping(address => mapping(address => StakingInfo)) staked;
    // current validator set used by chain
    // only changed at block epoch
    address[] public currentValidatorSet;
    // highest validator set(dynamic changed)
    address[] public highestValidatorsSet;
    // total stake of all validators
    uint256 public totalStake;
    // total jailed hb
    uint256 public totalJailedBHP;

    // System contracts
    Proposal proposal;
    Punish punish;

    enum Operations {Distribute, UpdateValidators}
    // Record the operations is done or not.
    mapping(uint256 => mapping(uint8 => bool)) operationsDone;

    event LogCreateValidator(
        address indexed val,
        address indexed fee,
        uint256 time
    );
    event LogEditValidator(
        address indexed val,
        address indexed fee,
        uint256 time
    );
    event LogReactive(address indexed val, uint256 time);
    event LogAddToTopValidators(address indexed val, uint256 time);
    event LogRemoveFromTopValidators(address indexed val, uint256 time);
    event LogUnstake(
        address indexed staker,
        address indexed val,
        uint256 amount,
        uint256 time
    );
    event LogWithdrawStaking(
        address indexed staker,
        address indexed val,
        uint256 amount,
        uint256 time
    );
    event LogWithdrawProfits(
        address indexed val,
        address indexed fee,
        uint256 hb,
        uint256 time
    );
    event LogRemoveValidator(address indexed val, uint256 hb, uint256 time);
    event LogRemoveValidatorIncoming(
        address indexed val,
        uint256 hb,
        uint256 time
    );
    event LogDistributeBlockReward(
        address indexed coinbase,
        uint256 blockReward,
        uint256 time
    );
    event LogUpdateValidator(address[] newSet);
    event LogStake(
        address indexed staker,
        address indexed val,
        uint256 staking,
        uint256 time
    );

    modifier onlyNotRewarded() {
        require(
            operationsDone[block.number][uint8(Operations.Distribute)] == false,
            "Block is already rewarded"
        );
        _;
    }

    modifier onlyNotUpdated() {
        require(
            operationsDone[block.number][uint8(Operations.UpdateValidators)] ==
            false,
            "Validators already updated"
        );
        _;
    }

    modifier onlyByManager(){
        require(msg.sender == managerAddr, "Only by Manager");
        _;
    }

    // 设置管理员地址
    function setManagerAddr(address addr) external onlyByManager {
        require(addr != address(0), "Don't set empty address");
        managerAddr = addr;
    }

    // 设置基金会地址
    function setFoundationAddr(address addr) external onlyByManager {
        foundationAddr = addr;
    }

    // 设置质押收益地址
    function setStakeAddr(address addr) external onlyByManager {
        stakeAddr = addr;
    }

    // 设置给个分配奖励的比例(需要将比例扩大100倍)
    function setRewardDistributionRatio(uint256 _r1, uint256 _r2, uint256 _r3) external onlyByManager {
        require((_r1 + _r2 + _r3) == r, "The distribution ratio cannot be greater than 100%.");
        r1 = _r1;
        r2 = _r2;
        r3 = _r3;
    }

    // 设置掉线惩罚
    function setOffLinePenalty(uint256 penalty) external onlyByManager {
        require(penalty <= offLinePenaltyMax, "The proportion cannot exceed 100.");
        offLinePenalty = penalty;
    }

    function initialize(address[] calldata vals) external onlyNotInitialized {
        proposal = Proposal(ProposalAddr);
        punish = Punish(PunishContractAddr);

        for (uint256 i = 0; i < vals.length; i++) {
            require(vals[i] != address(0), "Invalid validator address");

            if (!isActiveValidator(vals[i])) {
                currentValidatorSet.push(vals[i]);
            }
            if (!isTopValidator(vals[i])) {
                highestValidatorsSet.push(vals[i]);
            }
            if (validatorInfo[vals[i]].feeAddr == address(0)) {
                validatorInfo[vals[i]].feeAddr = payable(vals[i]);
            }
            // Important: NotExist validator can't get profits
            if (validatorInfo[vals[i]].status == Status.NotExist) {
                validatorInfo[vals[i]].status = Status.Staked;
            }
        }

        initialized = true;

        foundationAddr = 0x94dCb4d5C84c6dA477A7481aC86EC65EA8F8c62A;
        stakeAddr = 0x2F32fc7A02D6006d4906540083c225DDff5efdDE;
        managerAddr = 0x0941A01ab7B3A39Ed6f55d6a4907778a3f15E5c9;

        r1 = 300;
        r2 = 2700;
        r3 = 7000;
        r = 10000;

        offLinePenalty = 2000;
        offLinePenaltyMax = 10000;
    }

    // stake for the validator
    function stake(address validator)
    external
    payable
    onlyInitialized
    returns (bool)
    {
        address payable staker = msg.sender;
        uint256 staking = msg.value;

        require(
            validatorInfo[validator].status == Status.Created ||
            validatorInfo[validator].status == Status.Staked,
            "Can't stake to a validator in abnormal status"
        );
        require(
            proposal.pass(validator),
            "The validator you want to stake must be authorized first"
        );
        require(
            staked[staker][validator].unstakeBlock == 0,
            "Can't stake when you are unstaking"
        );

        Validator storage valInfo = validatorInfo[validator];
        // The staked coins of validator must >= MinimalStakingCoin
        require(
            valInfo.coins.add(staking) >= MinimalStakingCoin,
            "Staking coins not enough"
        );

        // stake at first time to this valiadtor
        if (staked[staker][validator].coins == 0) {
            // add staker to validator's record list
            staked[staker][validator].index = valInfo.stakers.length;
            valInfo.stakers.push(staker);
        }

        valInfo.coins = valInfo.coins.add(staking);
        if (valInfo.status != Status.Staked) {
            valInfo.status = Status.Staked;
        }
        tryAddValidatorToHighestSet(validator, valInfo.coins);

        // record staker's info
        staked[staker][validator].coins = staked[staker][validator].coins.add(
            staking
        );
        totalStake = totalStake.add(staking);

        emit LogStake(staker, validator, staking, block.timestamp);
        return true;
    }

    function createOrEditValidator(
        address payable feeAddr,
        string calldata moniker,
        string calldata identity,
        string calldata website,
        string calldata email,
        string calldata details
    ) external onlyInitialized returns (bool) {
        require(feeAddr != address(0), "Invalid fee address");
        require(
            validateDescription(moniker, identity, website, email, details),
            "Invalid description"
        );
        address payable validator = msg.sender;
        bool isCreate = false;
        if (validatorInfo[validator].status == Status.NotExist) {
            require(proposal.pass(validator), "You must be authorized first");
            validatorInfo[validator].status = Status.Created;
            isCreate = true;
        }

        if (validatorInfo[validator].feeAddr != feeAddr) {
            validatorInfo[validator].feeAddr = feeAddr;
        }

        validatorInfo[validator].description = Description(
            moniker,
            identity,
            website,
            email,
            details
        );

        if (isCreate) {
            emit LogCreateValidator(validator, feeAddr, block.timestamp);
        } else {
            emit LogEditValidator(validator, feeAddr, block.timestamp);
        }
        return true;
    }

    function tryReactive(address validator)
    external
    onlyProposalContract
    onlyInitialized
    returns (bool)
    {
        // Only update validator status if Unstaked/Jailed
        if (
            validatorInfo[validator].status != Status.Unstaked &&
            validatorInfo[validator].status != Status.Jailed
        ) {
            return true;
        }

        if (validatorInfo[validator].status == Status.Jailed) {
            require(punish.cleanPunishRecord(validator), "clean failed");
        }
        validatorInfo[validator].status = Status.Created;

        emit LogReactive(validator, block.timestamp);
        return false;
    }

    function unstake(address validator)
    external
    onlyInitialized
    returns (bool)
    {
        address staker = msg.sender;
        require(
            validatorInfo[validator].status != Status.NotExist,
            "Validator not exist"
        );

        StakingInfo storage stakingInfo = staked[staker][validator];
        Validator storage valInfo = validatorInfo[validator];
        uint256 unstakeAmount = stakingInfo.coins;

        require(
            stakingInfo.unstakeBlock == 0,
            "You are already in unstaking status"
        );
        require(unstakeAmount > 0, "You don't have any stake");
        // You can't unstake if the validator is the only one top validator and
        // this unstake operation will cause staked coins of validator < MinimalStakingCoin
        require(
            !(highestValidatorsSet.length == 1 &&
        isTopValidator(validator) &&
        valInfo.coins.sub(unstakeAmount) < MinimalStakingCoin),
            "You can't unstake, validator list will be empty after this operation!"
        );

        // try to remove this staker out of validator stakers list.
        if (stakingInfo.index != valInfo.stakers.length - 1) {
            valInfo.stakers[stakingInfo.index] = valInfo.stakers[valInfo
            .stakers
            .length - 1];
            // update index of the changed staker.
            staked[valInfo.stakers[stakingInfo.index]][validator]
            .index = stakingInfo.index;
        }
        valInfo.stakers.pop();

        valInfo.coins = valInfo.coins.sub(unstakeAmount);
        stakingInfo.unstakeBlock = block.number;
        stakingInfo.index = 0;
        totalStake = totalStake.sub(unstakeAmount);

        // try to remove it out of active validator set if validator's coins < MinimalStakingCoin
        if (valInfo.coins < MinimalStakingCoin) {
            valInfo.status = Status.Unstaked;
            // it's ok if validator not in highest set
            tryRemoveValidatorInHighestSet(validator);

            // call proposal contract to set unpass.
            // validator have to repropose to rebecome a validator.
            proposal.setUnpassed(validator);
        }

        emit LogUnstake(staker, validator, unstakeAmount, block.timestamp);
        return true;
    }

    function withdrawStaking(address validator) external returns (bool) {
        address payable staker = payable(msg.sender);
        StakingInfo storage stakingInfo = staked[staker][validator];
        require(
            validatorInfo[validator].status != Status.NotExist,
            "validator not exist"
        );
        require(stakingInfo.unstakeBlock != 0, "You have to unstake first");
        // Ensure staker can withdraw his staking back
        require(
            stakingInfo.unstakeBlock + StakingLockPeriod <= block.number,
            "Your staking haven't unlocked yet"
        );
        require(stakingInfo.coins > 0, "You don't have any stake");

        uint256 staking = stakingInfo.coins;
        stakingInfo.coins = 0;
        stakingInfo.unstakeBlock = 0;

        // send stake back to staker
        staker.transfer(staking);

        emit LogWithdrawStaking(staker, validator, staking, block.timestamp);
        return true;
    }

    // feeAddr can withdraw profits of it's validator
    function withdrawProfits(address validator) external returns (bool) {
        address payable feeAddr = payable(msg.sender);
        require(
            validatorInfo[validator].status != Status.NotExist,
            "Validator not exist"
        );
        require(
            validatorInfo[validator].feeAddr == feeAddr,
            "You are not the fee receiver of this validator"
        );
        require(
            validatorInfo[validator].lastWithdrawProfitsBlock +
            WithdrawProfitPeriod <=
            block.number,
            "You must wait enough blocks to withdraw your profits after latest withdraw of this validator"
        );
        uint256 hbIncoming = validatorInfo[validator].bhpIncoming;
        require(hbIncoming > 0, "You don't have any profits");

        // update info
        validatorInfo[validator].bhpIncoming = 0;
        validatorInfo[validator].lastWithdrawProfitsBlock = block.number;

        // send profits to fee address
        if (hbIncoming > 0) {
            feeAddr.transfer(hbIncoming);
        }

        emit LogWithdrawProfits(
            validator,
            feeAddr,
            hbIncoming,
            block.timestamp
        );

        return true;
    }

    // distributeBlockReward distributes block reward to all active validators
    function distributeBlockReward()
    external
    payable
    onlyMiner
    onlyNotRewarded
    onlyInitialized
    {
        operationsDone[block.number][uint8(Operations.Distribute)] = true;
        address val = msg.sender;
        uint256 bhp = msg.value;

        // never reach this
        if (validatorInfo[val].status == Status.NotExist) {
            return;
        }

        if (bhp == 0) {
            return;
        }

        // 需要先将基金会奖励和质押奖励分配
        // 基金会
        address payable foundationRewardAddr = payable(foundationAddr);
        uint256 foundationReward = bhp.mul(r3).div(r);
        foundationRewardAddr.transfer(foundationReward);
        // 质押奖励
        address payable stakeRewardAddr = payable(stakeAddr);
        uint stakeReward = bhp.mul(r2).div(r);
        // 保存每个区块，质押获得的收益
        stakeRewardByBlockNumber[block.number] = stakeReward;
        stakeRewardAddr.transfer(stakeReward);

        // 剩余的为验证者节点维护费
        bhp = bhp.sub(foundationReward).sub(stakeReward);
        // Jailed validator can't get profits.
        addProfitsToActiveValidatorsByStakePercentExcept(bhp, address(0));

        emit LogDistributeBlockReward(val, bhp, block.timestamp);
    }

    function updateActiveValidatorSet(address[] memory newSet, uint256 epoch)
    public
    onlyMiner
    onlyNotUpdated
    onlyInitialized
    onlyBlockEpoch(epoch)
    {
        operationsDone[block.number][uint8(Operations.UpdateValidators)] = true;
        require(newSet.length > 0, "Validator set empty!");

        currentValidatorSet = newSet;

        emit LogUpdateValidator(newSet);
    }

    function removeValidator(address val) external onlyPunishContract {
        uint256 bhp = validatorInfo[val].bhpIncoming;

        tryRemoveValidatorIncoming(val);

        // remove the validator out of active set
        // Note: the jailed validator may in active set if there is only one validator exists
        if (highestValidatorsSet.length > 1) {
            tryJailValidator(val);

            // call proposal contract to set unpass.
            // you have to repropose to be a validator.
            proposal.setUnpassed(val);
            emit LogRemoveValidator(val, bhp, block.timestamp);
        }
    }

    function removeValidatorIncoming(address val) external onlyPunishContract {
        tryRemoveValidatorIncoming(val);
    }

    function getValidatorDescription(address val)
    public
    view
    returns (
        string memory,
        string memory,
        string memory,
        string memory,
        string memory
    )
    {
        Validator memory v = validatorInfo[val];

        return (
        v.description.moniker,
        v.description.identity,
        v.description.website,
        v.description.email,
        v.description.details
        );
    }

    function getValidatorInfo(address val)
    public
    view
    returns (
        address payable,
        Status,
        uint256,
        uint256,
        uint256,
        uint256,
        uint256,
        address[] memory
    )
    {
        Validator memory v = validatorInfo[val];

        return (
        v.feeAddr,
        v.status,
        v.coins,
        v.bhpIncoming,
        v.totalJailedBHP,
        v.offLineNumber,
        v.lastWithdrawProfitsBlock,
        v.stakers
        );
    }

    function getStakingInfo(address staker, address val)
    public
    view
    returns (
        uint256,
        uint256,
        uint256
    )
    {
        return (
        staked[staker][val].coins,
        staked[staker][val].unstakeBlock,
        staked[staker][val].index
        );
    }

    function getActiveValidators() public view returns (address[] memory) {
        return currentValidatorSet;
    }

    function getTotalStakeOfActiveValidators()
    public
    view
    returns (uint256 total, uint256 len)
    {
        return getTotalStakeOfActiveValidatorsExcept(address(0));
    }

    function getTotalStakeOfActiveValidatorsExcept(address val)
    private
    view
    returns (uint256 total, uint256 len)
    {
        for (uint256 i = 0; i < currentValidatorSet.length; i++) {
            if (
                validatorInfo[currentValidatorSet[i]].status != Status.Jailed &&
                val != currentValidatorSet[i]
            ) {
                total = total.add(validatorInfo[currentValidatorSet[i]].coins);
                len++;
            }
        }

        return (total, len);
    }

    function isActiveValidator(address who) public view returns (bool) {
        for (uint256 i = 0; i < currentValidatorSet.length; i++) {
            if (currentValidatorSet[i] == who) {
                return true;
            }
        }

        return false;
    }

    function isTopValidator(address who) public view returns (bool) {
        for (uint256 i = 0; i < highestValidatorsSet.length; i++) {
            if (highestValidatorsSet[i] == who) {
                return true;
            }
        }

        return false;
    }

    function getTopValidators() public view returns (address[] memory) {
        return highestValidatorsSet;
    }

    function validateDescription(
        string memory moniker,
        string memory identity,
        string memory website,
        string memory email,
        string memory details
    ) public pure returns (bool) {
        require(bytes(moniker).length <= 70, "Invalid moniker length");
        require(bytes(identity).length <= 3000, "Invalid identity length");
        require(bytes(website).length <= 140, "Invalid website length");
        require(bytes(email).length <= 140, "Invalid email length");
        require(bytes(details).length <= 280, "Invalid details length");

        return true;
    }

    function tryAddValidatorToHighestSet(address val, uint256 staking)
    internal
    {
        // do nothing if you are already in highestValidatorsSet set
        for (uint256 i = 0; i < highestValidatorsSet.length; i++) {
            if (highestValidatorsSet[i] == val) {
                return;
            }
        }

        if (highestValidatorsSet.length < MaxValidators) {
            highestValidatorsSet.push(val);
            emit LogAddToTopValidators(val, block.timestamp);
            return;
        }

        // find lowest validator index in current validator set
        uint256 lowest = validatorInfo[highestValidatorsSet[0]].coins;
        uint256 lowestIndex = 0;
        for (uint256 i = 1; i < highestValidatorsSet.length; i++) {
            if (validatorInfo[highestValidatorsSet[i]].coins < lowest) {
                lowest = validatorInfo[highestValidatorsSet[i]].coins;
                lowestIndex = i;
            }
        }

        // do nothing if staking amount isn't bigger than current lowest
        if (staking <= lowest) {
            return;
        }

        // replace the lowest validator
        emit LogAddToTopValidators(val, block.timestamp);
        emit LogRemoveFromTopValidators(
            highestValidatorsSet[lowestIndex],
            block.timestamp
        );
        highestValidatorsSet[lowestIndex] = val;
    }

    function tryRemoveValidatorIncoming(address val) private {
        // do nothing if validator not exist(impossible)
        if (
            validatorInfo[val].status == Status.NotExist ||
            currentValidatorSet.length <= 1
        ) {
            return;
        }

        // 记录退出次数
        validatorInfo[val].offLineNumber = validatorInfo[val].offLineNumber + 1;
        uint256 bhp = validatorInfo[val].bhpIncoming;
        if (bhp > 0) {
            // 按照惩罚比例，惩罚
            bhp = bhp.mul(offLinePenalty).div(offLinePenaltyMax);

            addProfitsToActiveValidatorsByStakePercentExcept(bhp, val);
            // for display purpose
            totalJailedBHP = totalJailedBHP.add(bhp);
            validatorInfo[val].bhpIncoming = validatorInfo[val]
            .bhpIncoming
            .sub(bhp);
            validatorInfo[val].totalJailedBHP = validatorInfo[val]
            .totalJailedBHP
            .add(bhp);
        }

        emit LogRemoveValidatorIncoming(val, bhp, block.timestamp);
    }

    // add profits to all validators by stake percent except the punished validator or jailed validator
    function addProfitsToActiveValidatorsByStakePercentExcept(
        uint256 totalReward,
        address punishedVal
    ) private {
        if (totalReward == 0) {
            return;
        }

        uint256 totalRewardStake;
        uint256 rewardValsLen;
        (
        totalRewardStake,
        rewardValsLen
        ) = getTotalStakeOfActiveValidatorsExcept(punishedVal);

        if (rewardValsLen == 0) {
            return;
        }

        uint256 remain;
        address last;

        // no stake(at genesis period)
        if (totalRewardStake == 0) {
            uint256 per = totalReward.div(rewardValsLen);
            remain = totalReward.sub(per.mul(rewardValsLen));

            for (uint256 i = 0; i < currentValidatorSet.length; i++) {
                address val = currentValidatorSet[i];
                if (
                    validatorInfo[val].status != Status.Jailed &&
                    val != punishedVal
                ) {
                    validatorInfo[val].bhpIncoming = validatorInfo[val]
                    .bhpIncoming
                    .add(per);

                    last = val;
                }
            }

            if (remain > 0 && last != address(0)) {
                validatorInfo[last].bhpIncoming = validatorInfo[last]
                .bhpIncoming
                .add(remain);
            }
            return;
        }

        uint256 added;
        for (uint256 i = 0; i < currentValidatorSet.length; i++) {
            address val = currentValidatorSet[i];
            if (
                validatorInfo[val].status != Status.Jailed && val != punishedVal
            ) {
                uint256 reward = totalReward.mul(validatorInfo[val].coins).div(
                    totalRewardStake
                );
                added = added.add(reward);
                last = val;
                validatorInfo[val].bhpIncoming = validatorInfo[val]
                .bhpIncoming
                .add(reward);
            }
        }

        remain = totalReward.sub(added);
        if (remain > 0 && last != address(0)) {
            validatorInfo[last].bhpIncoming = validatorInfo[last].bhpIncoming.add(
                remain
            );
        }
    }

    function tryJailValidator(address val) private {
        // do nothing if validator not exist
        if (validatorInfo[val].status == Status.NotExist) {
            return;
        }

        // set validator status to jailed
        validatorInfo[val].status = Status.Jailed;

        // try to remove if it's in active validator set
        tryRemoveValidatorInHighestSet(val);
    }

    function tryRemoveValidatorInHighestSet(address val) private {
        for (
            uint256 i = 0;
        // ensure at least one validator exist
            i < highestValidatorsSet.length && highestValidatorsSet.length > 1;
            i++
        ) {
            if (val == highestValidatorsSet[i]) {
                // remove it
                if (i != highestValidatorsSet.length - 1) {
                    highestValidatorsSet[i] = highestValidatorsSet[highestValidatorsSet
                    .length - 1];
                }

                highestValidatorsSet.pop();
                emit LogRemoveFromTopValidators(val, block.timestamp);

                break;
            }
        }
    }
}
