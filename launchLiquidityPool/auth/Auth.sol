// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./Ownable.sol";

contract Auth is Ownable {
    mapping(address => bool) private _isOperator;

    error InvalidAccess();

    event OperatorUpdated(address indexed operator, bool isAllowed);

    modifier onlyOperator() {
        if (!_isOperator[msg.sender]) {
            revert InvalidAccess();
        }
        _;
    }

    function setOperator(address _operator, bool _isAllowed) external onlyOwner {
        _isOperator[_operator] = _isAllowed;
        emit OperatorUpdated(_operator, _isAllowed);
    }
}
