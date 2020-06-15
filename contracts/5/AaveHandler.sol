pragma solidity 0.5.12;

import "./helpers/ReentrancyGuard.sol";
import "./interface/IAave.sol";
import "./library/ERC20SafeTransfer.sol";
import "./library/Pausable.sol";
import "./library/SafeMath.sol";
import "./dTokenAddresses.sol";

contract AaveHandler is ERC20SafeTransfer, ReentrancyGuard, Pausable {
    using SafeMath for uint256;

    bool private initialized; // Flags for initializing data
    uint256 internal BASE;

    address public dTokens;
    address public aaveLendingPool;
    address public aaveLendingPoolCore;

    mapping(address => bool) public tokensEnable;
    mapping(address => uint256) public interestsDetails;

    event NewdTokenAddresses(address indexed originaldToken, address indexed newdToken);
    event DisableToken(address indexed underlyingToken);
    event EnableToken(address indexed underlyingToken);

    constructor(
        address _dTokens,
        address _lendingPool,
        address _lendingPoolCore
    ) public {
        initialize(_dTokens, _lendingPool, _lendingPoolCore);
    }

    // --- Init ---
    // This function is used with contract proxy, do not modify this function.
    function initialize(
        address _dTokens,
        address _lendingPool,
        address _lendingPoolCore
    ) public {
        require(!initialized, "initialize: Already initialized!");
        owner = msg.sender;
        BASE = 1e18;
        dTokens = _dTokens;
        notEntered = true;
        aaveLendingPool = _lendingPool;
        aaveLendingPoolCore = _lendingPoolCore;
        initialized = true;
    }

    /**
     * @dev Update dToken mapping contract.
     * @param _newdTokens The new dToken mapping contact.
     */
    function setdTokens(address _newdTokens) external auth {
        require(_newdTokens != dTokens, "setdTokens: The same dToken address!");
        address _originaldTokens = dTokens;
        dTokens = _newdTokens;
        emit NewdTokenAddresses(_originaldTokens, _newdTokens);
    }

    /**
     * @dev Authorized function to disable an underlying token.
     * @param _underlyingToken Token to disable.
     */
    function disableToken(address _underlyingToken) external auth {
        require(tokensEnable[_underlyingToken], "disableToken: Has been disabled!");
        tokensEnable[_underlyingToken] = false;
        emit DisableToken(_underlyingToken);
    }

    /**
     * @dev Authorized function to enable an underlying token.
     * @param _underlyingToken Token to enable.
     */
    function enableToken(address _underlyingToken) external auth {
        require(!tokensEnable[_underlyingToken], "enableToken: Has been enabled!");
        tokensEnable[_underlyingToken] = true;
        emit EnableToken(_underlyingToken);
    }

    function setLendingPoolCore(address _newLendingPoolCore) external auth {
        aaveLendingPoolCore = _newLendingPoolCore;
    }

    function setLendingPool(address _newLendingPool) external auth {
        aaveLendingPool = _newLendingPool;
    }

    /**
     * @dev This token `_underlyingToken` approves to market and dToken contract.
     * @param _underlyingToken Token address to approve.
     */
    function approve(address _underlyingToken) public {
        address _dToken = dTokenAddresses(dTokens).getdToken(_underlyingToken);

        if (
            IERC20(_underlyingToken).allowance(
                address(this),
                aaveLendingPoolCore
            ) != uint256(-1)
        ) {
            require(
                doApprove(_underlyingToken, aaveLendingPoolCore, uint256(-1)),
                "approve: Approve aToken failed!"
            );
        }

        if (
            IERC20(_underlyingToken).allowance(address(this), _dToken) !=
            uint256(-1)
        ) {
            require(
                doApprove(_underlyingToken, _dToken, uint256(-1)),
                "approve: Approve dToken failed!"
            );
        }
    }

    /**
     * @dev Deposit token to market, but only for dToken contract.
     * @param _underlyingToken Token to deposit.
     * @return True is success, false is failure.
     */
    function deposit(address _underlyingToken, uint256 _amount)
        external
        whenNotPaused
        auth
        nonReentrant
        returns (uint256)
    {
        require(tokensEnable[_underlyingToken], "deposit: token is disabled!");

        require(
            _amount > 0,
            "deposit: Deposit amount should be greater than 0!"
        );
        address _aToken = getaToken(_underlyingToken);
        require(_aToken != address(0x0), "supply: Do not support token!");

        uint256 _previousBalance = getBalance(_underlyingToken);

        uint256 _principalBalance = getUnderlyingBalance(_underlyingToken);
        if (_previousBalance > _principalBalance) {
            uint256 _periodInterests = _previousBalance.sub(_principalBalance);
            interestsDetails[_underlyingToken] = interestsDetails[_underlyingToken]
                .add(_periodInterests);
        }
        // TODO: 0(uint16)?
        LendingPool(aaveLendingPool).deposit(
            _underlyingToken,
            _amount,
            uint16(0)
        );
        uint256 _currentBalance = getBalance(_underlyingToken);

        uint256 _changedAmount = _currentBalance.sub(_previousBalance);

        return _changedAmount;
    }

    /**
     * @dev Withdraw token from market, but only for dToken contract.
     * @param _underlyingToken Token to withdraw.
     * @param _amount Token amount to withdraw.
     * @return Actually withdraw token amount.
     */
    function withdraw(address _underlyingToken, uint256 _amount)
        external
        whenNotPaused
        auth
        nonReentrant
        returns (uint256)
    {
        address _aToken = getaToken(_underlyingToken);
        require(_aToken != address(0x0), "redeem: Do not support token!");

        require(_amount > 0, "redeem: Redeem amount should be greater than 0!");

        uint256 _lastPrincipalBalance = getBalance(_underlyingToken);
        uint256 _principalBalance = getUnderlyingBalance(_underlyingToken);
        if (_lastPrincipalBalance > _principalBalance) {
            uint256 _periodInterests = _lastPrincipalBalance.sub(
                _principalBalance
            );
            interestsDetails[_underlyingToken] = interestsDetails[_underlyingToken]
                .add(_periodInterests);
        }

        // aave supports redeem -1
        uint256 _previousBalance = IERC20(_underlyingToken).balanceOf(
            address(this)
        );
        AToken(_aToken).redeem(_amount);
        uint256 _currentBalance = IERC20(_underlyingToken).balanceOf(
            address(this)
        );

        uint256 _changedAmount = _currentBalance.sub(_previousBalance);

        return _changedAmount;
    }

    /**
     * @dev Total balance with any accumulated interest for `_token` belonging to `handler`
     * @param _token Token to get balance.
     */
    function getBalance(address _token) public view returns (uint256) {
        address _aToken = getaToken(_token);

        return AToken(_aToken).balanceOf(address(this));
    }

    /**
     * @dev The principal balance.
     */
    function getUnderlyingBalance(address _token)
        public
        view
        returns (uint256)
    {
        address _aToken = getaToken(_token);
        return AToken(_aToken).principalBalanceOf(address(this));
    }

    /**
     * @dev The maximum withdrawable amount of token `_token` in the market.
     * @param _token Token to get balance.
     */
    function getLiquidity(address _token) public view returns (uint256) {
        uint256 _underlyingBalance = getBalance(_token);
        if (_underlyingBalance == 0) {
            return 0;
        }

        uint256 _cash = IERC20(_token).balanceOf(aaveLendingPoolCore);

        if (_underlyingBalance > _cash) {
            return _cash;
        }

        return _underlyingBalance;
    }

    /**
     * @dev The maximum withdrawable amount of asset `_token` in the market,
     *      and excludes fee, if has.
     * @param _token Token to get actual balance.
     */
    function getRealBalance(address _token) external returns (uint256) {
        return getBalance(_token);
    }

    function getaToken(address _token) public view returns (address) {
        return
            LendingPoolCore(aaveLendingPoolCore).getReserveATokenAddress(
                _token
            );
    }
}
