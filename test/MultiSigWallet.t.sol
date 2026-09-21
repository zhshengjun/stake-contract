// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {MultiSigWallet} from "../src/MultiSigWallet.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {StdChains} from "forge-std/StdChains.sol";
import {StdCheats, StdCheatsSafe} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Test} from "forge-std/Test.sol";

contract MultiSigTarget {
    uint256 public value;

    // 用于验证多签能同时执行 calldata 并转发 ETH。
    function setValue(uint256 newValue) external payable {
        value = newValue;
    }

    // 用于验证目标调用失败时，多签交易不会被标记为已执行。
    function fail() external pure {
        revert("target failed");
    }
}

contract MultiSigWalletTest is Test {
    MultiSigWallet private wallet;
    MultiSigTarget private target;

    address private owner2 = address(0x2);
    address private owner3 = address(0x3);
    address private outsider = address(0x99);

    function setUp() public {
        address[] memory owners = new address[](3);
        owners[0] = address(this);
        owners[1] = owner2;
        owners[2] = owner3;
        wallet = new MultiSigWallet(owners, 2);
        target = new MultiSigTarget();
    }

    // 构造函数必须拒绝空 owner 列表、零地址、重复 owner 和非法阈值。
    function testConstructorValidation() public {
        address[] memory emptyOwners = new address[](0);
        vm.expectRevert(bytes("owners required"));
        new MultiSigWallet(emptyOwners, 1);

        address[] memory owners = new address[](2);
        owners[0] = address(this);
        owners[1] = address(0);
        vm.expectRevert(bytes("invalid owner"));
        new MultiSigWallet(owners, 1);

        owners[1] = address(this);
        vm.expectRevert(bytes("owner exists"));
        new MultiSigWallet(owners, 1);

        owners[1] = owner2;
        vm.expectRevert(bytes("invalid threshold"));
        new MultiSigWallet(owners, 0);

        vm.expectRevert(bytes("invalid threshold"));
        new MultiSigWallet(owners, 3);
    }

    // 完整成功路径：入金、提交提案、第二位 owner 确认、执行 calldata 并转账。
    function testSubmitConfirmAndExecuteWithEth() public {
        (bool funded,) = address(wallet).call{value: 1 ether}("");
        assertTrue(funded);

        bytes memory data = abi.encodeCall(target.setValue, (42));
        uint256 transactionId = wallet.submitTransaction(address(target), 0.4 ether, data);

        // submitTransaction 会把提案发起人记为第一次确认。
        assertTrue(wallet.confirmed(transactionId, address(this)));

        // 阈值为 2，owner2 完成第二次确认后才能执行。
        vm.prank(owner2);
        wallet.confirmTransaction(transactionId);
        wallet.executeTransaction(transactionId);

        assertEq(target.value(), 42);
        assertEq(address(target).balance, 0.4 ether);
        assertEq(address(wallet).balance, 0.6 ether);
    }

    // 非 owner 不能提交、确认或执行任何多签交易。
    function testOnlyOwner() public {
        vm.startPrank(outsider);

        vm.expectRevert(bytes("not owner"));
        wallet.submitTransaction(address(target), 0, "");

        vm.expectRevert(bytes("not owner"));
        wallet.confirmTransaction(0);

        vm.expectRevert(bytes("not owner"));
        wallet.executeTransaction(0);

        vm.stopPrank();
    }

    // 拒绝重复确认、确认数不足，以及对已执行交易再次确认或执行。
    function testConfirmationValidation() public {
        uint256 transactionId = wallet.submitTransaction(address(target), 0, abi.encodeCall(target.setValue, (1)));

        vm.expectRevert(bytes("already confirmed"));
        wallet.confirmTransaction(transactionId);

        vm.expectRevert(bytes("not enough confirmations"));
        wallet.executeTransaction(transactionId);

        vm.prank(owner2);
        wallet.confirmTransaction(transactionId);
        wallet.executeTransaction(transactionId);

        vm.expectRevert(bytes("already executed"));
        wallet.executeTransaction(transactionId);

        vm.prank(owner2);
        vm.expectRevert(bytes("already executed"));
        wallet.confirmTransaction(transactionId);
    }

    // 目标合约回滚时，整个执行回滚，交易仍保持未执行状态。
    function testTargetCallFailureCanBeRetried() public {
        uint256 transactionId = wallet.submitTransaction(address(target), 0, abi.encodeCall(target.fail, ()));

        vm.prank(owner2);
        wallet.confirmTransaction(transactionId);

        vm.expectRevert(bytes("execution failed"));
        wallet.executeTransaction(transactionId);

        (,,,, bool executed) = wallet.transactions(transactionId);
        assertFalse(executed);
    }

    // owner 和 threshold 只能由多签钱包通过对自身的提案修改。
    function testOwnerManagementRequiresWalletCall() public {
        vm.expectRevert(bytes("only wallet"));
        wallet.addOwner(address(0x4));

        vm.expectRevert(bytes("only wallet"));
        wallet.removeOwner(owner3);

        vm.expectRevert(bytes("only wallet"));
        wallet.replaceOwner(owner3, address(0x4));

        vm.expectRevert(bytes("only wallet"));
        wallet.changeThreshold(1);
    }

    // 通过多签调用钱包自身，新增 owner。
    function testAddOwnerThroughMultisig() public {
        address newOwner = address(0x4);
        uint256 transactionId =
            wallet.submitTransaction(address(wallet), 0, abi.encodeCall(wallet.addOwner, (newOwner)));

        _confirmAndExecute(transactionId);

        assertTrue(wallet.isOwner(newOwner));
        assertEq(wallet.owners(3), newOwner);
    }

    // 通过多签替换 owner，并保持原阈值不变。
    function testReplaceOwnerThroughMultisig() public {
        address newOwner = address(0x4);
        bytes memory data = abi.encodeCall(wallet.replaceOwner, (owner3, newOwner));
        uint256 transactionId = wallet.submitTransaction(address(wallet), 0, data);

        vm.prank(owner2);
        wallet.confirmTransaction(transactionId);
        wallet.executeTransaction(transactionId);

        assertFalse(wallet.isOwner(owner3));
        assertTrue(wallet.isOwner(newOwner));
        assertEq(wallet.threshold(), 2);
    }

    // 通过多签移除 owner。
    function testRemoveOwnerThroughMultisig() public {
        uint256 transactionId =
            wallet.submitTransaction(address(wallet), 0, abi.encodeCall(wallet.removeOwner, (owner3)));

        _confirmAndExecute(transactionId);

        assertFalse(wallet.isOwner(owner3));
    }

    // 通过多签把确认阈值从 2 调整为 3。
    function testChangeThresholdThroughMultisig() public {
        uint256 transactionId =
            wallet.submitTransaction(address(wallet), 0, abi.encodeCall(wallet.changeThreshold, (3)));

        _confirmAndExecute(transactionId);

        assertEq(wallet.threshold(), 3);
    }

    // 钱包自调用同样必须拒绝无效 owner 参数和非法阈值。
    function testOwnerManagementValidation() public {
        _expectWalletCallFailure(abi.encodeCall(wallet.addOwner, (address(0))));
        _expectWalletCallFailure(abi.encodeCall(wallet.addOwner, (owner2)));
        _expectWalletCallFailure(abi.encodeCall(wallet.removeOwner, (outsider)));
        _expectWalletCallFailure(abi.encodeCall(wallet.replaceOwner, (outsider, address(0x4))));
        _expectWalletCallFailure(abi.encodeCall(wallet.replaceOwner, (owner3, address(0))));
        _expectWalletCallFailure(abi.encodeCall(wallet.replaceOwner, (owner3, owner2)));
        _expectWalletCallFailure(abi.encodeCall(wallet.changeThreshold, (0)));
        _expectWalletCallFailure(abi.encodeCall(wallet.changeThreshold, (4)));
    }

    // 移除 owner 后，剩余 owner 数量不能小于当前确认阈值。
    function testCannotRemoveOwnerBelowThreshold() public {
        uint256 removeOwner3 =
            wallet.submitTransaction(address(wallet), 0, abi.encodeCall(wallet.removeOwner, (owner3)));
        _confirmAndExecute(removeOwner3);

        _expectWalletCallFailure(abi.encodeCall(wallet.removeOwner, (owner2)));
    }

    // 只统计当前 owners：被移除 owner 的历史确认必须立即失效。
    function testRemovedOwnerConfirmationNoLongerCounts() public {
        uint256 targetTransaction = wallet.submitTransaction(address(target), 0, "");
        vm.prank(owner3);
        wallet.confirmTransaction(targetTransaction);

        uint256 removeOwner3 =
            wallet.submitTransaction(address(wallet), 0, abi.encodeCall(wallet.removeOwner, (owner3)));
        _confirmAndExecute(removeOwner3);

        vm.expectRevert(bytes("not enough confirmations"));
        wallet.executeTransaction(targetTransaction);
    }

    // 默认钱包为 2/3：发起人已自动确认，再补 owner2 的确认并执行。
    function _confirmAndExecute(uint256 transactionId) private {
        vm.prank(owner2);
        wallet.confirmTransaction(transactionId);
        wallet.executeTransaction(transactionId);
    }

    // 构造一个已达到阈值、但钱包自调用因业务校验失败的提案。
    function _expectWalletCallFailure(bytes memory data) private {
        uint256 transactionId = wallet.submitTransaction(address(wallet), 0, data);
        vm.prank(owner2);
        wallet.confirmTransaction(transactionId);

        vm.expectRevert(bytes("execution failed"));
        wallet.executeTransaction(transactionId);
    }
}
