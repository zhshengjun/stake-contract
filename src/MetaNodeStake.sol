// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract MetaNodeStake is Initializable, UUPSUpgradeable, PausableUpgradeable, AccessControlUpgradeable {
    using SafeERC20 for IERC20;
    using Address for address;
    using Math for uint256;

    /**
     * 质押的池子
     */
    struct Pool {
        // 质押代币的地址
        address stTokenAddress;

        // 不同资金池所占的权重,我理解这个用于分配每个区块的奖励
        // 流动性高的币权重高一些
        uint256 poolWeight;

        // 针对该矿池进行 MetaNodes 分发的最后一个区块号
        uint256 lastRewardBlock;
        // 当前池中，每单位质押代币累计获得的 MetaNode 奖励，精度放大 1e18
        uint256 accMetaNodePerST;

        // 质押的代币数量
        uint256 stTokenAmount;
        // 最小质押数量
        uint256 minDepositAmount;

        // 解质押锁定的区块高度，必须质押的高度超过这个才允许解锁提现
        uint256 unstakeLockedBlocks;
    }

    struct UnstakeRequest {
        // 用户取消质押的代币数量，要取出多少个 token
        uint256 amount;
        // 解质押时的区块高度，也就是当前高度高于这个值就可以
        uint256 unlockBlocks;
    }

    /**
     * 记录用户相对每个资金池 的质押记录
     */
    struct User {
        // 当前资金池，用户质押的代币数量
        uint256 stAmount;
        // 当前资金池，用户已经领取的 MetaNode 数量
        uint256 finishedMetaNode;
        // 当前资金池，用户当前可领取的 MetaNode 数量
        uint256 pendingMetaNode;
        // 当前资金池，用户取消质押的记录
        UnstakeRequest[] requests;
    }

    // 角色的solt
    bytes32 public constant ADMIN_ROLE = keccak256("admin_role");
    bytes32 public constant UPGRADE_ROLE = keccak256("upgrade_role");

    uint256 public constant ETH_PID = 0;
    // 这里为了精度，
    uint256 private constant ACC_PRECISION = 1 ether;

    // 质押开始区块高度
    uint256 public startBlock;
    // 质押结束区块高度
    uint256 public endBlock;
    // 每个区块高度，MetaNode 的奖励数量
    uint256 public metaNodePerBlock;

    // 是否暂停提现
    bool public withdrawPaused;
    // 是否暂停领取
    bool public claimPaused;

    // MetaNode 代币地址，用于奖励分发
    IERC20 public metaNode;

    // 所有资金池的权重总和，这个不是很理解,
    uint256 public totalPoolWeight;

    // 资金池列表
    Pool[] public pool;
    // 资金池 id（索引） => 用户地址 => 用户信息
    mapping(uint256 => mapping(address => User)) public user;

    // 需要考虑一个问题，用户怎么知道自己质押了哪些币，用户账户只有质押的币，用户取回时，怎么友好的看

    // ************************************** EVENT **************************************

    event UpdateMetaNode(IERC20 indexed metaNode);

    event PauseWithdraw();

    event UnpauseWithdraw();

    event PauseClaim();

    event UnpauseClaim();

    event SetStartBlock(uint256 indexed startBlock);

    event SetEndBlock(uint256 indexed endBlock);

    event SetMetaNodePerBlock(uint256 indexed metaNodePerBlock);

    event AddPool(
        address indexed stTokenAddress,
        uint256 indexed poolWeight,
        uint256 indexed lastRewardBlock,
        uint256 minDepositAmount,
        uint256 unstakeLockedBlocks
    );

    event UpdatePoolInfo(uint256 indexed poolId, uint256 indexed minDepositAmount, uint256 indexed unstakeLockedBlocks);

    event SetPoolWeight(uint256 indexed poolId, uint256 indexed poolWeight, uint256 totalPoolWeight);

    event UpdatePool(uint256 indexed poolId, uint256 indexed lastRewardBlock, uint256 totalMetaNode);

    event Deposit(address indexed user, uint256 indexed poolId, uint256 amount);

    event RequestUnstake(address indexed user, uint256 indexed poolId, uint256 amount);

    event Withdraw(address indexed user, uint256 indexed poolId, uint256 amount, uint256 indexed blockNumber);

    event Claim(address indexed user, uint256 indexed poolId, uint256 MetaNodeReward);

    // ************************************** ERROR **************************************

    error InvalidPid(uint256 pid);
    error StartMustSmallerThanEnd();

    error WithdrawPaused();
    error WithdrawAlreadyPaused();
    error WithdrawAlreadyUnPaused();

    error ClaimPaused();
    error ClaimAlreadyPaused();
    error ClaimAlreadyUnPaused();

    // ************************************** MODIFIER **************************************

    modifier checkPid(uint256 _pid) {
        // forge-lint: disable-next-line(require-revert-in-loop)
        require(_pid < pool.length, InvalidPid(_pid));
        _;
    }

    modifier whenNotClaimPaused() {
        require(!claimPaused, ClaimPaused());
        _;
    }

    modifier whenNotWithdrawPaused() {
        require(!withdrawPaused, WithdrawPaused());
        _;
    }

    /**
     * 构造器
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * 初始化
     */
    function initialize(IERC20 _metaNode, uint256 _startBlock, uint256 _endBlock, uint256 _metaNodePerBlock)
        external
        initializer
    {
        require(_startBlock <= _endBlock, StartMustSmallerThanEnd());

        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADE_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        metaNode = _metaNode;
        metaNodePerBlock = _metaNodePerBlock;

        startBlock = _startBlock;
        endBlock = _endBlock;
    }

    /**
     * 权限认证
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADE_ROLE) {}

    /**
     * @notice Pause withdraw. Can only be called by admin.
     */
    function pauseWithdraw() external onlyRole(ADMIN_ROLE) {
        require(!withdrawPaused, WithdrawPaused());
        withdrawPaused = true;
        // forge-lint: disable-next-line(reentrancy-events)
        emit PauseWithdraw();
    }

    /**
     * @notice Unpause withdraw. Can only be called by admin.
     */
    function unpauseWithdraw() external onlyRole(ADMIN_ROLE) {
        require(withdrawPaused, WithdrawAlreadyUnPaused());
        withdrawPaused = false;
        // forge-lint: disable-next-line(reentrancy-events)
        emit UnpauseWithdraw();
    }

    /**
     * @notice Pause claim. Can only be called by admin.
     */
    function pauseClaim() external onlyRole(ADMIN_ROLE) {
        require(!claimPaused, ClaimAlreadyPaused());
        claimPaused = true;
        // forge-lint: disable-next-line(reentrancy-events)
        emit PauseClaim();
    }

    /**
     * @notice Unpause claim. Can only be called by admin.
     */
    function unpauseClaim() external onlyRole(ADMIN_ROLE) {
        require(claimPaused, ClaimAlreadyUnPaused());
        claimPaused = false;
        // forge-lint: disable-next-line(reentrancy-events)
        emit UnpauseClaim();
    }

    /**
     * 更新区块奖励
     */
    function updateMetaNodePerBlock(uint256 _metaNodePerBlock) external onlyRole(ADMIN_ROLE) {
        require(_metaNodePerBlock > 0, "invalid parameter");

        refreshPools();
        metaNodePerBlock = _metaNodePerBlock;
        // forge-lint: disable-next-line(reentrancy-events)
        emit SetMetaNodePerBlock(_metaNodePerBlock);
    }

    /**
     * @notice Update staking start block. Can only be called by admin.
     */
    function setStartBlock(uint256 _startBlock) external onlyRole(ADMIN_ROLE) {
        require(_startBlock <= endBlock, StartMustSmallerThanEnd());
        refreshPools();
        startBlock = _startBlock;
        // forge-lint: disable-next-line(reentrancy-events)
        emit SetStartBlock(_startBlock);
    }

    /**
     * @notice Update staking end block. Can only be called by admin.
     */
    function setEndBlock(uint256 _endBlock) external onlyRole(ADMIN_ROLE) {
        require(startBlock <= _endBlock, StartMustSmallerThanEnd());
        refreshPools();
        endBlock = _endBlock;
        // forge-lint: disable-next-line(reentrancy-events)
        emit SetEndBlock(_endBlock);
    }

    /**
     * @notice Add a new staking to pool. Can only be called by admin
     * DO NOT add the same staking token more than once. MetaNode rewards will be messed up if you do
     */
    function addPool(
        address _stTokenAddress,
        uint256 _poolWeight,
        uint256 _minDepositAmount,
        uint256 _unstakeLockedBlocks
    ) external onlyRole(ADMIN_ROLE) {
        // 质押池，首个限制为原生代币ETH
        if (pool.length > 0) {
            require(_stTokenAddress != address(0x0), "invalid staking token address");
        } else {
            require(_stTokenAddress == address(0x0), "invalid staking token address");
        }

        // 奖金池不允许添加进去
        require(_stTokenAddress != address(metaNode), "reward token not allowed to add pool");

        // 权重要大于0，不然有什么意义呢，也会对pool刷新有影响，因为总权重是0
        require(_poolWeight > 0, "invalid pool weight");

        // 最小质押数必须大于0
        require(_unstakeLockedBlocks > 0, "invalid withdraw locked blocks");

        // 结束块之后，不允许添加质押池
        require(block.number < endBlock, "Already ended");

        // 刷新，因为这里新增了pool，权重变化，将之前的 accMetaNodePerST 计算出来
        refreshPools();

        // 添加质押池
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalPoolWeight = totalPoolWeight + _poolWeight;
        pool.push(
            Pool({
                stTokenAddress: _stTokenAddress,
                poolWeight: _poolWeight,
                lastRewardBlock: lastRewardBlock,
                accMetaNodePerST: 0,
                stTokenAmount: 0,
                minDepositAmount: _minDepositAmount,
                unstakeLockedBlocks: _unstakeLockedBlocks
            })
        );
        // 发送事件
        // forge-lint: disable-next-line(reentrancy-events)
        emit AddPool(_stTokenAddress, _poolWeight, lastRewardBlock, _minDepositAmount, _unstakeLockedBlocks);
    }

    /**
     * @notice Update reward variables for all pools. Be careful of gas spending!
     */
    function refreshPools() public {
        uint256 length = pool.length;
        for (uint256 pid = 0; pid < length; pid++) {
            _refreshPool(pid);
        }
    }

    /**
     * @notice 更新质押池，限制只能更新更新金额和质押高度
     */
    function updatePool(uint256 _pid, uint256 _minDepositAmount, uint256 _unstakeLockedBlocks)
        public
        onlyRole(ADMIN_ROLE)
        checkPid(_pid)
    {
        // 这是否需要限制 解锁区块高度，若降低解质押锁定期会破坏提现队列顺序
        pool[_pid].minDepositAmount = _minDepositAmount;
        pool[_pid].unstakeLockedBlocks = _unstakeLockedBlocks;

        // forge-lint: disable-next-line(reentrancy-events)
        emit UpdatePoolInfo(_pid, _minDepositAmount, _unstakeLockedBlocks);
    }

    /**
     * @notice 更新权重
     */
    function setPoolWeight(uint256 _pid, uint256 _poolWeight) public onlyRole(ADMIN_ROLE) checkPid(_pid) {
        require(_poolWeight > 0, "invalid pool weight");

        refreshPools();

        totalPoolWeight = totalPoolWeight - pool[_pid].poolWeight + _poolWeight;
        pool[_pid].poolWeight = _poolWeight;

        // forge-lint: disable-next-line(reentrancy-events)
        emit SetPoolWeight(_pid, _poolWeight, totalPoolWeight);
    }

    /**
     * @notice 获取质押池的长度
     */
    function poolLength() external view returns (uint256) {
        return pool.length;
    }

    /**
     * @notice 获取用户质押池累计的奖励
     */
    function pendingMetaNode(uint256 _pid, address _user) external view checkPid(_pid) returns (uint256) {
        return _pendingMetaNodeByBlockNumber(_pid, _user, block.number);
    }

    /**
     * @notice 获取用户的质押余额
     */
    function stakingBalance(uint256 _pid, address _user) external view checkPid(_pid) returns (uint256) {
        return user[_pid][_user].stAmount;
    }

    /**
     * @notice 取回质押已经满足区块的token
     */
    function withdrawAmount(uint256 _pid, address _user)
        public
        view
        checkPid(_pid)
        returns (uint256 requestAmount, uint256 pendingWithdrawAmount)
    {
        requestAmount = 0;
        pendingWithdrawAmount = 0;
        User storage user_ = user[_pid][_user];

        for (uint256 i = 0; i < user_.requests.length; i++) {
            if (user_.requests[i].unlockBlocks <= block.number) {
                pendingWithdrawAmount = pendingWithdrawAmount + user_.requests[i].amount;
            }
            requestAmount = requestAmount + user_.requests[i].amount;
        }
    }

    /**
     * @notice 质押ETH
     */
    function depositETH() public payable whenNotPaused {
        Pool storage pool_ = pool[ETH_PID];
        require(pool_.stTokenAddress == address(0x0), "invalid staking token address");

        uint256 _amount = msg.value;
        require(_amount >= pool_.minDepositAmount, "deposit amount is too small");

        _deposit(ETH_PID, _amount);
    }

    /**
     * @notice 质押 ERC20
     */
    function deposit(uint256 _pid, uint256 _amount) public whenNotPaused checkPid(_pid) {
        require(_pid != 0, "deposit not support ETH staking");
        Pool storage pool_ = pool[_pid];
        require(_amount > pool_.minDepositAmount, "deposit amount is too small");

        // 需要用户提前执行 approve
        if (_amount > 0) {
            IERC20(pool_.stTokenAddress).safeTransferFrom(msg.sender, address(this), _amount);
        }

        // 质押逻辑
        _deposit(_pid, _amount);
    }

    /**
     * @notice 解质押
     */
    function unstake(uint256 _pid, uint256 _amount) public whenNotPaused checkPid(_pid) whenNotWithdrawPaused {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        require(user_.stAmount >= _amount, "Not enough staking token balance");

        // 把历史的 accMetaNodePerST 先计算了
        _refreshPool(_pid);

        // 用户最新的待领取的奖励
        uint256 pendingMetaNode_ = _accumulatedReward(user_.stAmount, pool_.accMetaNodePerST) - user_.finishedMetaNode;

        if (pendingMetaNode_ > 0) {
            user_.pendingMetaNode += pendingMetaNode_;
        }

        // 减去质押金额
        if (_amount > 0) {
            user_.stAmount -= _amount;
            user_.requests
                .push(UnstakeRequest({amount: _amount, unlockBlocks: block.number + pool_.unstakeLockedBlocks}));
        }

        pool_.stTokenAmount -= _amount;
        user_.finishedMetaNode = _accumulatedReward(user_.stAmount, pool_.accMetaNodePerST);

        // forge-lint: disable-next-line(reentrancy-events)
        emit RequestUnstake(msg.sender, _pid, _amount);
    }

    /**
     * @notice 这里将到期的质押取回
     */
    function withdraw(uint256 _pid) public whenNotPaused checkPid(_pid) whenNotWithdrawPaused {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        uint256 pendingWithdraw_ = 0;
        uint256 popNum_ = 0;
        // 累加到期的质押，也就是满足区块长度的质押
        for (uint256 i = 0; i < user_.requests.length; i++) {
            if (user_.requests[i].unlockBlocks > block.number) {
                break;
            }
            pendingWithdraw_ = pendingWithdraw_ + user_.requests[i].amount;
            popNum_++;
        }

        // 复制后面的申请记录
        for (uint256 i = 0; i < user_.requests.length - popNum_; i++) {
            user_.requests[i] = user_.requests[i + popNum_];
        }

        // 清理已经被复制的记录
        for (uint256 i = 0; i < popNum_; i++) {
            user_.requests.pop();
        }

        // 如果取回的不为0，则进行打款逻辑
        if (pendingWithdraw_ > 0) {
            if (pool_.stTokenAddress == address(0x0)) {
                _safeETHTransfer(msg.sender, pendingWithdraw_);
            } else {
                IERC20(pool_.stTokenAddress).safeTransfer(msg.sender, pendingWithdraw_);
            }
        }

        // forge-lint: disable-next-line(reentrancy-events)
        emit Withdraw(msg.sender, _pid, pendingWithdraw_, block.number);
    }

    /**
     * @notice Claim MetaNode tokens reward
     *
     * @param _pid       Id of the pool to be claimed from
     */
    function claim(uint256 _pid) public whenNotPaused checkPid(_pid) whenNotClaimPaused {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        _refreshPool(_pid);

        uint256 accumulatedMetaNode = _accumulatedReward(user_.stAmount, pool_.accMetaNodePerST);
        uint256 pendingMetaNode_ = accumulatedMetaNode - user_.finishedMetaNode + user_.pendingMetaNode;

        // 先更新状态，避免 transfer 回调重复领取同一段奖励
        user_.finishedMetaNode = accumulatedMetaNode;

        // 先清零，防止重入
        user_.pendingMetaNode = 0;

        uint256 transAmount = 0;
        if (pendingMetaNode_ > 0) {
            transAmount = _safeMetaNodeTransfer(msg.sender, pendingMetaNode_);
            if (transAmount < pendingMetaNode_) {
                user_.pendingMetaNode += pendingMetaNode_ - transAmount;
            }
        }

        // forge-lint: disable-next-line(reentrancy-events)
        emit Claim(msg.sender, _pid, transAmount);
    }

    /**
     * @notice 刷型质押池
     */
    function _refreshPool(uint256 _pid) private checkPid(_pid) {
        Pool storage pool_ = pool[_pid];

        uint256 rewardTo = Math.min(block.number, endBlock);

        if (rewardTo <= pool_.lastRewardBlock) {
            return;
        }

        // 获取奖励倍速
        uint256 totalMetaNode =
            Math.mulDiv(_getRewardMultiplier(pool_.lastRewardBlock, block.number), pool_.poolWeight, totalPoolWeight);
        // 当前池的总质押数
        uint256 stSupply = pool_.stTokenAmount;
        if (stSupply > 0) {
            uint256 totalMetaNode_ = _rewardPerST(totalMetaNode, stSupply);

            (bool addSuccess, uint256 accMetaNodePerST) = pool_.accMetaNodePerST.tryAdd(totalMetaNode_);
            // forge-lint: disable-next-line(require-revert-in-loop)
            require(addSuccess, "overflow");
            pool_.accMetaNodePerST = accMetaNodePerST;
        }
        // 最后计算的block块
        pool_.lastRewardBlock = rewardTo;

        // forge-lint: disable-next-line(reentrancy-events)
        emit UpdatePool(_pid, pool_.lastRewardBlock, totalMetaNode);
    }

    /**
     * @notice 计算用户某一个池子的奖励
     *
     */
    function _pendingMetaNodeByBlockNumber(uint256 _pid, address _user, uint256 _blockNumber)
        private
        view
        checkPid(_pid)
        returns (uint256)
    {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][_user];
        uint256 accMetaNodePerST = pool_.accMetaNodePerST;
        uint256 stSupply = pool_.stTokenAmount;

        // 如果存在池中计算的区块数落后，需要累加上
        if (_blockNumber > pool_.lastRewardBlock && stSupply != 0) {
            uint256 metaNodeForPool = Math.mulDiv(
                _getRewardMultiplier(pool_.lastRewardBlock, _blockNumber), pool_.poolWeight, totalPoolWeight
            );

            accMetaNodePerST = accMetaNodePerST + _rewardPerST(metaNodeForPool, stSupply);
        }

        return _accumulatedReward(user_.stAmount, accMetaNodePerST) - user_.finishedMetaNode + user_.pendingMetaNode;
    }

    /**
     * @notice 质押逻辑
     *
     */
    function _deposit(uint256 _pid, uint256 _amount) internal {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        // 先把历史的 accMetaNodePerST 计算
        _refreshPool(_pid);

        // 如果已经存在质押，则先计算出  pendingMetaNode 和 finishedMetaNode
        // pendingMetaNode =  (stAmount * accMetaNodePerST) - finishedMetaNode(更新前) + pendingMetaNode（更新前）
        // finishedMetaNode（更新后） = stAmount * accMetaNodePerST
        // 计算奖励时：  (stAmount * accMetaNodePerST) - finishedMetaNode + pendingMetaNode
        if (user_.stAmount > 0) {
            uint256 currentReward = _accumulatedReward(user_.stAmount, pool_.accMetaNodePerST);

            (bool success2, uint256 pendingMetaNode_) = currentReward.trySub(user_.finishedMetaNode);
            require(success2, "currentReward sub finishedMetaNode overflow");

            if (pendingMetaNode_ > 0) {
                (bool success3, uint256 _pendingMetaNode) = user_.pendingMetaNode.tryAdd(pendingMetaNode_);
                require(success3, "user pendingMetaNode overflow");
                user_.pendingMetaNode = _pendingMetaNode;
            }
        }

        // 累加总额
        if (_amount > 0) {
            (bool success4, uint256 stAmount) = user_.stAmount.tryAdd(_amount);
            require(success4, "user stAmount overflow");
            user_.stAmount = stAmount;
        }

        (bool success5, uint256 stTokenAmount) = pool_.stTokenAmount.tryAdd(_amount);
        require(success5, "pool stTokenAmount overflow");
        pool_.stTokenAmount = stTokenAmount;

        user_.finishedMetaNode = _accumulatedReward(user_.stAmount, pool_.accMetaNodePerST);

        // forge-lint: disable-next-line(reentrancy-events)
        emit Deposit(msg.sender, _pid, _amount);
    }

    /**
     * @notice 转账
     */
    function _safeMetaNodeTransfer(address _to, uint256 _amount) internal returns (uint256) {
        uint256 contractTokenBalance = metaNode.balanceOf(address(this));

        uint256 transAmount = _amount > contractTokenBalance ? contractTokenBalance : _amount;

        bool success = metaNode.transfer(_to, transAmount);
        require(success, "MetaNode Transfer failed");
        return transAmount;
    }

    /**
     * @notice 发送ETH
     */
    function _safeETHTransfer(address _to, uint256 _amount) internal {
        // forge-lint: disable-next-line(arbitrary-send-eth)
        (bool success,) = payable(_to).call{value: _amount}("");
        require(success, "ETH transfer call failed");
    }

    /**
     * @notice 就是计算区块的层数 * 设定每个区块的奖励
     */
    function _getRewardMultiplier(uint256 _from, uint256 _to) private view returns (uint256 multiplier) {
        // forge-lint: disable-next-line(require-revert-in-loop)
        require(_from <= _to, "invalid block");
        if (_from < startBlock) {
            _from = startBlock;
        }
        if (_to > endBlock) {
            _to = endBlock;
        }
        // forge-lint: disable-next-line(require-revert-in-loop)
        require(_from <= _to, "end block must be greater than start block");
        bool success = false;
        (success, multiplier) = (_to - _from).tryMul(metaNodePerBlock);
        // forge-lint: disable-next-line(require-revert-in-loop)
        require(success, "multiplier overflow");
    }

    /**
     *
     *
     * @notice 池中的奖励，精度放大，防止出现小数
     */
    function _rewardPerST(uint256 reward, uint256 stSupply) private pure returns (uint256) {
        return Math.mulDiv(reward, ACC_PRECISION, stSupply);
    }

    /**
     *
     * @notice 领取的奖励，精度需要缩小
     */
    function _accumulatedReward(uint256 stAmount, uint256 accMetaNodePerST) private pure returns (uint256) {
        return Math.mulDiv(stAmount, accMetaNodePerST, ACC_PRECISION);
    }
}
