// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice The part of the USDC ERC-20 interface this vault uses.
/// On Arc, USDC is the native gas token and this interface is a 6-decimal view
/// of the same balance (0x3600000000000000000000000000000000000000).
interface IUSDC {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title Agent Allowance Vault
/// @notice A person (the owner) funds this vault with USDC and gives each AI
/// agent key a spending policy. An agent can pay USDC within its policy and can
/// do nothing else. The owner can pause, revoke an agent and withdraw at any time.
///
/// "At any time" means as far as USDC itself allows: its issuer can blocklist an
/// address or pause the token, and then transfers revert.
///
/// Design rules:
///  - not upgradeable, no proxy, no delegatecall, no selfdestruct;
///  - one admin, the owner, fixed at deployment (rotate by deploying a new vault);
///  - one token, fixed at deployment. On Arc (chain 5042 and 5042002) the
///    constructor accepts only the canonical USDC address; on any other chain it
///    accepts any 6-decimal token, which is how the tests use a mock;
///  - no payable function, no receive and no fallback: a plain native send
///    reverts. On Arc the vault's USDC is its native balance all the same, and
///    value can still be forced in (for example as a selfdestruct beneficiary);
///    that only adds to what the owner can withdraw;
///  - checks, then effects, then the one state-changing external call, made
///    last, behind a reentrancy lock.
///
/// The daily cap is a rolling limit: at every payment, the agent's total over
/// the trailing 24 hours, including that payment, is at most the daily cap in
/// force at that payment. See `spentInWindow`.
///
/// Written by an AI system. Not professionally audited. Use at your own risk.
contract AgentAllowanceVault {
    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    struct Policy {
        uint128 maxPerPayment; // largest single payment, in USDC base units (6 decimals)
        uint128 maxPerDay; // largest total in any rolling 24 hours, same units
        uint64 expiry; // unix time; the agent can pay strictly before this
        uint32 payeeEpoch; // bumped by every setPolicy, which discards the old payee list
        bool restrictPayees; // true: only listed payees; false: any payee
        bool active; // false: never set, or revoked
    }

    // ------------------------------------------------------------------
    // Constants and immutables
    // ------------------------------------------------------------------

    /// @notice Spending is recorded in one-hour buckets.
    uint256 public constant BUCKET_SECONDS = 1 hours;

    /// @notice The cap is checked over the current bucket plus the 24 before it.
    /// That span is between 24 and 25 hours long, so it always contains the
    /// whole trailing 24 hours. The check is therefore never looser than a
    /// 24-hour rolling limit, and at most one hour stricter.
    uint256 public constant WINDOW_BUCKETS = 25;

    /// @notice USDC's ERC-20 interface on Arc mainnet and Arc Testnet.
    address public constant ARC_USDC = 0x3600000000000000000000000000000000000000;

    /// @notice The USDC token this vault holds and pays. Fixed forever.
    IUSDC public immutable usdc;

    /// @notice The only admin. Fixed forever.
    address public immutable owner;

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    /// @notice While true, no agent can pay. The owner can still withdraw.
    bool public paused;

    /// @notice Number of payments ever made; also the id of the latest payment.
    uint256 public paymentCount;

    /// @notice Lifetime total paid by each agent, in USDC base units.
    mapping(address agent => uint256) public totalPaidBy;

    uint256 private _lock = 1;
    mapping(address agent => Policy) private _policies;
    mapping(address agent => mapping(uint32 epoch => mapping(address payee => bool))) private _payeeAllowed;
    mapping(address agent => mapping(uint256 bucket => uint256)) private _spentInBucket;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event Paused();
    event Unpaused();
    event PolicySet(
        address indexed agent,
        uint256 maxPerPayment,
        uint256 maxPerDay,
        uint256 expiry,
        bool restrictPayees,
        uint32 payeeEpoch
    );
    event PayeeSet(address indexed agent, address indexed payee, bool allowed, uint32 payeeEpoch);
    event AgentRevoked(address indexed agent);

    /// @param memoHash a 32-byte commitment chosen by the agent, for example
    /// keccak256 of an invoice or of the reason for the payment
    /// @param id sequence number of the payment (1, 2, 3, ...)
    /// @param spentInWindow the agent's total in the rolling window after this payment
    event Payment(
        address indexed agent,
        address indexed payee,
        bytes32 indexed memoHash,
        uint256 id,
        uint256 amount,
        uint256 spentInWindow
    );

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error NotOwner();
    error ZeroAddress();
    error ZeroAmount();
    error NotUSDC();
    error Reentrancy();
    error TransferFailed();
    error InvalidPolicy();
    error ExpiryNotInFuture();
    error VaultPaused();
    error NoPolicy();
    error PolicyExpired(uint256 expiry);
    error InvalidPayee();
    error PayeeNotAllowed(address payee);
    error ExceedsPerPaymentCap(uint256 amount, uint256 maxPerPayment);
    error ExceedsDailyCap(uint256 amount, uint256 remaining);
    error InsufficientVaultBalance(uint256 amount, uint256 balance);

    // ------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    /// @param usdc_ the USDC ERC-20 interface (on Arc: 0x3600000000000000000000000000000000000000)
    /// @param owner_ the person who funds the vault and sets the policies
    constructor(address usdc_, address owner_) {
        if (usdc_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        // On Arc there is exactly one USDC; a look-alike token would strand real funds.
        if ((block.chainid == 5042 || block.chainid == 5042002) && usdc_ != ARC_USDC) revert NotUSDC();
        if (usdc_.code.length == 0) revert NotUSDC();
        if (IUSDC(usdc_).decimals() != 6) revert NotUSDC();
        usdc = IUSDC(usdc_);
        owner = owner_;
    }

    // ------------------------------------------------------------------
    // Funding (anyone may add funds; only the owner can take them out)
    // ------------------------------------------------------------------

    /// @notice Pull `amount` USDC from the caller into the vault. Needs a prior
    /// `approve`. Sending USDC to the vault with a plain ERC-20 `transfer` works
    /// too and needs no approval.
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        emit Deposited(msg.sender, amount);
        if (!usdc.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
    }

    /// @notice Owner takes `amount` USDC out. Works while paused. An agent's
    /// payment landing first can make an exact amount too large; use withdrawAll
    /// to empty the vault.
    function withdraw(address to, uint256 amount) external onlyOwner nonReentrant {
        _withdraw(to, amount);
    }

    /// @notice Owner takes everything out. Works while paused.
    function withdrawAll(address to) external onlyOwner nonReentrant {
        _withdraw(to, usdc.balanceOf(address(this)));
    }

    // ------------------------------------------------------------------
    // Owner controls
    // ------------------------------------------------------------------

    /// @notice Stop every agent from paying. Never reverts for the owner.
    function pause() external onlyOwner {
        if (!paused) {
            paused = true;
            emit Paused();
        }
    }

    /// @notice Let agents pay again.
    function unpause() external onlyOwner {
        if (paused) {
            paused = false;
            emit Unpaused();
        }
    }

    /// @notice Give `agent` a policy, replacing any earlier one and its payee list.
    /// The agent's spending history is kept, so replacing a policy never resets
    /// the rolling window.
    /// @param maxPerPayment largest single payment (USDC base units, 6 decimals)
    /// @param maxPerDay largest total in any rolling 24 hours (same units)
    /// @param expiry unix time from which the agent can no longer pay (it can pay strictly before)
    /// @param restrictPayees true to allow only `payees`; false to allow any payee
    /// @param payees the allowed payees; must be empty when `restrictPayees` is false
    function setPolicy(
        address agent,
        uint256 maxPerPayment,
        uint256 maxPerDay,
        uint256 expiry,
        bool restrictPayees,
        address[] calldata payees
    ) external onlyOwner {
        if (agent == address(0)) revert ZeroAddress();
        if (maxPerPayment == 0 || maxPerDay < maxPerPayment || maxPerDay > type(uint128).max) revert InvalidPolicy();
        if (!restrictPayees && payees.length != 0) revert InvalidPolicy();
        if (expiry <= block.timestamp || expiry > type(uint64).max) revert ExpiryNotInFuture();

        uint32 epoch = _policies[agent].payeeEpoch + 1;
        // The three casts are safe: maxPerPayment <= maxPerDay <= type(uint128).max
        // and expiry <= type(uint64).max were all checked just above.
        _policies[agent] = Policy({
            // forge-lint: disable-next-line(unsafe-typecast)
            maxPerPayment: uint128(maxPerPayment),
            // forge-lint: disable-next-line(unsafe-typecast)
            maxPerDay: uint128(maxPerDay),
            // forge-lint: disable-next-line(unsafe-typecast)
            expiry: uint64(expiry),
            payeeEpoch: epoch,
            restrictPayees: restrictPayees,
            active: true
        });
        emit PolicySet(agent, maxPerPayment, maxPerDay, expiry, restrictPayees, epoch);

        for (uint256 i = 0; i < payees.length; ++i) {
            _setPayee(agent, epoch, payees[i], true);
        }
    }

    /// @notice Add or remove one allowed payee of an agent whose policy restricts
    /// payees. Reverts for a policy that allows any payee, where a list would
    /// have no effect: use setPolicy to switch the restriction on.
    function setPayee(address agent, address payee, bool allowed) external onlyOwner {
        Policy storage p = _policies[agent];
        if (!p.active) revert NoPolicy();
        if (!p.restrictPayees) revert InvalidPolicy();
        _setPayee(agent, p.payeeEpoch, payee, allowed);
    }

    /// @notice Take away an agent's right to pay. Never reverts for the owner.
    function revokeAgent(address agent) external onlyOwner {
        Policy storage p = _policies[agent];
        if (p.active) {
            p.active = false;
            p.maxPerPayment = 0;
            p.maxPerDay = 0;
            p.expiry = 0;
            p.restrictPayees = false;
            // payeeEpoch is kept so that a later setPolicy cannot revive old payees.
            emit AgentRevoked(agent);
        }
    }

    // ------------------------------------------------------------------
    // The one thing an agent can do
    // ------------------------------------------------------------------

    /// @notice Pay `amount` USDC to `payee` under the caller's policy.
    /// @param memoHash a 32-byte commitment recorded in the Payment event
    /// @return id the sequence number of this payment
    function pay(address payee, uint256 amount, bytes32 memoHash) external nonReentrant returns (uint256 id) {
        // checks
        if (paused) revert VaultPaused();
        Policy memory p = _policies[msg.sender];
        if (!p.active) revert NoPolicy();
        if (block.timestamp >= p.expiry) revert PolicyExpired(p.expiry);
        if (amount == 0) revert ZeroAmount();
        if (payee == address(0) || payee == address(this)) revert InvalidPayee();
        if (amount > p.maxPerPayment) revert ExceedsPerPaymentCap(amount, p.maxPerPayment);
        if (p.restrictPayees && !_payeeAllowed[msg.sender][p.payeeEpoch][payee]) revert PayeeNotAllowed(payee);
        uint256 spent = spentInWindow(msg.sender);
        if (spent + amount > p.maxPerDay) {
            revert ExceedsDailyCap(amount, p.maxPerDay > spent ? p.maxPerDay - spent : 0);
        }
        uint256 balance = usdc.balanceOf(address(this));
        if (amount > balance) revert InsufficientVaultBalance(amount, balance);

        // effects
        _spentInBucket[msg.sender][block.timestamp / BUCKET_SECONDS] += amount;
        totalPaidBy[msg.sender] += amount;
        id = ++paymentCount;
        emit Payment(msg.sender, payee, memoHash, id, amount, spent + amount);

        // interaction
        if (!usdc.transfer(payee, amount)) revert TransferFailed();
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice The policy of `agent` (all zero if it never had one or was revoked,
    /// apart from `payeeEpoch`).
    function policyOf(address agent) external view returns (Policy memory) {
        return _policies[agent];
    }

    /// @notice Whether `payee` is an acceptable payee under `agent`'s current
    /// policy. Looks only at the payee rule: not at expiry, pause, caps or balance.
    function isPayeeAllowed(address agent, address payee) public view returns (bool) {
        Policy storage p = _policies[agent];
        if (!p.active || payee == address(0) || payee == address(this)) return false;
        return !p.restrictPayees || _payeeAllowed[agent][p.payeeEpoch][payee];
    }

    /// @notice What `agent` has paid in the current one-hour bucket and the 24
    /// buckets before it. This always includes every payment of the last 24 hours.
    function spentInWindow(address agent) public view returns (uint256 total) {
        uint256 bucket = block.timestamp / BUCKET_SECONDS;
        uint256 n = bucket + 1 < WINDOW_BUCKETS ? bucket + 1 : WINDOW_BUCKETS;
        for (uint256 i = 0; i < n; ++i) {
            total += _spentInBucket[agent][bucket - i];
        }
    }

    /// @notice The largest single payment `agent` could make right now to a payee
    /// its policy accepts: zero if paused, without a policy or expired; otherwise
    /// the smallest of the per-payment cap, what is left of the daily cap and the
    /// vault balance. It does not look at the payee list.
    function availableToPay(address agent) external view returns (uint256) {
        Policy memory p = _policies[agent];
        if (paused || !p.active || block.timestamp >= p.expiry) return 0;
        uint256 spent = spentInWindow(agent);
        uint256 available = p.maxPerDay > spent ? p.maxPerDay - spent : 0;
        if (available > p.maxPerPayment) available = p.maxPerPayment;
        uint256 balance = usdc.balanceOf(address(this));
        return available < balance ? available : balance;
    }

    /// @notice USDC held by the vault, in base units (6 decimals).
    function vaultBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _withdraw(address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert InvalidPayee();
        if (amount == 0) revert ZeroAmount();
        uint256 balance = usdc.balanceOf(address(this));
        if (amount > balance) revert InsufficientVaultBalance(amount, balance);
        emit Withdrawn(to, amount);
        if (!usdc.transfer(to, amount)) revert TransferFailed();
    }

    function _setPayee(address agent, uint32 epoch, address payee, bool allowed) private {
        if (payee == address(0) || payee == address(this)) revert InvalidPayee();
        _payeeAllowed[agent][epoch][payee] = allowed;
        emit PayeeSet(agent, payee, allowed, epoch);
    }
}
