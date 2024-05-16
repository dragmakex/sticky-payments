// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ITimelock {
    function getTxId(
        address _target,
        uint256 _value,
        string calldata _func,
        bytes calldata _data,
        uint256 _timestamp
    ) external pure returns (bytes32);

    function queueTimelock(
        address _target,
        uint256 _value,
        string calldata _func,
        bytes calldata _data,
        uint256 _timestamp
    ) external;

    function executeTimelock(
        address _target,
        uint256 _value,
        string calldata _func,
        bytes calldata _data,
        uint256 _timestamp
    ) external payable returns (bytes memory);

    function cancelTimelock(bytes32 _txId) external;
}

interface IMultisig {
    function submitMultisig(address _to, uint256 _value, bytes calldata _data) external;

    function approveMultisig(uint256 _txId) external;

    function executeMultisig(uint256 _txId) external;

    function revokeMultisig(uint256 _txId) external;
}

interface IStreaming {
    function queueStreaming(
        address _target,
        uint256 _value,
        string calldata _func,
        bytes calldata _data,
        uint256 _timestamp
    ) external;

    function executeStreaming(
        address _target,
        uint256 _value,
        string calldata _func,
        bytes calldata _data,
        uint256 _timestamp
    ) external payable returns (bytes memory);

    function cancelStreaming(bytes32 _txId) external;
}

interface Owned {
    function isOwner(address account) external view returns (bool);
}

contract StickyPayments is ReentrancyGuard, ITimelock, IMultisig, IStreaming, Owned{

    // ----- Global Errors -----

    error NotOwnerError();
    error TxFailedError();

    // ----- Timelock & Streaming Errors -----

    error AlreadyQueuedError(bytes32 txId);
    error NotQueuedError(bytes32 txId);
    error TimestampNotInRangeError(uint256 blockTimestamp, uint256 timestamp);
    error TimestampNotPassedError(uint256 blockTimestamp, uint256 timestamp);
    error TimestampExpiredError(uint256 blockTimestamp, uint256 expiresAt);

    // ----- Multisig Errors -----

    error TxNotExisting(uint256 txId);
    error AlreadyApprovedError(uint256 txId);
    error AlreadyExecuted(uint256 txId);
    error NotEnoughApprovalsError(uint256 txId);
    error NotApprovedError(uint256 txId);

    // ----- Global Events ----

    event Deposit(address indexed sender, uint256 amount);

    // ----- Timelock Events -----

    event QueueTimelock(
        bytes32 indexed txId, 
        address indexed target, 
        uint256 value, 
        string func, 
        bytes data, 
        uint256 timestamp
    );
    event ExecuteTimelock(
        bytes32 indexed txId, 
        address indexed target, 
        uint256 value, 
        string func, 
        bytes data, 
        uint256 timestamp
    );
    event CancelTimelock(bytes32 indexed txId);

    // ----- Multisig Events -----

    event SubmitMultisig(uint256 indexed txId);
    event ApproveMultisig(address indexed owner, uint256 indexed txId);
    event RevokeMultisig(address indexed owner, uint256 indexed txId);
    event ExecuteMultisig(uint256 indexed txId);

        // ----- Streaming Events -----

    event QueueStreaming(
        bytes32 indexed txId, 
        address indexed target, 
        uint256 value, 
        string func, 
        bytes data, 
        uint256 timestamp
    );
    event ExecuteStreaming(
        bytes32 indexed txId, 
        address indexed target, 
        uint256 value, 
        string func, 
        bytes data, 
        uint256 timestamp
    );
    event CancelStreaming(bytes32 indexed txId);

    // ----- Global State Variables -----

    address[] public owners;
    mapping(address => bool) public isOwner;

    // ----- Timelock State Variables -----

    uint256 public constant MIN_DELAY = 10;
    uint256 public constant MAX_DELAY = 1000;
    uint256 public constant GRACE_PERIOD = 1000;
    mapping(bytes32 => bool) public queuedTimelock;

    // ----- Multisig State Variables -----

    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        bool executed;
        //bool isToken;
        //address tokenAddress;
    }
    uint256 public required;
    Transaction[] public transactions;
    mapping(uint256 => mapping(address => bool)) public approved;

    // ----- Streaming State Variables -----

    mapping(bytes32 => bool) public queuedStreaming;

    // ----- Global Functions & Modifiers -----

    constructor(address[] memory _owners, uint256 _required) {
        
        require(_owners.length > 0, "owners required");
        require(
            _required > 0 && _required <= owners.length,
            "invalid number of owners"
        );

        for (uint256 i; i < _owners.length; i++) {
            address localOwner = _owners[i];

            require(localOwner != address(0), "invalid owner");
            require(!isOwner[localOwner], "owner is not unique");

            isOwner[localOwner] = true;
            owners.push(localOwner);
        }

        required = _required;
    }

    receive() external payable {
        emit Deposit(msg.sender, msg.value);
    }

    modifier onlyOwner() {
        if (!isOwner[msg.sender]) {
            revert NotOwnerError();
        }
        _;
    }

    modifier txExists (uint256 _txId) {
        if (_txId >= transactions.length) {
            revert TxNotExisting(_txId);
        }
        _;
    }

    modifier notApproved(uint256 _txId) {
        if (approved[_txId][msg.sender]) {
            revert AlreadyApprovedError(_txId);
        }
        _;
    }

    modifier notExecuted(uint256 _txId) {
        if (transactions[_txId].executed) {
            revert AlreadyExecuted(_txId);
        }
        _;
    }

    function getTxId(
        address _target,
        uint256 _value,
        string calldata _func,
        bytes calldata _data,
        uint256 _timestamp
    ) public pure returns (bytes32 txId) {
        return keccak256(
            abi.encode(_target, _value, _func, _data, _timestamp)
        );
    }

    // ----- Timelock Functions -----
    
    function queueTimelock(
        address _target,
        uint256 _value,
        string calldata _func,
        bytes calldata _data,
        uint256 _timestamp
    ) external onlyOwner {

        bytes32 txId = getTxId(_target, _value, _func, _data, _timestamp);

        if (queuedTimelock[txId]) {
            revert AlreadyQueuedError(txId);
        }

        if (_timestamp < block.timestamp + MIN_DELAY || _timestamp > block.timestamp + MAX_DELAY) {
            revert TimestampNotInRangeError(block.timestamp, _timestamp);
        }

        queuedTimelock[txId] = true;

        emit QueueTimelock(txId, _target, _value, _func, _data, _timestamp);

    }

    function executeTimelock(
        address _target,
        uint256 _value,
        string calldata _func,
        bytes calldata _data,
        uint256 _timestamp
    ) external payable onlyOwner nonReentrant returns (bytes memory) {
        
        bytes32 txId = getTxId(_target, _value, _func, _data, _timestamp);
  
        if (!queuedTimelock[txId]) {
            revert NotQueuedError(txId);
        }
        if (block.timestamp < _timestamp) {
            revert TimestampNotPassedError(block.timestamp, _timestamp);
        }
        if (block.timestamp > _timestamp + GRACE_PERIOD) {
            revert TimestampExpiredError(block.timestamp, _timestamp + GRACE_PERIOD);
        }

        queuedTimelock[txId] = false;

        bytes memory data;
        if (bytes(_func).length > 0) {
            data = abi.encodePacked(
                bytes4(keccak256(bytes(_func))), _data
            );
        } else {
            data = _data;
        }

        /*if (transaction.isToken) {
            IERC20 token = IERC20(transaction.tokenAddress);
            require(token.transfer(transaction.to, transaction.value), "Token transfer failed");
        } else {
            (bool success, ) = transaction.to.call{value: transaction.value}(transaction.data);
            require(success, "Ether transfer failed");
        }*/

        (bool ok, bytes memory res) = _target.call{value: _value}(data);
        if (!ok) {
            revert TxFailedError();
        }

        emit ExecuteTimelock(txId, _target, _value, _func, _data, _timestamp);

        return res;
    }

    function cancelTimelock(bytes32 _txId) external onlyOwner {
        
        if(!queuedTimelock[_txId]) {
            revert NotQueuedError(_txId);
        }
        queuedTimelock[_txId] = false;
        emit CancelTimelock(_txId);
    }

    // ---- Multisig Functions -----

    function submitMultisig(address _to, uint256 _value, bytes calldata _data) 
        external
        onlyOwner
    {
        transactions.push(Transaction({
            to: _to,
            value: _value,
            data: _data,
            executed: false
        }));
        
        emit SubmitMultisig(transactions.length - 1);
    }

    function approveMultisig(uint256 _txId) 
        external
        onlyOwner
        txExists(_txId)
        notApproved(_txId)
        notExecuted(_txId)
    {
        approved[_txId][msg.sender] = true;
        emit ApproveMultisig(msg.sender, _txId);
    }

    function _getApprovalCountMultisig(uint256 _txId) private view returns (uint256 count) {
        for (uint256 i; i < owners.length; i++) {
            if (approved[_txId][owners[i]]) {
                count += 1;
            }
        }
    }

    function executeMultisig(uint256 _txId) 
        external 
        txExists(_txId) 
        notExecuted(_txId) 
        nonReentrant 
    {

        if (_getApprovalCountMultisig(_txId) < required) {
            revert NotEnoughApprovalsError(_txId);
        }
        Transaction storage transaction = transactions[_txId];

        transaction.executed = true;

        (bool success, ) = transaction.to.call{value: transaction.value}(
            transaction.data
        );

        if (!success) {
            revert TxFailedError();
        }

        emit ExecuteMultisig(_txId);
    }

    function revokeMultisig(uint256 _txId) external onlyOwner txExists(_txId) notExecuted(_txId) {
        
        if (!approved[_txId][msg.sender]) {
            revert NotApprovedError(_txId);
        }
        approved[_txId][msg.sender] = false;
        emit RevokeMultisig(msg.sender, _txId);
    }

    // ----- Streaming Functions -----

    function queueStreaming(
        address _target,
        uint256 _value,
        string calldata _func,
        bytes calldata _data,
        uint256 _timestamp
    ) external onlyOwner {

        bytes32 txId = getTxId(_target, _value, _func, _data, _timestamp);

        if (queuedStreaming[txId]) {
            revert AlreadyQueuedError(txId);
        }

        if (_timestamp <= block.timestamp) {
            revert TimestampNotInRangeError(block.timestamp, _timestamp);
        }

        queuedStreaming[txId] = true;

        emit QueueStreaming(txId, _target, _value, _func, _data, _timestamp);

    }

    function executeStreaming(
        address _target,
        uint256 _value,
        string calldata _func,
        bytes calldata _data,
        uint256 _timestamp
    ) external payable onlyOwner nonReentrant returns (bytes memory) {
        
        bytes32 txId = getTxId(_target, _value, _func, _data, _timestamp);
  
        if (!queuedStreaming[txId]) {
            revert NotQueuedError(txId);
        }

        queuedStreaming[txId] = false;

        bytes memory data;
        if (bytes(_func).length > 0) {
            data = abi.encodePacked(
                bytes4(keccak256(bytes(_func))), _data
            );
        } else {
            data = _data;
        }

        uint256 finalValue = _value;

        if (block.timestamp < _timestamp) {
            // Multiply by 1e18 to avoid precision loss
            uint256 proportion = (block.timestamp * 1e18) / _timestamp;
            // Divide by 1e18 to scale back down
            finalValue = (_value * proportion) / 1e18;
        }

        (bool ok, bytes memory res) = _target.call{value: finalValue}(data);
        if (!ok) {
            revert TxFailedError();
        }

        emit ExecuteStreaming(txId, _target, _value, _func, _data, _timestamp);

        return res;
    }

    function cancelStreaming(bytes32 _txId) external onlyOwner {
        
        if(!queuedStreaming[_txId]) {
            revert NotQueuedError(_txId);
        }
        queuedStreaming[_txId] = false;
        emit CancelStreaming(_txId);
    }
}