pragma solidity >=0.6.0 <0.8.0;

import "./Params.sol";
import "./Proposal.sol";
import "./Punish.sol";
import "./library/SafeMath.sol";

contract Validators is Params {
    using SafeMath for uint256;

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
        // 验证者状态
        Status status;
        // 该验证者的总质押
        uint256 coins;
        // 描述
        Description description;
        // 质押收益
        uint256 bhpIncoming;
        // 离线惩罚
        uint256 totalJailedReward;
        // Address list of user who has staked for this validator
        // 质押者列表
        address[] stakers;
    }

    struct StakingInfo {
        // 用户质押数量
        uint256 coins;
        // 退出状态
        uint256 unstakeBlock;
        // 在验证者，质押列表中的索引
        uint256 index;
        // 最后一次获取收益块
        uint256 lastWithdrawProfitsBlock;
        // 用户以获取收益
        uint userRewardPerTokenPaid;
        // 用户未取收益
        uint reward;
        // 验证者离线,被动惩罚
        uint256 jailedReward;
    }

    // 验证者信息
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
    uint256 public totalJailedHB;

    // System contracts
    Proposal proposal;
    Punish punish;

    enum Operations {Distribute, UpdateValidators}
    // Record the operations is done or not.
    mapping(uint256 => mapping(uint8 => bool)) operationsDone;
    // 记录每个验证者对应每个区块的token奖励
    mapping(address => mapping(uint256 => uint256)) blockTokenReward;

    event LogCreateValidator(
        address indexed val,
        uint256 time
    );
    event LogEditValidator(
        address indexed val,
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
            // Important: NotExist validator can't get profits
            if (validatorInfo[vals[i]].status == Status.NotExist) {
                validatorInfo[vals[i]].status = Status.Staked;
            }
        }

        initialized = true;
    }

    function createOrEditValidator(
        string calldata moniker,
        string calldata identity,
        string calldata website,
        string calldata email,
        string calldata details
    ) external onlyInitialized returns (bool) {
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

        validatorInfo[validator].description = Description(
            moniker,
            identity,
            website,
            email,
            details
        );

        if (isCreate) {
            emit LogCreateValidator(validator, block.timestamp);
        } else {
            emit LogEditValidator(validator, block.timestamp);
        }
        return true;
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
        StakingInfo storage stakingInfo = staked[staker][validator];

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
            stakingInfo.unstakeBlock == 0,
            "Can't stake when you are unstaking"
        );

        Validator storage valInfo = validatorInfo[validator];
        // The staked coins of validator must >= MinimalStakingCoin
        require(
            valInfo.coins.add(staking) >= MinimalStakingCoin,
            "Staking coins not enough"
        );

        // stake at first time to this valiadtor
        if (stakingInfo.coins == 0) {
            // add staker to validator's record list
            stakingInfo.index = valInfo.stakers.length;
            valInfo.stakers.push(staker);
        }

        valInfo.coins = valInfo.coins.add(staking);
        if (valInfo.status != Status.Staked) {
            valInfo.status = Status.Staked;
        }
        tryAddValidatorToHighestSet(validator, valInfo.coins);

        // 如果原先有质押，需要先将reward获取出来
        uint256 reward;
        if (stakingInfo.coins > 0) {
            reward = stakingInfo.coins.mul(
                getValidatorBlockRangeTokenReward(validator,stakingInfo.lastWithdrawProfitsBlock, block.number)
            );
        }

        // record staker's info
        stakingInfo.coins = stakingInfo.coins.add(staking);
        // 更新用户的未取收益
        stakingInfo.reward = stakingInfo.reward.add(reward).sub(stakingInfo.jailedReward);
        // 更新惩罚奖励
        stakingInfo.jailedReward = 0;
        // 更新用户获取收益的高度
        stakingInfo.lastWithdrawProfitsBlock = block.number;

        totalStake = totalStake.add(staking);

        emit LogStake(staker, validator, staking, block.timestamp);
        return true;
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

        // 质押奖励
        uint tokenReward = staking.mul(getValidatorBlockRangeTokenReward(validator,stakingInfo.lastWithdrawProfitsBlock, stakingInfo.unstakeBlock));
        // 所有奖励，需要减去离线惩罚
        uint reward = stakingInfo.reward.add(tokenReward).sub(stakingInfo.jailedReward);
        uint allMoney = staking.add(reward);

        // 更新用户未取存款
        stakingInfo.reward = 0;
        // 更新用户以取存款
        stakingInfo.userRewardPerTokenPaid = reward;
        // 更新离线惩罚
        stakingInfo.jailedReward = 0;
        // 更新最后取收益高度
        stakingInfo.lastWithdrawProfitsBlock = block.number;
        // 更新验证者的总收益池
        validatorInfo[validator].bhpIncoming = validatorInfo[validator].bhpIncoming.sub(reward);

        // send allMoney back to staker
        staker.transfer(allMoney);

        emit LogWithdrawStaking(staker, validator, staking, block.timestamp);
        return true;
    }

    // 收益（不能是unstake状态）
    function withdrawProfits(address validator) external returns (bool) {
        address payable userAddr = payable(msg.sender);
        StakingInfo storage userStake = staked[msg.sender][validator];

        require(
            validatorInfo[validator].status != Status.NotExist,
            "Validator not exist"
        );

        // 未质押，报错
        require(userStake.coins != 0, "You don't have any stake");
        // 不能是unstake状态
        require(
            userStake.unstakeBlock == 0,
            "Can't stake when you are unstaking"
        );
        // 收取收益不能小于区块范围
        require(
            userStake.lastWithdrawProfitsBlock +
            WithdrawProfitPeriod <=
            block.number,
            "You must wait enough blocks to withdraw your profits after latest withdraw of this validator"
        );

        // 当前验证者的所有收益
        uint256 bhpIncoming = validatorInfo[validator].bhpIncoming;
        require(bhpIncoming > 0, "You don't have any profits");

        uint totalToken = getValidatorBlockRangeTokenReward(validator,userStake.lastWithdrawProfitsBlock, block.number);
        uint reward = userStake.reward.add(userStake.coins.mul(totalToken)).sub(userStake.jailedReward);

        // 清空数据
        userStake.reward = 0;
        userStake.jailedReward = 0;

        // 如果收益大于验证者的总收益，报错
        require(bhpIncoming.sub(reward) > 0, "You don't have any profits");

        // 更新验证者剩余奖励
        validatorInfo[validator].bhpIncoming = validatorInfo[validator].bhpIncoming.sub(reward);
        // 更新用户以获取的收益
        userStake.userRewardPerTokenPaid = userStake.userRewardPerTokenPaid.add(reward);
        // 更新最后获取收益区块
        userStake.lastWithdrawProfitsBlock = block.number;

        // 发送奖励
        if (reward > 0) {
            userAddr.transfer(reward);
        }

        emit LogWithdrawProfits(
            validator,
            userAddr,
            reward,
            block.timestamp
        );

        return true;
    }

    function tryReactive(address validator) external onlyProposalContract onlyInitialized returns (bool){
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

    // 获取范围内的每个token的总收益
    function getValidatorBlockRangeTokenReward(address val,uint256 startBlockNumber, uint256 endBlockNumber) private returns (uint256){
        uint256 totalToken;
        for (uint i = startBlockNumber + 1; i <= endBlockNumber; i++) {
            totalToken = totalToken.add(blockTokenReward[val][i]);
        }
        return totalToken;
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

        // 先将70%分配给基金会地址
        uint256 burnBhp = bhp.mul(700).div(1000);
        address payable burn = payable(BurnAddr);
        burn.transfer(burnBhp);

        // Jailed validator can't get profits.
        addProfitsToActiveValidatorsByStakePercentExcept(bhp.sub(burnBhp), address(0));

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

    // 获取验证者描述
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

    // 获取验证者信息
    function getValidatorInfo(address val)
    public
    view
    returns (
        Status,
        uint256,
        uint256,
        uint256,
        address[] memory
    )
    {
        Validator memory v = validatorInfo[val];

        return (
        v.status,
        v.coins,
        v.bhpIncoming,
        v.totalJailedReward,
        v.stakers
        );
    }

    // 获取质押者信息
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

    // 获取所有验证者列表
    function getActiveValidators() public view returns (address[] memory) {
        return currentValidatorSet;
    }

    // 获取当前总质押量
    function getTotalStakeOfActiveValidators()
    public
    view
    returns (uint256 total, uint256 len)
    {
        return getTotalStakeOfActiveValidatorsExcept(address(0));
    }

    // 获取除了当前验证者状态为禁用，以及指定验证者地址以外的所有质押总量
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

    // 是否为验证者
    function isActiveValidator(address who) public view returns (bool) {
        for (uint256 i = 0; i < currentValidatorSet.length; i++) {
            if (currentValidatorSet[i] == who) {
                return true;
            }
        }

        return false;
    }

    // 是否为有效验证者
    function isTopValidator(address who) public view returns (bool) {
        for (uint256 i = 0; i < highestValidatorsSet.length; i++) {
            if (highestValidatorsSet[i] == who) {
                return true;
            }
        }

        return false;
    }

    // 获取当前有效验证者，列表
    function getTopValidators() public view returns (address[] memory) {
        return highestValidatorsSet;
    }

    // 验证，验证者信息是否符合要求
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

    // 验证指定验证者是否在前21个
    // 如果不在则加入，如果存在则返回
    function tryAddValidatorToHighestSet(address val, uint256 staking)
    internal
    {
        // do nothing if you are already in highestValidatorsSet set
        // 如果验证者已在前21，则返回
        for (uint256 i = 0; i < highestValidatorsSet.length; i++) {
            if (highestValidatorsSet[i] == val) {
                return;
            }
        }

        // 还未达到最大
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

    // 移除一个验证者的奖励，并按质押比例分配到各有效验证者
    // 处罚比例
    function tryRemoveValidatorIncoming(address val) private {
        // do nothing if validator not exist(impossible)
        if (
            validatorInfo[val].status == Status.NotExist ||
            currentValidatorSet.length <= 1
        ) {
            return;
        }

        uint256 bhp = validatorInfo[val].bhpIncoming;
        // 处罚比例(暂定为5%)
        bhp = bhp.mul(50).div(1000);
        // 计算平坦到每个用户的比例
        uint256 jail = bhp.div(validatorInfo[val].coins);
        for (uint256 i = 0; i < validatorInfo[val].stakers.length; i++) {
            // 获取质押者信息
            StakingInfo storage staker = staked[validatorInfo[val].stakers[i]][val];
            // 需要支付的处罚金额
            staker.jailedReward = staker.jailedReward.add(staker.coins.mul(jail));
        }

        if (bhp > 0) {
            addProfitsToActiveValidatorsByStakePercentExcept(bhp, val);
            // for display purpose
            totalJailedHB = totalJailedHB.add(bhp);
            validatorInfo[val].totalJailedReward = validatorInfo[val]
            .totalJailedReward
            .add(bhp);

            validatorInfo[val].bhpIncoming = validatorInfo[val].bhpIncoming.sub(bhp);
        }

        emit LogRemoveValidatorIncoming(val, bhp, block.timestamp);
    }

    // 通过股权百分比为所有验证者增加利润，但受惩罚的验证者或监禁的验证者除外
    function addProfitsToActiveValidatorsByStakePercentExcept(
        uint256 totalReward,
        address punishedVal
    ) private {
        if (totalReward == 0) {
            return;
        }

        // 当前需要分配奖励的总质押量
        uint256 totalRewardStake;
        // 需要分奖励的验证者数量
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
                    // 如果是在创世节点，还没有任何节点加入，直接把钱转给创世节点
                    address payable validator = payable(val);
                    validator.transfer(per);
                    last = val;
                }
            }

            if (remain > 0 && last != address(0)) {
                address payable validator = payable(last);
                validator.transfer(remain);
            }
            return;
        }


        // 先将10%给验证者，90%给质押用户
        uint256 verifierReward = totalReward.mul(100).div(1000);
        totalReward = totalReward.sub(verifierReward);
        // 获得每个验证者的额外收益
        verifierReward = verifierReward.mul(1).div(currentValidatorSet.length);

        // 计算当前区块的每个token的收益(如果有验证者被处罚，处罚奖励也会被添加到每个区块奖励中来)
        uint256 tokenReward = totalReward.div(totalRewardStake);
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

                // 添加额外收益给验证者
                staked[val][val].reward = verifierReward.add(staked[val][val].reward);
                // 记录每个验证者对于区块的奖励
                blockTokenReward[val][block.number] = blockTokenReward[val][block.number].add(tokenReward);
            }
        }

        remain = totalReward.sub(added);
        if (remain > 0 && last != address(0)) {
            validatorInfo[last].bhpIncoming = validatorInfo[last].bhpIncoming.add(
                remain
            );
        }
    }

    // 尝试监禁验证者
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

    // 尝试移除一个前21的验证者
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
