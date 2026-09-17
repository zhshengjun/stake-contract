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
        address tokenAddress;

        // 不同资金池所占的权重
        uint256 poolWeight;

        // 针对该矿池进行 MetaNodes 分发的最后一个区块号
        uint256 lastRewardBlock;
        // 质押 1个ETH经过1个区块高度，能拿到 n 个MetaNode,也就是奖励
        uint256 accMetaNodePerST;

        // 质押的代币数量
        uint256 stTokenAmount;

        // 最小质押数量
        uint256 minDepositAmount;

        // Unstake locked blocks 解质押锁定的区块高度
        uint256 unstakeLockedBlocks;
    }

    struct UnstakeRequest {
        // 用户取消质押的代币数量，要取出多少个 token
        uint256 amount;
        // 解质押的区块高度
        uint256 unlockBlocks;
    }

    /**
     * 记录用户相对每个资金池 的质押记录
     */
    struct User {
        // 当前资金池，用户质押的代币数量
        uint256 amount;
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
    // 所有资金池的权重总和，这个不是很理解
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

    event UpdateStartBlock(uint256 indexed startBlock);

    event UpdateEndBlock(uint256 indexed endBlock);

    event UpdateMetaNodePerBlock(uint256 indexed metaNodePerBlock);

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

        updateMetaNode(_metaNode);
        updateMetaNodePerBlock(_metaNodePerBlock);

        updateStartBlock(_startBlock);
        updateEndBlock()(_endBlock);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADE_ROLE) {}

    /**
     * @notice Set MetaNode token address. Can only be called by admin
     */
    function updateMetaNode(IERC20 _metaNode) public onlyRole(ADMIN_ROLE) {
        metaNode = _metaNode;
        emit updateMetaNode(_metaNode);
    }

    function updateMetaNodePerBlock(uint256 _metaNodePerBlock) public onlyRole(ADMIN_ROLE) {
        require(_metaNodePerBlock > 0, "invalid parameter");
        metaNodePerBlock = _metaNodePerBlock;
        emit UpdateMetaNodePerBlock(_metaNodePerBlock);
    }

    /**
     * @notice Pause withdraw. Can only be called by admin.
     */
    function pauseWithdraw() external onlyRole(ADMIN_ROLE) {
        require(!withdrawPaused, WithdrawPaused());
        withdrawPaused = true;
        emit PauseWithdraw();
    }

    /**
     * @notice Unpause withdraw. Can only be called by admin.
     */
    function unpauseWithdraw() external onlyRole(ADMIN_ROLE) {
        require(withdrawPaused, WithdrawAlreadyUnPaused());
        withdrawPaused = false;
        emit UnpauseWithdraw();
    }

    /**
     * @notice Pause claim. Can only be called by admin.
     */
    function pauseClaim() external onlyRole(ADMIN_ROLE) {
        require(!claimPaused, ClaimAlreadyPaused());
        claimPaused = true;
        emit PauseClaim();
    }

    /**
     * @notice Unpause claim. Can only be called by admin.
     */
    function unpauseClaim() external onlyRole(ADMIN_ROLE) {
        require(claimPaused, ClaimAlreadyUnPaused());
        claimPaused = false;
        emit UnpauseClaim();
    }

    /**
     * @notice Update staking start block. Can only be called by admin.
     */
    function updateStartBlock(uint256 _startBlock) public onlyRole(ADMIN_ROLE) {
        require(_startBlock <= endBlock, StartMustSmallerThanEnd());
        startBlock = _startBlock;
        emit UpdateStartBlock(_startBlock);
    }

    /**
     * @notice Update staking end block. Can only be called by admin.
     */
    function updateEndBlock(uint256 _endBlock) public onlyRole(ADMIN_ROLE) {
        require(startBlock <= _endBlock, StartMustSmallerThanEnd());
        endBlock = _endBlock;
        emit UpdateEndBlock(_endBlock);
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
        // Default the first pool to be ETH pool, so the first pool must be added with stTokenAddress = address(0x0)
        if (pool.length > 0) {
            require(_stTokenAddress != address(0x0), "invalid staking token address");
        } else {
            require(_stTokenAddress == address(0x0), "invalid staking token address");
        }
        // allow the min deposit amount equal to 0
        require(_unstakeLockedBlocks > 0, "invalid withdraw locked blocks");
        require(block.number < endBlock, "Already ended");

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

        emit AddPool(_stTokenAddress, _poolWeight, lastRewardBlock,
            _minDepositAmount, _unstakeLockedBlocks);

        // 刷新
        refreshPools();
    }

    /**
     * @notice Update reward variables for all pools. Be careful of gas spending!
     */
    function refreshPools() public {
        uint256 length = pool.length;
        for (uint256 pid = 0; pid < length; pid++) {
            updatePool(pid);
        }
    }

    /**
     * @notice Update the given pool's info (minDepositAmount and unstakeLockedBlocks). Can only be called by admin.
     */
    function updatePool(uint256 _pid, uint256 _minDepositAmount, uint256 _unstakeLockedBlocks)
    public
    onlyRole(ADMIN_ROLE)
    checkPid(_pid)
    {
        pool[_pid].minDepositAmount = _minDepositAmount;
        pool[_pid].unstakeLockedBlocks = _unstakeLockedBlocks;

        emit UpdatePoolInfo(_pid, _minDepositAmount, _unstakeLockedBlocks);
    }

    /**
     * @notice Update reward variables of the given pool to be up-to-date.
     */
    function updatePool(uint256 _pid) public checkPid(_pid) {
        Pool storage pool_ = pool[_pid];

        if (block.number <= pool_.lastRewardBlock) {
            return;
        }

        (bool success, uint256 totalMetaNode) =
                                _getRewardMultiplier(pool_.lastRewardBlock, block.number).tryMul(pool_.poolWeight);
        require(success, "overflow");

        (success, totalMetaNode) = totalMetaNode.tryDiv(totalPoolWeight);
        require(success, "overflow");

        uint256 stSupply = pool_.stTokenAmount;
        if (stSupply > 0) {
            (bool success, uint256 totalMetaNode_) = totalMetaNode.tryMul(1 ether);
            require(success, "overflow");

            (success, totalMetaNode_) = totalMetaNode_.tryDiv(stSupply);
            require(success, "overflow");

            (bool success, uint256 accMetaNodePerST) = pool_.accMetaNodePerST.tryAdd(totalMetaNode_);
            require(success, "overflow");
            pool_.accMetaNodePerST = accMetaNodePerST;
        }

        pool_.lastRewardBlock = block.number;

        emit UpdatePool(_pid, pool_.lastRewardBlock, totalMetaNode);
    }

    /**
     * @notice Return reward multiplier over given _from to _to block. [_from, _to)
     *
     * @param _from    From block number (included)
     * @param _to      To block number (exluded)
     * _getRewardMultiplier(pool_.lastRewardBlock, block.number).tryMul(pool_.poolWeight);
     */
    function _getRewardMultiplier(uint256 _from, uint256 _to) private view returns (uint256 multiplier) {
        require(_from <= _to, "invalid block");
        if (_from < startBlock) {
            _from = startBlock;
        }
        if (_to > endBlock) {
            _to = endBlock;
        }
        require(_from <= _to, "end block must be greater than start block");
        bool success;
        (success, multiplier) = (_to - _from).tryMul(metaNodePerBlock);
        require(success, "multiplier overflow");
    }
}
