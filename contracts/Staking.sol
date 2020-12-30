pragma solidity >=0.6.0 <0.8.0;

import "./library/SafeMath.sol";

interface IValidators {
    function stakeRewardByBlockNumber(uint256) external view returns (uint256);

    function stakeAddr() external view returns (address);
}

contract StakeTokenReward {
    using SafeMath for uint256;

    address public constant ValidatorContractAddr = 0x000000000000000000000000000000000000f000;
    address public manage;
    IValidators validator;

    // 总质押
    uint256 public totalStake;

    // 每个token的累计收益
    uint256 public cumulativeRewardPerStoredToken;

    // 最后一次计算,区块高度
    uint256 lastBlockNumber;

    // 是否开启
    bool start;

    struct stakingInfo {
        // 用户质押
        uint256 coins;
        // 每个token累计收益
        uint256 userCumulativeRevenuePerToken;
        // 最后一次领取收益的区块
        uint256 lastWithdrawProfitsBlock;
        // 用户以获取收益
        uint256 userRewardPerTokenPaid;
        // 用户未获取收益
        uint256 reward;
    }

    // 用户对应的个人信息
    mapping(address => stakingInfo) staked;

    event Staked(
        address staker,
        uint256 amount
    );
    event Withdrawn(
        address staker,
        uint256 amount,
        uint256 reward
    );
    event RewardPaid(
        address staker,
        uint256 reward
    );
    event LogReward(
        uint256 amount,
        uint256 cumulativeRewardPerStoredToken
    );


    constructor() public {
        validator = IValidators(ValidatorContractAddr);
        manage = msg.sender;
    }

    modifier updateCumulativeRewardPerStoredToken(){
        require(totalStake > 0,"no stake");

        // 如果validators设置的地址是本合约地址
        // 并且最后一次获取奖励的要小于当前高度
        // 可以更新奖励
        if(totalStake > 0){
            if ((address(this) == address(validator.stakeAddr())) && (lastBlockNumber <= block.number)) {
                // 计算当前的收益
                cumulativeRewardPerStoredToken = cumulativeRewardPerStoredToken.add(
                    getBlockNumberReward(lastBlockNumber).mul(1e18).div(totalStake)
                );
                // 更新收益
                lastBlockNumber = block.number;
            }
        }
        _;
    }

    modifier checkStart(){
        require(start, "no start");
        _;
    }

    modifier checkManage(){
        require(manage == msg.sender,"Only by Manager");
        _;
    }

    function setManageAddr(address account) external checkManage {
        manage = account;
    }

    // 质押
    function stake() external payable checkStart updateCumulativeRewardPerStoredToken {
        uint256 amount = msg.value;
        require(amount > 0, "Cannot pledge 0!");


        totalStake = totalStake.add(amount);
        stakingInfo storage staker = staked[msg.sender];
        // 如果在次质押，将原有奖励计算出来
        if (staker.coins > 0) {
            // 计算出奖励
            uint256 reward = staker.coins.mul(
                cumulativeRewardPerStoredToken.sub(staker.userCumulativeRevenuePerToken)
            ).div(1e18);
            staker.reward = staker.reward.add(reward);
            // 更新用户每个token累计收益
            staker.userCumulativeRevenuePerToken = cumulativeRewardPerStoredToken;
        }

        staker.lastWithdrawProfitsBlock = block.number;
        staker.userCumulativeRevenuePerToken = cumulativeRewardPerStoredToken;
        staker.coins = staker.coins.add(amount);

        emit Staked(msg.sender, amount);
    }

    // 查看用户质押收益
    function earned(address account) external view returns (uint256) {
        require(totalStake > 0, "no stake");
        stakingInfo memory staker = staked[account];
        uint256 tokenByReward;

        if (address(this) == address(validator.stakeAddr())) {
            // 计算当前的收益
            tokenByReward = cumulativeRewardPerStoredToken.add(
                getBlockNumberReward(lastBlockNumber).mul(1e18).div(totalStake)
            );
        } else {
            tokenByReward = cumulativeRewardPerStoredToken;
        }

        return staker.coins.mul(
            tokenByReward.sub(staker.userCumulativeRevenuePerToken)
        )
        .div(1e18)
        .add(staker.reward);
    }

    // 获取奖励
    function getReward() external checkStart updateCumulativeRewardPerStoredToken {
        stakingInfo storage staker = staked[msg.sender];
        require(staker.coins > 0, "You need to stake first");

        uint256 reward = staker.coins.mul(
            cumulativeRewardPerStoredToken.sub(staker.userCumulativeRevenuePerToken)
        ).div(1e18);
        reward = reward.add(staker.reward);

        address payable stakerAddr = payable(msg.sender);

        staker.userCumulativeRevenuePerToken = cumulativeRewardPerStoredToken;
        staker.reward = 0;
        staker.userRewardPerTokenPaid = staker.userRewardPerTokenPaid.add(reward);
        staker.lastWithdrawProfitsBlock = block.number;

        // 发送奖励
        stakerAddr.transfer(reward);

        emit RewardPaid(msg.sender, reward);
    }

    // 取款
    function withdraw(uint256 amount) external checkStart updateCumulativeRewardPerStoredToken {
        stakingInfo storage staker = staked[msg.sender];

        require(staker.coins > 0, "You need to stake first");
        require(staker.coins.sub(amount) >= 0, "Your stake balance is not enough");
        require(totalStake.sub(amount) >= 0, "Your stake balance is not enough");

        // 计算收益
        uint256 reward = staker.coins.mul(
            cumulativeRewardPerStoredToken.sub(staker.userCumulativeRevenuePerToken)
        ).div(1e18);
        reward = reward.add(staker.reward);

        staker.reward = 0;
        staker.coins = staker.coins.sub(amount);
        staker.lastWithdrawProfitsBlock = block.number;
        staker.userCumulativeRevenuePerToken = cumulativeRewardPerStoredToken;
        staker.userRewardPerTokenPaid = staker.userRewardPerTokenPaid.add(reward);

        uint256 total = reward.add(amount);
        address payable stakerAddr = payable(msg.sender);
        totalStake = totalStake.sub(amount);

        stakerAddr.transfer(total);

        emit Withdrawn(msg.sender, amount, reward);
    }

    // 退出
    function exit() external {
        this.withdraw(staked[msg.sender].coins);
    }

    // 获取最后一次更新区块到当前区块的质押总收益
    function getBlockNumberReward(uint256 _lastBlockNumber) private view returns (uint256){
        uint reward;
        for (uint i = _lastBlockNumber + 1; i <= block.number; i++) {
            reward = reward.add(validator.stakeRewardByBlockNumber(i));
        }
        return reward;
    }

    // 获取质押者信息
    function getStakingInfo(address account) external view
    returns (
        uint256,
        uint256,
        uint256
    ){
      return (
        staked[account].coins,
        staked[account].lastWithdrawProfitsBlock,
        staked[account].userRewardPerTokenPaid
      );
    }


    // 开关
    function StartAndShutdown(bool _start,uint256 _lastBlockNumber) external checkManage {
        start = _start;
        lastBlockNumber = _lastBlockNumber;
    }

    receive() external payable {
    }
}