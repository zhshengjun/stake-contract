// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Test} from "forge-std/Test.sol";

import {MetaNodeStakeDeployer} from "../script/MetaNodeStakeDeployer.sol";

contract MetaNodeStakeDeployerTest is Test {
    uint256 private constant LOCAL_CHAIN_ID = 31337;
    uint256 private constant PRIVATE_KEY = 0xA11CE;
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    MetaNodeStakeDeployer private deployer;
    address private owner1;
    address private owner2 = address(0x2);
    address private owner3 = address(0x3);

    function setUp() public {
        vm.chainId(LOCAL_CHAIN_ID);
        vm.roll(1_000);

        owner1 = vm.addr(PRIVATE_KEY);
        deployer = new MetaNodeStakeDeployer();

        vm.setEnv("DEPLOY_CHAIN_ID", vm.toString(LOCAL_CHAIN_ID));
        vm.setEnv("PRIVATE_KEY", vm.toString(PRIVATE_KEY));
        vm.setEnv(
            "MULTISIG_OWNERS", string.concat(vm.toString(owner1), ",", vm.toString(owner2), ",", vm.toString(owner3))
        );
        vm.setEnv("MULTISIG_THRESHOLD", "2");
        vm.setEnv("START_BLOCK_OFFSET", "10");
        vm.setEnv("REWARD_DURATION_BLOCKS", "100");
        vm.setEnv("META_NODE_PER_BLOCK", vm.toString(uint256(1 ether)));
        vm.setEnv("REWARD_FUND_AMOUNT", vm.toString(uint256(100 ether)));
    }

    // 在本地链执行完整部署，不连接 Sepolia，也不广播真实交易。
    function testDeployFromEnvironmentConfig() public {
        assertEq(vm.envUint("REWARD_DURATION_BLOCKS"), 100, "duration config");
        assertEq(vm.envUint("META_NODE_PER_BLOCK"), 1 ether, "reward per block config");
        assertEq(vm.envUint("REWARD_FUND_AMOUNT"), 100 ether, "reward fund config");

        MetaNodeStakeDeployer.Deployment memory deployment = deployer.run();

        assertEq(deployment.stake.startBlock(), 1_010);
        assertEq(deployment.stake.endBlock(), 1_110);
        assertEq(deployment.stake.metaNodePerBlock(), 1 ether);
        assertEq(address(deployment.stake.metaNode()), address(deployment.token));
        assertEq(deployment.token.balanceOf(address(deployment.stake)), 100 ether);

        assertEq(deployment.multisig.threshold(), 2);
        assertTrue(deployment.multisig.isOwner(owner1));
        assertTrue(deployment.multisig.isOwner(owner2));
        assertTrue(deployment.multisig.isOwner(owner3));

        assertTrue(deployment.stake.hasRole(deployment.stake.ADMIN_ROLE(), owner1));
        assertTrue(deployment.stake.hasRole(deployment.stake.DEFAULT_ADMIN_ROLE(), address(deployment.multisig)));
        assertTrue(deployment.stake.hasRole(deployment.stake.UPGRADE_ROLE(), address(deployment.multisig)));

        address actualImplementation =
            address(uint160(uint256(vm.load(address(deployment.stake), IMPLEMENTATION_SLOT))));
        assertEq(actualImplementation, address(deployment.implementation));
    }

    // 配置的目标网络与当前链不一致时，必须在广播前终止。
    function testRevertWhenChainIdDoesNotMatchConfig() public {
        vm.chainId(1);

        vm.expectRevert(abi.encodeWithSelector(MetaNodeStakeDeployer.InvalidChain.selector, 1, LOCAL_CHAIN_ID));
        deployer.run();
    }
}
