// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.4;

import "../oz430/ERC20.sol";
import "./IDividendPayingToken.sol";
import "./IDividendPayingTokenOptional.sol";

/// @title Dividend-Paying Token
/// @author Roger Wu (https://github.com/roger-wu)
/// @dev A mintable ERC20 token that allows anyone to pay and distribute ether
/// to token holders as dividends and allows token holders to withdraw their dividends.
/// Reference: the source code of PoWH3D: https://etherscan.io/address/0xB3775fB83F7D12A36E0475aBdD1FCA35c091efBe#code

contract DividendPayingToken is ERC20, IDividendPayingToken, IDividendPayingTokenOptional {
    // With `dpt_magnitude`, we can properly distribute dividends even if the amount of received bnb is small.
    // For more discussion about choosing the value of `dpt_magnitude`,
    //  see https://github.com/ethereum/EIPs/issues/1726#issuecomment-472352728
    uint256 internal constant dpt_magnitude = 2**128;

    uint256 internal magnifiedDividendPerShare;
//    uint256 internal dpt_lastAmount;


    // About dividendCorrection:
    // If the token balance of a `_user` is never changed, the dividend of `_user` can be computed with:
    // `dividendOf(_user) = dividendPerShare * balanceOf(_user)`.
    // When `balanceOf(_user)` is changed (via minting/burning/transferring tokens),
    // `dividendOf(_user)` should not be changed,
    // but the computed value of `dividendPerShare * balanceOf(_user)` is changed.
    // To keep the `dividendOf(_user)` unchanged, we add a correction term:
    // `dividendOf(_user) = dividendPerShare * balanceOf(_user) + dividendCorrectionOf(_user)`,
    // where `dividendCorrectionOf(_user)` is updated whenever `balanceOf(_user)` is changed:
    // `dividendCorrectionOf(_user) = dividendPerShare * (old balanceOf(_user)) - (new balanceOf(_user))`.
    // So now `dividendOf(_user)` returns the same value before and after `balanceOf(_user)` is changed.
    mapping(address => int256) internal magnifiedDividendCorrections;
    mapping(address => uint256) internal withdrawnDividends;

    // Need to make gas fee customizable to future-proof against Ethereum network upgrades.
    uint256 public gasForTransfer;

    uint256 public totalDividendsDistributed;

    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol){
        gasForTransfer = 3000;
    }

    receive() external payable {
        distributeDividends();
    }

    /// @notice Distributes ether to token holders as dividends.
    /// @dev It reverts if the total supply of tokens is 0.
    /// It emits the `DividendsDistributed` event if the amount of received ether is greater than 0.
    /// About undistributed ether:
    ///   In each distribution, there is a small amount of ether not distributed,
    /// the magnified amount of which is
    /// `(msg.value * dpt_magnitude) % totalSupply()`.
    ///   With a well-chosen `dpt_magnitude`, the amount of undistributed ether
    /// (de-magnified) in a distribution can be less than 1 wei.
    ///   We can actually keep track of the undistributed ether in a distribution
    /// and try to distribute it in the next distribution,
    /// but keeping track of such data on-chain costs much more than
    ///     the saved ether, so we don't do that.
    function distributeDividends() public payable override {
        require(totalSupply() > 0);

        if (msg.value > 0) {
            magnifiedDividendPerShare =
            magnifiedDividendPerShare +
            (((msg.value) * (dpt_magnitude)) / totalSupply());
            emit DividendsDistributed(msg.sender, msg.value);

            totalDividendsDistributed = totalDividendsDistributed + msg.value;
        }
    }

    function distributeDividends(uint256 amount) public {
        require(totalSupply() > 0);

        if (amount > 0) {
            magnifiedDividendPerShare =
                magnifiedDividendPerShare +
                ((amount * dpt_magnitude) / totalSupply());
            emit DividendsDistributed(msg.sender, amount);

            totalDividendsDistributed = totalDividendsDistributed + amount;
        }
    }

    /// @notice Withdraws the ether distributed to the sender.
    /// @dev It emits a `DividendWithdrawn` event if the amount of withdrawn ether is greater than 0.
    function withdrawDividend() public virtual override {
        _withdrawDividendOfUser(payable(msg.sender));
    }

    /// @notice Withdraws the ether distributed to the sender.
    /// @dev It emits a `DividendWithdrawn` event if the amount of withdrawn ether is greater than 0.
    function _withdrawDividendOfUser(address payable user) internal returns (uint256){
        uint256 _withdrawableDividend = withdrawableDividendOf(user);
        if (_withdrawableDividend > 0) {
            withdrawnDividends[user] =
            withdrawnDividends[user] +
            _withdrawableDividend;
            emit DividendWithdrawn(user, _withdrawableDividend);
            (bool success,) = user.call{value: _withdrawableDividend, gas: gasForTransfer}("");

            if (!success) {
                withdrawnDividends[user] =
                withdrawnDividends[user] -
                _withdrawableDividend;
                return 0;
            }

            return _withdrawableDividend;
        }

        return 0;
    }

    /// @notice View the amount of dividend in wei that an address can withdraw.
    /// @param _owner The address of a token holder.
    /// @return The amount of dividend in wei that `_owner` can withdraw.
    function dividendOf(address _owner) public view override returns (uint256) {
        return withdrawableDividendOf(_owner);
    }

    /// @notice View the amount of dividend in wei that an address can withdraw.
    /// @param _owner The address of a token holder.
    /// @return The amount of dividend in wei that `_owner` can withdraw.
    function withdrawableDividendOf(address _owner) public view override returns (uint256){
        return accumulativeDividendOf(_owner) - withdrawnDividends[_owner];
    }

    /// @notice View the amount of dividend in wei that an address has withdrawn.
    /// @param _owner The address of a token holder.
    /// @return The amount of dividend in wei that `_owner` has withdrawn.
    function withdrawnDividendOf(address _owner) public view override returns (uint256){
        return withdrawnDividends[_owner];
    }

    /// @notice View the amount of dividend in wei that an address has earned in total.
    /// @dev accumulativeDividendOf(_owner) = withdrawableDividendOf(_owner) + withdrawnDividendOf(_owner)
    /// = (magnifiedDividendPerShare * balanceOf(_owner) + magnifiedDividendCorrections[_owner]) / dpt_magnitude
    /// @param _owner The address of a token holder.
    /// @return The amount of dividend in wei that `_owner` has earned in total.
    function accumulativeDividendOf(address _owner) public view override returns (uint256){
        return uint256(
            int256(magnifiedDividendPerShare * balanceOf(_owner)) +
            magnifiedDividendCorrections[_owner]
        ) / dpt_magnitude;
    }

    /// @dev Internal function that transfer tokens from one address to another.
    /// Update magnifiedDividendCorrections to keep dividends unchanged.
    /// @param from The address to transfer from.
    /// @param to The address to transfer to.
    /// @param value The amount to be transferred.
    function _transfer(address from, address to, uint256 value) internal virtual override {
        require(false);

        int256 _magCorrection = int256(magnifiedDividendPerShare * value);
        magnifiedDividendCorrections[from] =
        magnifiedDividendCorrections[from] +
        _magCorrection;
        magnifiedDividendCorrections[to] =
        magnifiedDividendCorrections[to] -
        _magCorrection;
    }

    /// @dev Internal function that mints tokens to an account.
    /// Update magnifiedDividendCorrections to keep dividends unchanged.
    /// @param account The account that will receive the created tokens.
    /// @param value The amount that will be created.
    function _mint(address account, uint256 value) internal override {
        super._mint(account, value);

        magnifiedDividendCorrections[account] =
        magnifiedDividendCorrections[account] -
        int256(magnifiedDividendPerShare * value);
    }

    /// @dev Internal function that burns an amount of the token of a given account.
    /// Update magnifiedDividendCorrections to keep dividends unchanged.
    /// @param account The account whose tokens will be burnt.
    /// @param value The amount that will be burnt.
    function _burn(address account, uint256 value) internal override {
        super._burn(account, value);

        magnifiedDividendCorrections[account] =
        magnifiedDividendCorrections[account] +
        int256(magnifiedDividendPerShare * value);
    }

    function _setBalance(address account, uint256 newBalance) internal {
        uint256 currentBalance = balanceOf(account);

        if (newBalance > currentBalance) {
            uint256 mintAmount = newBalance - currentBalance;
            _mint(account, mintAmount);
        } else if (newBalance < currentBalance) {
            uint256 burnAmount = currentBalance - newBalance;
            _burn(account, burnAmount);
        }
    }
}