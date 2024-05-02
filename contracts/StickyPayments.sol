// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17;

/*interface IStickyPayments {
    function queue() external;
    function execute() external;
    
}*/

contract StickyPayments /*is IStickyPayments*/{
    
    error NotOwnerError();
    error AlreadyQueuedError(bytes32 txId);
    error TimestampNotInRangeError(uint256 blockTimestamp, uint256 timestamp);

    event Queue(
        bytes32 indexed txId, 
        address indexed target, 
        uint256 value, 
        string func, 
        bytes data, 
        uint256 timestamp
    );

    uint256 public constant MIN_DELAY = 10;
    uint256 public constant MAX_DELAY = 1000;

    address public owner;
    mapping(bytes32 => bool) public alreadyQueued;

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwnerError();
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
    
    function queue(
        address _target,
        uint256 _value,
        string calldata _func,
        bytes calldata _data,
        uint256 _timestamp
    ) external onlyOwner {
        bytes32 txId = getTxId(_target, _value, _func, _data, _timestamp);

        if (alreadyQueued[txId]) {
            revert AlreadyQueuedError(txId);
        }

        if (_timestamp < block.timestamp + MIN_DELAY || _timestamp > block.timestamp + MAX_DELAY) {
            revert TimestampNotInRangeError(block.timestamp, _timestamp);
        }

        alreadyQueued[txId] = true;

        emit Queue(txId, _target, _value, _func, _data, _timestamp);

    }

    function execute(
        address _target,
        uint256 _value,
        string calldata _func,
        bytes calldata _data,
        uint256 _timestamp
    ) external {
        



    }
    
}