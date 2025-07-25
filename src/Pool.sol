// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IWinToken} from "../src/interfaces/IWinToken.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract Pool is AccessControl {
    // erros
    error Pool__MustSendEth();
    error Pool__CanOnlyWithdrawDepositedAmountOrLess();
    error Pool__ParticipantIsNotInList();
    error Pool_WithdrawTransferBackToUserFail();

    IWinToken private immutable i_winToken;
    // the total deposits for everyone
    uint256 public s_totalDeposits;
    // the accumulated interest to be won
    uint256 s_poolBalance;
    // last time the contract accrued interest to balance
    uint256 s_lastAccrued;
    // this is each users deposits + interest accrued
    mapping(address user => uint256 amountDeposited) private s_amountUserDeposited;
    // bool to whether user is in the participant list
    mapping(address user => bool) private s_isParticipant;
    // the index of the user in the list
    mapping(address user => uint256 index) private s_indexOfUser;
    // this is the list of address of users who have deposited
    address[] private s_participants;
    // this is 0.00000005 per second, equivalent to 5% annually
    uint256 public immutable s_interestRate = (5 * PRECISION_FACTOR) / 1e8;
    // scale up to 18 decimals
    uint256 private constant PRECISION_FACTOR = 1e18;
    // this is the role for the chainlink automator to distribute the contracts funds to a lucky address
    bytes32 private constant DISTRIBUTE_INTEREST_ROLE = keccak256("DISTRIBUTE_INTEREST_ROLE");

    // events
    event Deposit(address indexed user, uint256 amount);
    event InterestRateChange(uint256 newInterestRate);

    constructor(IWinToken _i_winToken) {
        i_winToken = _i_winToken;
        s_totalDeposits = 0;
    }

    receive() external payable {}

    /**
     * @notice this function deposits eth into the contract
     */
    function deposit() external payable {
        if (msg.value == 0) {
            revert Pool__MustSendEth();
        }
        _addParticipants(msg.sender);
        s_amountUserDeposited[msg.sender] += msg.value;
        s_totalDeposits += msg.value;
        _accrueInterest();

        i_winToken.mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    /**
     * @notice this function enables users to withdraw the eth they deposited, and return the win tokens, removing them from the pool
     * @param ethToWithdraw the amount of eth to withdraw from the users deposited amount. The amount of win tokens transfered back depends on the withdraw amount
     */
    function withdraw(uint256 ethToWithdraw) external {
        if (!s_isParticipant[msg.sender]) {
            revert Pool__ParticipantIsNotInList();
        }
        if (ethToWithdraw > s_amountUserDeposited[msg.sender]) {
            revert Pool__CanOnlyWithdrawDepositedAmountOrLess();
        }
        if (ethToWithdraw == s_amountUserDeposited[msg.sender]) {
            _removeParticipant(msg.sender);
            i_winToken.returnAllUserTokens(msg.sender);
        }
        s_amountUserDeposited[msg.sender] -= ethToWithdraw;
        s_totalDeposits -= ethToWithdraw;
        i_winToken.returnUserTokens(msg.sender, ethToWithdraw);
        (bool success,) = payable(msg.sender).call{value: ethToWithdraw}("");
        if (!success) {
            revert Pool_WithdrawTransferBackToUserFail();
        }
    }

    // interest

    /**
     * @notice this function adds to accumulated interest since the last time this function was called
     * uint256 timeElapsed is the time (in seconds) since the last time interest was accrued to the contract
     * uint256 interestToMint calculates the interest (by mutliplying the total deposits, by interest rate, by the time in seconds)
     * it then mints this to the contract (pool), and sets the lastAccrued (last time interest was added to the pool balance)
     */
    function _accrueInterest() internal {
        uint256 timeElapsed = block.timestamp - s_lastAccrued;
        if (timeElapsed == 0) {
            return;
        }
        uint256 interestToMint = (s_totalDeposits * s_interestRate * timeElapsed) / PRECISION_FACTOR;
        s_poolBalance += interestToMint;
        s_lastAccrued = block.timestamp;
    }

    // list

    /**
     * @notice this is an internal function to push the user to the list, assigning them an index and true bool
     * @param _user the user we are adding to the list
     */
    function _addParticipants(address _user) internal {
        if (!s_isParticipant[_user]) {
            s_indexOfUser[_user] = s_participants.length;
            s_participants.push(_user);
            s_isParticipant[_user] = true;
        }
    }

    function _removeParticipant(address _user) internal {
        uint256 index = s_indexOfUser[_user];
        uint256 lastIndexInList = s_participants.length - 1;

        if (index != lastIndexInList) {
            address lastUser = s_participants[lastIndexInList];
            s_participants[index] = lastUser;
            s_indexOfUser[lastUser] = index;
        }
        s_participants.pop();

        delete s_indexOfUser[_user];
        s_isParticipant[_user] = false;
    }

    // getters

    /**
     * @notice gets whether the user has deposited (if they are in the deposited list)
     * @param _user the user we want to see if they've deposited
     */
    function getIsUserParticipant(address _user) external view returns (bool) {
        return s_isParticipant[_user];
    }

    /**
     * @return returns the pools balance from interest
     * As the pool will contain ETH outside of the ETH gained from interest accrued, we are tracking balances via
     * uint256 poolBalance, instead of address(this).balance
     */
    function getPoolBalance() external view returns (uint256) {
        return s_poolBalance;
    }
}
