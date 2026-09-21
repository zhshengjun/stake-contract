// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {MetaNodeStake} from "../src/MetaNodeStake.sol";
import {MetaNodeToken} from "../src/MetaNodeToken.sol";
import {MultiSigWallet} from "../src/MultiSigWallet.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CommonBase} from "forge-std/Base.sol";
import {Script} from "forge-std/Script.sol";
import {StdChains} from "forge-std/StdChains.sol";
import {StdCheatsSafe} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {console} from "forge-std/console.sol";

contract MetaNodeStakeDeployer is Script {
    /**
     * 校验
     */
    error InvalidChain(uint256 actualChainId, uint256 expectedChainId);

    struct Config {
        uint256 chainId;
        uint256 privateKey;
        address deployer;
        address[] owners;
        uint256 threshold;
        uint256 startBlock;
        uint256 endBlock;
        uint256 rewardPerBlock;
        uint256 rewardFundAmount;
    }

    struct Deployment {
        MetaNodeToken token;
        MultiSigWallet multisig;
        MetaNodeStake implementation;
        MetaNodeStake stake;
    }

    function run() external returns (Deployment memory deployment) {
        Config memory config = _loadConfig();
        if (block.chainid != config.chainId) {
            revert InvalidChain(block.chainid, config.chainId);
        }

        vm.startBroadcast(config.privateKey);

        deployment.token = new MetaNodeToken(config.deployer);
        deployment.multisig = new MultiSigWallet(config.owners, config.threshold);
        deployment.implementation = new MetaNodeStake();

        bytes memory initData = abi.encodeCall(
            MetaNodeStake.initialize,
            (
                IERC20(address(deployment.token)),
                config.startBlock,
                config.endBlock,
                config.rewardPerBlock,
                address(deployment.multisig)
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(deployment.implementation), initData);
        deployment.stake = MetaNodeStake(address(proxy));

        deployment.token.transfer(address(deployment.stake), config.rewardFundAmount);

        vm.stopBroadcast();

        require(deployment.stake.hasRole(deployment.stake.ADMIN_ROLE(), config.deployer), "deployer is not admin");

        require(
            deployment.stake.hasRole(deployment.stake.DEFAULT_ADMIN_ROLE(), address(deployment.multisig)),
            "multisig is not default admin"
        );

        require(
            deployment.stake.hasRole(deployment.stake.UPGRADE_ROLE(), address(deployment.multisig)),
            "multisig is not upgrade authority"
        );
        require(
            deployment.token.balanceOf(address(deployment.stake)) == config.rewardFundAmount, "reward funding failed"
        );

        console.log("MetaNodeToken:", address(deployment.token));
        console.log("MultiSigWallet:", address(deployment.multisig));
        console.log("MetaNodeStake implementation:", address(deployment.implementation));
        console.log("MetaNodeStake proxy:", address(deployment.stake));
        console.log("Start block:", config.startBlock);
        console.log("End block:", config.endBlock);
    }

    // 从 .env 读取部署参数，并在广播交易前完成配置校验。
    function _loadConfig() private view returns (Config memory config) {
        config.chainId = vm.envUint("DEPLOY_CHAIN_ID");
        config.privateKey = vm.envUint("PRIVATE_KEY");
        config.deployer = vm.addr(config.privateKey);
        config.owners = vm.envAddress("MULTISIG_OWNERS", ",");
        config.threshold = vm.envUint("MULTISIG_THRESHOLD");
        config.startBlock = block.number + vm.envUint("START_BLOCK_OFFSET");

        uint256 durationBlocks = vm.envUint("REWARD_DURATION_BLOCKS");
        config.endBlock = config.startBlock + durationBlocks;
        config.rewardPerBlock = vm.envUint("META_NODE_PER_BLOCK");
        config.rewardFundAmount = vm.envUint("REWARD_FUND_AMOUNT");

        require(config.rewardFundAmount >= durationBlocks * config.rewardPerBlock, "insufficient reward funding");

        return config;
    }
}
