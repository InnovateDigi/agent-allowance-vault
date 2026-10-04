// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AgentAllowanceVault} from "../src/AgentAllowanceVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Property tests for the rolling daily cap.
///
/// Safety:   for every instant t, what an agent paid in (t - 24h, t] is at most the cap.
/// Fairness: a payment is refused for the daily cap only if the last 25 hours plus
///           the payment would exceed the cap (the check is at most 1 hour strict).
contract DailyCapPropertyTest is Test {
    uint256 internal constant USDC1 = 1e6;
    uint256 internal constant T0 = 1_790_000_000;
    uint256 internal constant STEPS = 72;

    MockUSDC internal usdc;
    AgentAllowanceVault internal vault;
    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agent");
    address internal payee = makeAddr("payee");

    uint256[] internal paidAt;
    uint256[] internal paidAmount;

    function setUp() public {
        vm.warp(T0);
        usdc = new MockUSDC();
        vault = new AgentAllowanceVault(address(usdc), owner);
        usdc.mint(address(vault), 1_000_000 * USDC1);
    }

    /// @dev Sum of recorded payments made strictly after `since`.
    function _paidAfter(uint256 since) internal view returns (uint256 total) {
        for (uint256 i = paidAt.length; i > 0; --i) {
            if (paidAt[i - 1] <= since) break; // times are non-decreasing
            total += paidAmount[i - 1];
        }
    }

    /// @dev Time steps chosen to hit the edges: the same second (Arc blocks may
    /// share a timestamp), seconds, exact hours, just under a day and long gaps.
    function _step(uint256 r) internal pure returns (uint256) {
        uint256 kind = r % 10;
        uint256 x = r >> 8;
        if (kind == 0) return 0;
        if (kind == 1) return 1;
        if (kind == 2) return x % 60;
        if (kind == 3) return 3600;
        if (kind == 4) return 3600 * (1 + (x % 26));
        if (kind == 5) return 24 hours - 1 - (x % 3);
        if (kind == 6) return 24 hours + (x % 3);
        if (kind == 7) return x % (26 hours);
        return x % (3 hours);
    }

    function testFuzz_rollingDailyCapIsNeverExceeded(uint256 seed, uint256 perPaymentSeed, uint256 perDaySeed) public {
        uint256 perPayment = bound(perPaymentSeed, 1, 500 * USDC1);
        uint256 perDay = bound(perDaySeed, perPayment, 2_000 * USDC1);
        vm.prank(owner);
        vault.setPolicy(agent, perPayment, perDay, T0 + 3650 days, false, new address[](0));

        for (uint256 i = 0; i < STEPS; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(block.timestamp + _step(seed));
            uint256 amount = bound(uint256(keccak256(abi.encode(seed, "amount"))), 1, perPayment);

            uint256 last24h = _paidAfter(block.timestamp - 24 hours);
            uint256 last25h = _paidAfter(block.timestamp - 25 hours);

            // The vault's own figure always lies between the 24h and the 25h totals.
            uint256 window = vault.spentInWindow(agent);
            assertGe(window, last24h, "window misses a payment of the last 24h");
            assertLe(window, last25h, "window counts a payment older than 25h");

            vm.prank(agent);
            try vault.pay(payee, amount, bytes32(i)) {
                assertLe(last24h + amount, perDay, "SAFETY: rolling 24h total above the cap");
                paidAt.push(block.timestamp);
                paidAmount.push(amount);
            } catch (bytes memory reason) {
                assertEq(bytes4(reason), AgentAllowanceVault.ExceedsDailyCap.selector, "unexpected revert");
                assertGt(last25h + amount, perDay, "FAIRNESS: refused although the last 25h leave room");
            }
        }

        // Safety again, from the record alone: the worst 24h window ends at a payment.
        uint256 total;
        for (uint256 j = 0; j < paidAt.length; ++j) {
            total += paidAmount[j];
            uint256 inWindow;
            for (uint256 k = j + 1; k > 0; --k) {
                if (paidAt[k - 1] + 24 hours <= paidAt[j]) break;
                inWindow += paidAmount[k - 1];
            }
            assertLe(inWindow, perDay, "SAFETY: a 24h window above the cap");
        }
        assertEq(usdc.balanceOf(payee), total);
        assertEq(vault.totalPaidBy(agent), total);
        assertEq(vault.paymentCount(), paidAt.length);
    }

    /// @notice The per-payment cap and the daily cap hold for arbitrary single calls.
    function testFuzz_singlePaymentRespectsBothCaps(uint256 perPayment, uint256 perDay, uint256 amount) public {
        perPayment = bound(perPayment, 1, 1_000 * USDC1);
        perDay = bound(perDay, perPayment, 5_000 * USDC1);
        amount = bound(amount, 0, 10_000 * USDC1);
        vm.prank(owner);
        vault.setPolicy(agent, perPayment, perDay, T0 + 1 days, false, new address[](0));

        vm.prank(agent);
        try vault.pay(payee, amount, bytes32(0)) {
            assertGt(amount, 0);
            assertLe(amount, perPayment);
            assertLe(amount, perDay);
            assertEq(usdc.balanceOf(payee), amount);
        } catch {
            assertTrue(amount == 0 || amount > perPayment, "a valid first payment was refused");
            assertEq(usdc.balanceOf(payee), 0);
        }
    }

    /// @notice Nobody but the owner can use an owner function, whatever the caller.
    function testFuzz_onlyOwnerCanAdminister(address caller, address target, uint256 amount) public {
        vm.assume(caller != owner);
        vm.startPrank(caller);
        vm.expectRevert(AgentAllowanceVault.NotOwner.selector);
        vault.withdraw(target, amount);
        vm.expectRevert(AgentAllowanceVault.NotOwner.selector);
        vault.withdrawAll(target);
        vm.expectRevert(AgentAllowanceVault.NotOwner.selector);
        vault.pause();
        vm.expectRevert(AgentAllowanceVault.NotOwner.selector);
        vault.unpause();
        vm.expectRevert(AgentAllowanceVault.NotOwner.selector);
        vault.setPolicy(target, 1, 1, block.timestamp + 1, false, new address[](0));
        vm.expectRevert(AgentAllowanceVault.NotOwner.selector);
        vault.setPayee(target, target, true);
        vm.expectRevert(AgentAllowanceVault.NotOwner.selector);
        vault.revokeAgent(target);
        vm.stopPrank();
    }

    /// @notice An address without a policy can never move funds.
    function testFuzz_noPolicyNoPayment(address caller, address to, uint256 amount) public {
        vm.assume(caller != owner);
        uint256 before = usdc.balanceOf(address(vault));
        vm.prank(caller);
        vm.expectRevert(AgentAllowanceVault.NoPolicy.selector);
        vault.pay(to, amount, bytes32(0));
        assertEq(usdc.balanceOf(address(vault)), before);
    }
}

/// @notice Drives the vault with random actions by an owner and three agents and
/// keeps an independent record of what should have happened.
contract VaultHandler is Test {
    uint256 internal constant USDC1 = 1e6;

    MockUSDC public usdc;
    AgentAllowanceVault public vault;
    address public owner;
    address[3] public agents;
    address[3] public payees;

    uint256 public deposited;
    uint256 public withdrawn;
    uint256 public paid;
    uint256 public payments;
    uint256 public violations; // any payment that should not have gone through
    mapping(address => uint256) public paidBy;
    mapping(address => uint256[]) internal _at;
    mapping(address => uint256[]) internal _amount;

    constructor(MockUSDC usdc_, AgentAllowanceVault vault_, address owner_) {
        usdc = usdc_;
        vault = vault_;
        owner = owner_;
        for (uint256 i = 0; i < 3; ++i) {
            agents[i] = makeAddr(string(abi.encodePacked("agent", vm.toString(i))));
            payees[i] = makeAddr(string(abi.encodePacked("payee", vm.toString(i))));
        }
    }

    function paidAfter(address agent, uint256 since) public view returns (uint256 total) {
        uint256[] storage at = _at[agent];
        for (uint256 i = at.length; i > 0; --i) {
            if (at[i - 1] <= since) break;
            total += _amount[agent][i - 1];
        }
    }

    function payeeTotal() external view returns (uint256 total) {
        for (uint256 i = 0; i < 3; ++i) {
            total += usdc.balanceOf(payees[i]);
        }
    }

    /// @dev Moves time with a bias towards the edges of the rolling window.
    function warp(uint256 r) external {
        uint256 kind = r % 8;
        uint256 x = r >> 8;
        uint256 dt;
        if (kind == 0) dt = 0; // the next action shares this timestamp
        else if (kind == 1) dt = 3600 - (block.timestamp % 3600); // exactly onto the next bucket
        else if (kind == 2) dt = 24 hours - 1 - (x % 3);
        else if (kind == 3) dt = 24 hours + (x % 3);
        else if (kind == 4) dt = 3600 * (1 + (x % 26));
        else dt = x % (9 hours);
        vm.warp(block.timestamp + dt);
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 1, 500 * USDC1);
        usdc.mint(owner, amount);
        vm.startPrank(owner);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
        deposited += amount;
    }

    function withdraw(uint256 amount) external {
        uint256 balance = usdc.balanceOf(address(vault));
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(owner);
        vault.withdraw(owner, amount);
        withdrawn += amount;
    }

    function togglePause(bool on) external {
        vm.prank(owner);
        if (on) vault.pause();
        else vault.unpause();
    }

    function setPolicy(uint256 who, uint256 perPayment, uint256 perDay, uint256 life, bool restrict) external {
        address agent = agents[who % 3];
        perPayment = bound(perPayment, 1, 50 * USDC1);
        perDay = bound(perDay, perPayment, 200 * USDC1);
        address[] memory list = new address[](restrict ? 1 : 0);
        if (restrict) list[0] = payees[who % 3];
        vm.prank(owner);
        vault.setPolicy(agent, perPayment, perDay, block.timestamp + bound(life, 1, 3 days), restrict, list);
    }

    function revoke(uint256 who) external {
        vm.prank(owner);
        vault.revokeAgent(agents[who % 3]);
    }

    function pay(uint256 who, uint256 to, uint256 amount, bytes32 memo) external {
        address agent = agents[who % 3];
        address payee = payees[to % 3];
        amount = bound(amount, 0, 80 * USDC1);

        AgentAllowanceVault.Policy memory p = vault.policyOf(agent);
        bool wasPaused = vault.paused();
        bool allowed = vault.isPayeeAllowed(agent, payee);
        uint256 last24h = paidAfter(agent, block.timestamp - 24 hours);
        uint256 balance = usdc.balanceOf(address(vault));

        vm.prank(agent);
        try vault.pay(payee, amount, memo) {
            if (
                wasPaused || !p.active || block.timestamp >= p.expiry || amount == 0 || amount > p.maxPerPayment
                    || !allowed || last24h + amount > p.maxPerDay || amount > balance
            ) {
                ++violations;
            }
            _at[agent].push(block.timestamp);
            _amount[agent].push(amount);
            paidBy[agent] += amount;
            paid += amount;
            ++payments;
        } catch {}
    }
}

contract VaultInvariantTest is Test {
    uint256 internal constant T0 = 1_790_000_000;
    MockUSDC internal usdc;
    AgentAllowanceVault internal vault;
    VaultHandler internal handler;
    address internal owner = makeAddr("owner");

    function setUp() public {
        vm.warp(T0);
        usdc = new MockUSDC();
        vault = new AgentAllowanceVault(address(usdc), owner);
        handler = new VaultHandler(usdc, vault, owner);
        targetContract(address(handler));
    }

    /// @notice No payment ever went through against a rule (pause, policy, expiry,
    /// per-payment cap, payee list, rolling daily cap, vault balance).
    function invariant_noPaymentBreaksARule() public view {
        assertEq(handler.violations(), 0);
    }

    /// @notice Money only leaves through recorded payments and owner withdrawals.
    function invariant_fundsAreConserved() public view {
        assertEq(usdc.balanceOf(address(vault)) + handler.withdrawn() + handler.paid(), handler.deposited());
        assertEq(handler.payeeTotal(), handler.paid());
        assertEq(vault.paymentCount(), handler.payments());
    }

    /// @notice The vault's books match the independent record for every agent,
    /// and its window always covers at least the last 24 hours.
    function invariant_booksMatchAndWindowCoversTheDay() public view {
        for (uint256 i = 0; i < 3; ++i) {
            address agent = handler.agents(i);
            assertEq(vault.totalPaidBy(agent), handler.paidBy(agent));
            uint256 window = vault.spentInWindow(agent);
            assertGe(window, handler.paidAfter(agent, block.timestamp - 24 hours));
            assertLe(window, handler.paidAfter(agent, block.timestamp - 25 hours));
        }
    }
}
