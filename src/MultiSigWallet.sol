// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

contract MultiSigWallet {
    struct Transaction {
        address target; // MetaNodeStake 代理地址
        uint256 value; // 一般为 0
        bytes data; // updatePool(...) 等函数 calldata
        uint256 confirmations;
        bool executed;
    }

    address[] public owners;
    mapping(address => bool) public isOwner;

    // 提案阈值
    uint256 public threshold;

    // 提案列表
    Transaction[] public transactions;

    // transactionId => owner => 是否已确认
    mapping(uint256 => mapping(address => bool)) public confirmed;

    event SubmitTransaction(
        uint256 indexed transactionId, address indexed proposer, address indexed target, uint256 value, bytes data
    );

    event ConfirmTransaction(uint256 indexed transactionId, address indexed owner);

    event ExecuteTransaction(uint256 indexed transactionId, address indexed executor);

    event ExecutionFailure(uint256 indexed transactionId, bytes reason);

    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event OwnerReplaced(address indexed oldOwner, address indexed newOwner);
    event ThresholdChanged(uint256 threshold);

    constructor(address[] memory _owners, uint256 _threshold) {
        require(_owners.length > 0, "owners required");

        for (uint256 i = 0; i < _owners.length; i++) {
            _addOwner(_owners[i]);
        }

        _changeThreshold(_threshold);
    }

    receive() external payable {}

    modifier onlyOwner() {
        require(isOwner[msg.sender], "not owner");
        _;
    }

    modifier onlyWallet() {
        require(msg.sender == address(this), "only wallet");
        _;
    }

    function submitTransaction(address target, uint256 value, bytes calldata data)
        external
        onlyOwner
        returns (uint256 transactionId)
    {
        transactionId = transactions.length;

        transactions.push(Transaction({target: target, value: value, data: data, confirmations: 0, executed: false}));

        emit SubmitTransaction(transactionId, msg.sender, target, value, data);

        // 发起人默认确认
        confirmTransaction(transactionId);
    }

    function confirmTransaction(uint256 transactionId) public onlyOwner {
        Transaction storage transaction = transactions[transactionId];

        require(!transaction.executed, "already executed");
        require(!confirmed[transactionId][msg.sender], "already confirmed");

        confirmed[transactionId][msg.sender] = true;
        transaction.confirmations++;

        emit ConfirmTransaction(transactionId, msg.sender);
    }

    function executeTransaction(uint256 transactionId) external onlyOwner {
        Transaction storage transaction = transactions[transactionId];

        require(!transaction.executed, "already executed");
        require(_currentConfirmations(transactionId) >= threshold, "not enough confirmations");

        // 先修改状态，防止重入重复执行
        transaction.executed = true;

        // 多签达到 threshold 后才能执行提案中的 target、value 和 data。
        // forge-lint: disable-next-line(arbitrary-send-eth)
        (bool success, bytes memory result) = transaction.target.call{value: transaction.value}(transaction.data);

        if (!success) {
            transaction.executed = false;
            // forge-lint: disable-next-line(reentrancy-events)
            emit ExecutionFailure(transactionId, result);
            revert("execution failed");
        }

        // forge-lint: disable-next-line(reentrancy-events)
        emit ExecuteTransaction(transactionId, msg.sender);
    }

    function addOwner(address owner) external onlyWallet {
        _addOwner(owner);
    }

    function removeOwner(address owner) external onlyWallet {
        require(isOwner[owner], "not owner");
        require(owners.length - 1 >= threshold, "threshold too high");

        isOwner[owner] = false;

        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == owner) {
                owners[i] = owners[owners.length - 1];
                owners.pop();
                break;
            }
        }

        emit OwnerRemoved(owner);
    }

    function replaceOwner(address oldOwner, address newOwner) external onlyWallet {
        require(isOwner[oldOwner], "old owner not found");
        require(newOwner != address(0), "invalid owner");
        require(!isOwner[newOwner], "owner exists");

        isOwner[oldOwner] = false;
        isOwner[newOwner] = true;

        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == oldOwner) {
                owners[i] = newOwner;
                break;
            }
        }

        emit OwnerReplaced(oldOwner, newOwner);
    }

    function changeThreshold(uint256 newThreshold) external onlyWallet {
        _changeThreshold(newThreshold);
    }

    function _addOwner(address owner) private {
        // forge-lint: disable-next-line(require-revert-in-loop)
        require(owner != address(0), "invalid owner");
        // forge-lint: disable-next-line(require-revert-in-loop)
        require(!isOwner[owner], "owner exists");

        isOwner[owner] = true;
        owners.push(owner);

        emit OwnerAdded(owner);
    }

    function _changeThreshold(uint256 newThreshold) private {
        require(newThreshold > 0 && newThreshold <= owners.length, "invalid threshold");
        threshold = newThreshold;
        emit ThresholdChanged(newThreshold);
    }

    function _currentConfirmations(uint256 transactionId) private view returns (uint256 count) {
        for (uint256 i = 0; i < owners.length; i++) {
            if (confirmed[transactionId][owners[i]]) {
                count++;
            }
        }
    }
}
