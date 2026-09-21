// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {MetaNodeStake} from "../src/MetaNodeStake.sol";
import {MetaNodeToken} from "../src/MetaNodeToken.sol";
import {MultiSigWallet} from "../src/MultiSigWallet.sol";
import {MyToken} from "./MetaNodeStake.t.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {StdChains} from "forge-std/StdChains.sol";
import {StdCheats, StdCheatsSafe} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

contract MyToken is ERC20 {
    constructor() ERC20("MyToken", "MyToken") {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract MetaNodeStakeV2 is MetaNodeStake {
    uint256 public maxDepositAmount;

    function initializeV2(uint256 _maxDepositAmount) external reinitializer(2) {
        maxDepositAmount = _maxDepositAmount;
    }
}

contract MetaNodeStakePrecisionTest is Test {
    address public learn = 0xb58bbA2158cD9E2d52985D21e863217941600734;
    address public alice = 0x12AFAaa63A92bfe7fFEe7881a10b49EeC4a2F762;
    address public tim = 0xc2b6c20651dA38CBfCf3279deCD634ab147c0AaD;
    address public owner;

    // 质押合约
    MetaNodeStake public stake;
    MultiSigWallet public multiSigWallet;
    // 奖励币
    MetaNodeToken public metaNode;

    MyToken public myToken;

    uint256 public startBlock;
    uint256 public endBlock;

    function setUp() public {
        startBlock = vm.getBlockNumber();
        endBlock = startBlock + 1_0000;
        owner = address(this);

        // 部署奖励代币
        metaNode = new MetaNodeToken(learn);
        MetaNodeStake implementation = new MetaNodeStake();

        // 多签钱包
        address[] memory owners = new address[](3);
        owners[0] = address(this);
        owners[1] = alice;
        owners[2] = tim;
        multiSigWallet = new MultiSigWallet(owners, 2);

        myToken = new MyToken();
        // 构建 abi编码
        bytes memory initData = abi.encodeCall(
            MetaNodeStake.initialize,
            (IERC20(address(metaNode)), startBlock, endBlock, 1 ether, address(multiSigWallet))
        );

        // 就是代理什么合约，调用的初始化函数是哪个
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        // 这个就是 将 proxy 包装成一个 质押合约，注意这里没有new
        stake = MetaNodeStake(address(proxy));

        // 给质押合约准备奖励 Token
        uint256 rewardBalance = metaNode.balanceOf(learn);
        vm.prank(learn);
        metaNode.transfer(address(stake), rewardBalance);
    }

    function initPool() private {
        // 添加ETH
        stake.addPool(address(0x0), 50, 1 ether * 0.01, 100);
        // 添加首个测试币
        stake.addPool(address(myToken), 50, 1 ether, 100);
    }

    function mintToken(address to, uint256 amount) private {
        // 先mint
        myToken.mint(to, amount);
    }

    // 测试初始化逻辑
    function test_SetUp() public view {
        assertEq(address(stake.metaNode()), address(metaNode));
        assertEq(stake.startBlock(), startBlock);
        assertEq(stake.endBlock(), endBlock);
        assertEq(stake.metaNodePerBlock(), 1 ether);
        assertTrue(stake.hasRole(stake.ADMIN_ROLE(), address(this)));
        assertTrue(stake.hasRole(stake.DEFAULT_ADMIN_ROLE(), address(multiSigWallet)));
        assertTrue(stake.hasRole(stake.UPGRADE_ROLE(), address(multiSigWallet)));
        assertFalse(stake.hasRole(stake.UPGRADE_ROLE(), address(this)));
    }

    function test_authorizeUpgrade() public {
        // 必须在 expectRevert 之前部署
        MetaNodeStakeV2 newImplementation = new MetaNodeStakeV2();
        bytes memory initializeData = abi.encodeCall(MetaNodeStakeV2.initializeV2, (100 ether));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, learn, stake.UPGRADE_ROLE()
            )
        );

        vm.prank(learn);
        stake.upgradeToAndCall(address(newImplementation), initializeData);

        bytes memory upgradeData = abi.encodeCall(stake.upgradeToAndCall, (address(newImplementation), initializeData));
        uint256 transactionId = multiSigWallet.submitTransaction(address(stake), 0, upgradeData);

        vm.prank(alice);
        multiSigWallet.confirmTransaction(transactionId);
        multiSigWallet.executeTransaction(transactionId);

        assertEq(MetaNodeStakeV2(address(stake)).maxDepositAmount(), 100 ether);

        // 这是获取真正代理的地址
        bytes32 implementationSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        bytes32 implementationValue = vm.load(address(stake), implementationSlot);
        address actualImplementation = address(uint160(uint256(implementationValue)));
        assertEq(actualImplementation, address(newImplementation));
    }

    // 测试无权，无admin角色
    function test_AdminRole() public {
        vm.startPrank(learn);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, learn, stake.ADMIN_ROLE())
        );
        //vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        stake.pauseWithdraw();

        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        stake.unpauseWithdraw();

        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        stake.pauseClaim();

        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        stake.unpauseClaim();

        vm.stopPrank();
    }

    // 测试重复暂停
    function test_PauseState() public {
        // 直接取消暂停
        vm.expectPartialRevert(MetaNodeStake.WithdrawAlreadyUnPaused.selector);
        stake.unpauseWithdraw();
        // 重复暂停
        stake.pauseWithdraw();
        vm.expectPartialRevert(MetaNodeStake.WithdrawPaused.selector);
        stake.pauseWithdraw();

        vm.expectPartialRevert(MetaNodeStake.ClaimAlreadyUnPaused.selector);
        stake.unpauseClaim();

        stake.pauseClaim();
        vm.expectPartialRevert(MetaNodeStake.ClaimAlreadyPaused.selector);
        stake.pauseClaim();
    }

    function test_MetaNodePerBlock() public {
        vm.prank(learn);
        // 修改MetaNodePerBlock的权限
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        stake.updateMetaNodePerBlock(12345);

        // 测试 block 填写的小于 0
        vm.expectRevert(bytes("invalid parameter"));
        stake.updateMetaNodePerBlock(0);

        vm.expectEmit(address(stake));
        // 注意，如果不是新版本，需要重新定义事件
        emit MetaNodeStake.SetMetaNodePerBlock(1234);
        stake.updateMetaNodePerBlock(1234);
    }

    function test_StartBlock() public {
        vm.prank(learn);
        // 调用 setStartBlock 的权限
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        stake.setStartBlock(vm.getBlockNumber());

        // 参数必须小于 endBlock
        vm.expectPartialRevert(MetaNodeStake.StartMustSmallerThanEnd.selector);
        stake.setStartBlock(vm.getBlockNumber() + 100000);

        vm.expectEmit(address(stake));
        emit MetaNodeStake.SetStartBlock(vm.getBlockNumber() + 10);
        stake.setStartBlock(vm.getBlockNumber() + 10);
    }

    function test_EndBlock() public {
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        vm.prank(learn);
        stake.setEndBlock(0);

        // 测试范围
        vm.expectPartialRevert(MetaNodeStake.StartMustSmallerThanEnd.selector);
        stake.setEndBlock(0);

        uint256 blockNumber = vm.getBlockNumber() + 300;
        vm.expectEmit(address(stake));
        emit MetaNodeStake.SetEndBlock(blockNumber);

        stake.setEndBlock(blockNumber);
        assertEq(stake.endBlock(), blockNumber);
    }

    function test_AddPool() public {
        // 权限
        vm.prank(learn);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        stake.addPool(address(0x0), 50, 1 ether, 100);

        // 添加的 首个不是 EHT
        vm.expectRevert(bytes("invalid staking token address"));
        stake.addPool(address(0x01), 50, 1 ether * 0.001, 100);

        // 添加首个
        stake.addPool(address(0x0), 50, 1 ether * 0.001, 100);

        // 添加第二个ETH报错
        vm.expectRevert(bytes("invalid staking token address"));
        stake.addPool(address(0x0), 20, 1 ether * 0.01, 100);

        // 测试添加奖金池
        vm.expectRevert(bytes("reward token not allowed to add pool"));
        stake.addPool(address(metaNode), 20, 1 ether * 0.1, 100);

        // 测试权重等于0了
        vm.expectRevert(bytes("invalid pool weight"));
        stake.addPool(address(myToken), 0, 1 ether * 0.1, 100);

        // 最小质押数
        vm.expectRevert(bytes("invalid min deposit amount"));
        stake.addPool(address(myToken), 1, 0, 100);

        // 最小区块数
        vm.expectRevert(bytes("invalid withdraw locked blocks"));
        stake.addPool(address(myToken), 1, 1 ether, 0);

        uint256 lastRewardBlock = vm.getBlockNumber() > startBlock ? vm.getBlockNumber() : startBlock;
        vm.expectEmit(address(stake));
        emit MetaNodeStake.AddPool(address(myToken), 1, lastRewardBlock, 1 ether, 1);
        stake.addPool(address(myToken), 1, 1 ether, 1);

        // 区块结束了
        vm.roll(endBlock);
        assertEq(vm.getBlockNumber(), endBlock);
        vm.expectRevert(bytes("Already ended"));
        stake.addPool(address(0x02), 1, 1, 1);
    }

    function test_UpdatePool() public {
        initPool();

        // 测试权限
        vm.prank(learn);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        stake.updatePool(0, 0.02 ether, 200);

        //测试ID不存在
        vm.expectRevert(abi.encodeWithSelector(MetaNodeStake.InvalidPid.selector, 10));
        stake.updatePool(10, 0.02 ether, 200);

        vm.expectEmit(address(stake));
        emit MetaNodeStake.UpdatePoolInfo(1, 5 ether, 50);
        stake.updatePool(1, 5 ether, 50);
    }

    function test_UpdatePoolWeight() public {
        initPool();

        // 测试权限
        vm.prank(learn);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        stake.setPoolWeight(0, 60);

        //测试ID不存在
        vm.expectRevert(abi.encodeWithSelector(MetaNodeStake.InvalidPid.selector, 10));
        stake.setPoolWeight(10, 60);

        // 测试权重为0
        vm.expectRevert(bytes("invalid pool weight"));
        stake.setPoolWeight(1, 0);

        vm.expectEmit(address(stake));
        emit MetaNodeStake.SetPoolWeight(1, 100, 150);
        stake.setPoolWeight(1, 100);
        assertEq(stake.totalPoolWeight(), 150);
    }

    function test_Deposit() public {
        initPool();
        //测试ID不存在
        vm.expectRevert(abi.encodeWithSelector(MetaNodeStake.InvalidPid.selector, 10));
        stake.deposit(10, 1 ether);

        // 测试暂停
        stake.pause();
        assertTrue(stake.paused());
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        stake.deposit(1, 1 ether);

        stake.unpause();
        // 测试质押 eth
        vm.expectRevert(bytes("deposit not support ETH staking"));
        stake.deposit(0, 0 ether);

        // 测试质押数量低于配置
        vm.expectRevert(bytes("deposit amount is too small"));
        stake.deposit(1, 0.5 ether);

        mintToken(learn, 50 ether);
        vm.startPrank(learn);
        myToken.approve(address(stake), 100 ether);

        // 正常质押
        vm.expectEmit(address(stake));
        emit MetaNodeStake.Deposit(learn, 1, 5 ether);

        stake.deposit(1, 5 ether);

        assertEq(myToken.balanceOf(learn), 45 ether);
        assertEq(myToken.balanceOf(address(stake)), 5 ether);

        vm.stopPrank();
    }

    function test_DepositEth() public payable {
        // 测试暂停
        stake.pause();
        assertTrue(stake.paused());
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        stake.depositETH();
        stake.unpause();

        initPool();

        // 质押 ETH
        vm.startPrank(learn);
        vm.deal(learn, 10 ether);
        vm.expectRevert(bytes("deposit amount is too small"));
        stake.depositETH{value: 0.001 ether}();

        // 正常质押
        vm.expectEmit(address(stake));
        emit MetaNodeStake.Deposit(learn, 0, 2 ether);
        stake.depositETH{value: 2 ether}();

        vm.assertEq(learn.balance, 8 ether);
        vm.assertEq(address(stake).balance, 2 ether);
        vm.stopPrank();
    }

    function test_Unstake() public {
        // 测试暂停
        stake.pause();
        assertTrue(stake.paused());
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        stake.unstake(1, 1 ether);
        stake.unpause();

        // 测试暂停
        stake.pauseWithdraw();
        vm.expectRevert(MetaNodeStake.WithdrawPaused.selector);
        vm.prank(learn);
        stake.unstake(1, 1 ether);
        stake.unpauseWithdraw();

        //测试ID不存在
        vm.expectRevert(abi.encodeWithSelector(MetaNodeStake.InvalidPid.selector, 10));
        vm.prank(learn);
        stake.unstake(10, 1 ether);

        initPool();
        mintToken(learn, 100 ether);

        vm.startPrank(learn);
        myToken.approve(address(stake), 100 ether);
        stake.deposit(1, 6 ether);

        assertEq(myToken.balanceOf(learn), 94 ether);
        assertEq(myToken.balanceOf(address(stake)), 6 ether);

        vm.roll(startBlock + 100);
        stake.unstake(1, 1 ether);

        assertGt(stake.pendingMetaNode(1, learn), 0);

        // 没有足够的额度
        vm.expectRevert(bytes("Not enough staking token balance"));
        stake.unstake(1, 6 ether);

        // 解质押
        vm.expectEmit(address(stake));
        emit MetaNodeStake.RequestUnstake(learn, 1, 5 ether);
        stake.unstake(1, 5 ether);
        vm.stopPrank();
    }

    function test_WithdrawAmount() public {
        //测试ID不存在
        vm.expectRevert(abi.encodeWithSelector(MetaNodeStake.InvalidPid.selector, 10));
        vm.prank(learn);
        stake.unstake(10, 1 ether);

        initPool();
        mintToken(learn, 10 ether);

        vm.startPrank(learn);
        myToken.approve(address(stake), 10 ether);
        stake.deposit(1, 7 ether);
        stake.unstake(1, 5 ether);
        (uint256 amount, uint256 pending) = stake.withdrawAmount(1);

        assertEq(amount, 5 ether);
        assertEq(pending, 0 ether);

        vm.roll(vm.getBlockNumber() + 101);
        (amount, pending) = stake.withdrawAmount(1);
        assertEq(amount, 5 ether);
        assertEq(pending, 5 ether);
    }

    function test_Withdraw() public {
        // 测试暂停
        stake.pause();
        assertTrue(stake.paused());
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        stake.withdraw(1);
        stake.unpause();

        // 测试暂停
        stake.pauseWithdraw();
        vm.expectRevert(MetaNodeStake.WithdrawPaused.selector);
        vm.prank(learn);
        stake.withdraw(1);
        stake.unpauseWithdraw();

        //测试ID不存在
        vm.expectRevert(abi.encodeWithSelector(MetaNodeStake.InvalidPid.selector, 10));
        vm.prank(learn);
        stake.withdraw(10);

        initPool();
        mintToken(learn, 10 ether);
        vm.deal(learn, 10 ether);

        vm.startPrank(learn);
        myToken.approve(address(stake), 10 ether);

        // 各存7个
        stake.deposit(1, 7 ether);
        stake.depositETH{value: 7 ether}();

        // 解压三个
        vm.roll(startBlock + 50);
        stake.unstake(1, 3 ether);
        (uint256 amount, uint256 pending) = stake.withdrawAmount(1);

        assertEq(amount, 3 ether);
        assertEq(pending, 0 ether);

        vm.roll(startBlock + 149);
        (amount, pending) = stake.withdrawAmount(1);
        assertEq(amount, 3 ether);
        assertEq(pending, 0 ether);

        vm.roll(startBlock + 151);
        stake.unstake(1, 2 ether);
        (amount, pending) = stake.withdrawAmount(1);
        assertEq(amount, 5 ether);
        assertEq(pending, 3 ether);

        assertEq(myToken.balanceOf(learn), 3 ether);
        assertEq(myToken.balanceOf(address(stake)), 7 ether);

        vm.roll(startBlock + 252);
        stake.unstake(1, 1 ether);
        (amount, pending) = stake.withdrawAmount(1);
        assertEq(amount, 6 ether);
        assertEq(pending, 5 ether);

        // 取回质押
        stake.withdraw(1);

        // 解压队列
        (uint256 stAmount, uint256 finishedMetaNode, uint256 pendingMetaNode) = stake.user(1, learn);
        assertEq(stAmount, 1000000000000000000);
        assertEq(finishedMetaNode, 41446428571428571428);
        assertEq(pendingMetaNode, 125999999999999999996);

        vm.stopPrank();
    }

    function test_UnstakeRequest() public {
        initPool();
        mintToken(learn, 10 ether);

        vm.startPrank(learn);
        myToken.approve(address(stake), 10 ether);
        stake.deposit(1, 5 ether);

        vm.roll(startBlock + 100);
        stake.unstake(1, 2 ether);

        vm.roll(startBlock + 200);
        stake.unstake(1, 2 ether);

        vm.roll(startBlock + 299);
        stake.withdraw(1);
        assertEq(myToken.balanceOf(learn), 7 ether);
        vm.stopPrank();
        (uint256 amount, uint256 unlockBlocks) = stake.unstakeRequest(1, learn, 0);
        assertEq(amount, 2 ether);
        assertEq(unlockBlocks, startBlock + 300);
    }

    function test_Claim() public {
        // 测试暂停
        stake.pause();
        assertTrue(stake.paused());
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        stake.claim(1);
        stake.unpause();

        // 测试暂停
        stake.pauseClaim();
        vm.expectRevert(MetaNodeStake.ClaimPaused.selector);
        vm.prank(learn);
        stake.claim(1);
        stake.unpauseClaim();

        //测试ID不存在
        vm.expectRevert(abi.encodeWithSelector(MetaNodeStake.InvalidPid.selector, 10));
        stake.claim(10);

        initPool();
        mintToken(learn, 100 ether);
        mintToken(alice, 100 ether);

        vm.prank(learn);
        myToken.approve(address(stake), 100 ether);
        vm.prank(alice);
        myToken.approve(address(stake), 100 ether);

        uint256 blockNumber = vm.getBlockNumber();
        vm.prank(learn);
        stake.deposit(1, 10 ether);

        vm.roll(blockNumber + 100);
        vm.prank(learn);
        stake.deposit(1, 20 ether);
        uint256 reward = stake.pendingMetaNode(1, learn);
        console.log("reward+100:", reward);

        vm.roll(blockNumber + 200);
        vm.deal(learn, 100 ether);
        vm.prank(learn);
        stake.deposit(1, 30 ether);
        vm.prank(learn);
        stake.depositETH{value: 5 ether}();

        vm.prank(alice);
        stake.deposit(1, 50 ether);
        reward = stake.pendingMetaNode(1, learn);
        console.log("reward+200:", reward);

        vm.roll(blockNumber + 300);
        reward = stake.pendingMetaNode(1, learn);
        console.log("reward+300:", reward);
        vm.prank(learn);
        stake.deposit(1, 30 ether);

        vm.roll(blockNumber + 400);
        reward = stake.pendingMetaNode(1, learn);
        console.log("reward+400:", reward);

        uint256 award = stake.pendingMetaNode(1, learn);
        console.log("reward:", award);
        vm.expectEmit(address(stake));
        emit MetaNodeStake.Claim(learn, 1, award);
        vm.prank(learn);
        stake.claim(1);
        assertEq(metaNode.balanceOf(learn), award);
    }

    function test_PendingMetaNode() public {
        //测试ID不存在
        vm.expectRevert(abi.encodeWithSelector(MetaNodeStake.InvalidPid.selector, 10));
        vm.prank(learn);
        stake.pendingMetaNode(10, learn);

        initPool();
        mintToken(learn, 100 ether);
        vm.startPrank(learn);
        myToken.approve(address(stake), 100 ether);
        stake.deposit(1, 1 ether);
    }

    function test_RefreshPools() public {
        initPool();
        stake.refreshPools();
    }

    function test_PoolLength() public {
        initPool();
        stake.poolLength();
    }

    function test_StakingBalance() public {
        initPool();
        mintToken(learn, 100 ether);

        vm.prank(learn);
        myToken.approve(address(stake), 100 ether);
        vm.prank(learn);
        stake.deposit(1, 10 ether);

        stake.stakingBalance(1, learn);
    }

    function test_blockNumber() public {
        initPool();
        mintToken(learn, 100 ether);
        // 先质押
        vm.prank(learn);
        myToken.approve(address(stake), 100 ether);
        vm.prank(learn);
        stake.deposit(1, 10 ether);

        // 推进到 endBlock 之后
        vm.roll(startBlock + 300);
        uint256 reward = stake.pendingMetaNode(1, learn);
        console.log("reward:", reward / 1 ether);

        vm.roll(endBlock);
        uint256 endReward = stake.pendingMetaNode(1, learn);
        console.log("endReward:", endReward / 1 ether);

        vm.roll(endBlock + 300);
        uint256 overReward = stake.pendingMetaNode(1, learn);
        console.log("overReward:", overReward / 1 ether);

        assertEq(endReward, overReward);
    }
}
