// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AgentAllowanceVault} from "../src/AgentAllowanceVault.sol";
import {MockUSDC, ReentrantToken, FalseReturnToken, EighteenDecimalsToken} from "./mocks/MockUSDC.sol";

abstract contract VaultFixture is Test {
    uint256 internal constant USDC1 = 1e6;
    uint256 internal constant T0 = 1_790_000_000; // a realistic clock
    uint256 internal constant PER_PAYMENT = 10 * USDC1;
    uint256 internal constant PER_DAY = 25 * USDC1;

    MockUSDC internal usdc;
    AgentAllowanceVault internal vault;

    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agent");
    address internal agent2 = makeAddr("agent2");
    address internal payee = makeAddr("payee");
    address internal payee2 = makeAddr("payee2");
    address internal stranger = makeAddr("stranger");

    function setUp() public virtual {
        vm.warp(T0);
        usdc = new MockUSDC();
        vault = new AgentAllowanceVault(address(usdc), owner);
        usdc.mint(owner, 10_000 * USDC1);
        vm.startPrank(owner);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_000 * USDC1);
        vm.stopPrank();
    }

    function _open(address a, uint256 perPayment, uint256 perDay, uint256 expiry) internal {
        vm.prank(owner);
        vault.setPolicy(a, perPayment, perDay, expiry, false, new address[](0));
    }

    function _restricted(address a, address onlyPayee) internal {
        address[] memory list = new address[](1);
        list[0] = onlyPayee;
        vm.prank(owner);
        vault.setPolicy(a, PER_PAYMENT, PER_DAY, T0 + 30 days, true, list);
    }

    function _defaultPolicy() internal {
        _open(agent, PER_PAYMENT, PER_DAY, T0 + 30 days);
    }

    function _pay(uint256 amount) internal returns (uint256) {
        vm.prank(agent);
        return vault.pay(payee, amount, bytes32(0));
    }
}

contract ConstructorTest is VaultFixture {
    function test_storesTokenAndOwner() public view {
        assertEq(address(vault.usdc()), address(usdc));
        assertEq(vault.owner(), owner);
        assertFalse(vault.paused());
        assertEq(vault.paymentCount(), 0);
        assertEq(vault.BUCKET_SECONDS(), 3600);
        assertEq(vault.WINDOW_BUCKETS(), 25);
    }

    function test_revert_zeroToken() public {
        vm.expectRevert(AgentAllowanceVault.ZeroAddress.selector);
        new AgentAllowanceVault(address(0), owner);
    }

    function test_revert_zeroOwner() public {
        vm.expectRevert(AgentAllowanceVault.ZeroAddress.selector);
        new AgentAllowanceVault(address(usdc), address(0));
    }

    function test_revert_tokenWithoutCode() public {
        vm.expectRevert(AgentAllowanceVault.NotUSDC.selector);
        new AgentAllowanceVault(makeAddr("not a contract"), owner);
    }

    function test_revert_tokenWithWrongDecimals() public {
        address bad = address(new EighteenDecimalsToken());
        vm.expectRevert(AgentAllowanceVault.NotUSDC.selector);
        new AgentAllowanceVault(bad, owner);
    }

    function test_onArcOnlyTheCanonicalUsdcIsAccepted() public {
        address arcUsdc = vault.ARC_USDC();
        assertEq(arcUsdc, 0x3600000000000000000000000000000000000000);
        uint256[2] memory arcChains = [uint256(5042), uint256(5042002)];
        for (uint256 i = 0; i < 2; ++i) {
            vm.chainId(arcChains[i]);
            // a look-alike 6-decimal token is refused on Arc ...
            vm.expectRevert(AgentAllowanceVault.NotUSDC.selector);
            new AgentAllowanceVault(address(usdc), owner);
            // ... and the canonical address is accepted (the mock's code stands in for USDC here)
            vm.etch(arcUsdc, address(usdc).code);
            AgentAllowanceVault v = new AgentAllowanceVault(arcUsdc, owner);
            assertEq(address(v.usdc()), arcUsdc);
        }
        vm.chainId(31337);
        new AgentAllowanceVault(address(usdc), owner); // other chains: any 6-decimal token, as in these tests
    }

    function test_rejectsNativeValue() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertFalse(ok, "the vault must not accept native value");
    }

    function test_unknownSelectorReverts() public {
        (bool ok,) = address(vault).call(abi.encodeWithSignature("upgradeTo(address)", stranger));
        assertFalse(ok);
    }
}

contract FundingTest is VaultFixture {
    function test_depositPullsFundsAndEmits() public {
        vm.expectEmit(true, true, true, true, address(vault));
        emit AgentAllowanceVault.Deposited(owner, 5 * USDC1);
        vm.prank(owner);
        vault.deposit(5 * USDC1);
        assertEq(vault.vaultBalance(), 1_005 * USDC1);
        assertEq(usdc.balanceOf(owner), 8_995 * USDC1);
    }

    function test_anyoneCanDeposit() public {
        usdc.mint(stranger, 3 * USDC1);
        vm.startPrank(stranger);
        usdc.approve(address(vault), 3 * USDC1);
        vault.deposit(3 * USDC1);
        vm.stopPrank();
        assertEq(vault.vaultBalance(), 1_003 * USDC1);
    }

    function test_plainTransferAlsoFunds() public {
        vm.prank(owner);
        assertTrue(usdc.transfer(address(vault), 7 * USDC1));
        assertEq(vault.vaultBalance(), 1_007 * USDC1);
    }

    function test_revert_depositZero() public {
        vm.prank(owner);
        vm.expectRevert(AgentAllowanceVault.ZeroAmount.selector);
        vault.deposit(0);
    }

    function test_revert_depositWithoutApproval() public {
        usdc.mint(stranger, 3 * USDC1);
        vm.prank(stranger);
        vm.expectRevert(bytes("ERC20: insufficient allowance"));
        vault.deposit(3 * USDC1);
    }

    function test_withdrawByOwner() public {
        vm.expectEmit(true, true, true, true, address(vault));
        emit AgentAllowanceVault.Withdrawn(stranger, 40 * USDC1);
        vm.prank(owner);
        vault.withdraw(stranger, 40 * USDC1);
        assertEq(usdc.balanceOf(stranger), 40 * USDC1);
        assertEq(vault.vaultBalance(), 960 * USDC1);
    }

    function test_withdrawAll() public {
        vm.prank(owner);
        vault.withdrawAll(owner);
        assertEq(vault.vaultBalance(), 0);
        assertEq(usdc.balanceOf(owner), 10_000 * USDC1);
    }

    function test_withdrawWorksWhilePaused() public {
        vm.startPrank(owner);
        vault.pause();
        vault.withdrawAll(owner);
        vm.stopPrank();
        assertEq(vault.vaultBalance(), 0);
    }

    function test_revert_withdrawNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(AgentAllowanceVault.NotOwner.selector);
        vault.withdraw(stranger, 1);
        vm.prank(stranger);
        vm.expectRevert(AgentAllowanceVault.NotOwner.selector);
        vault.withdrawAll(stranger);
    }

    function test_revert_agentCannotWithdraw() public {
        _defaultPolicy();
        vm.prank(agent);
        vm.expectRevert(AgentAllowanceVault.NotOwner.selector);
        vault.withdraw(agent, 1);
        vm.prank(agent);
        vm.expectRevert(AgentAllowanceVault.NotOwner.selector);
        vault.withdrawAll(agent);
    }

    function test_revert_withdrawToZeroOrSelf() public {
        vm.startPrank(owner);
        vm.expectRevert(AgentAllowanceVault.ZeroAddress.selector);
        vault.withdraw(address(0), 1);
        vm.expectRevert(AgentAllowanceVault.InvalidPayee.selector);
        vault.withdraw(address(vault), 1);
        vm.stopPrank();
    }

    function test_revert_withdrawZero() public {
        vm.prank(owner);
        vm.expectRevert(AgentAllowanceVault.ZeroAmount.selector);
        vault.withdraw(owner, 0);
    }

    function test_revert_withdrawAllWhenEmpty() public {
        vm.startPrank(owner);
        vault.withdrawAll(owner);
        vm.expectRevert(AgentAllowanceVault.ZeroAmount.selector);
        vault.withdrawAll(owner);
        vm.stopPrank();
    }

    function test_revert_withdrawMoreThanBalance() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(AgentAllowanceVault.InsufficientVaultBalance.selector, 1_001 * USDC1, 1_000 * USDC1)
        );
        vault.withdraw(owner, 1_001 * USDC1);
    }

    function test_revert_transferReportingFalse() public {
        FalseReturnToken bad = new FalseReturnToken();
        AgentAllowanceVault v = new AgentAllowanceVault(address(bad), owner);
        bad.mint(address(v), 10 * USDC1);
        vm.startPrank(owner);
        vm.expectRevert(AgentAllowanceVault.TransferFailed.selector);
        v.deposit(1);
        vm.expectRevert(AgentAllowanceVault.TransferFailed.selector);
        v.withdraw(owner, 1);
        v.setPolicy(agent, PER_PAYMENT, PER_DAY, T0 + 1 days, false, new address[](0));
        vm.stopPrank();
        vm.prank(agent);
        vm.expectRevert(AgentAllowanceVault.TransferFailed.selector);
        v.pay(payee, 1, bytes32(0));
        assertEq(v.paymentCount(), 0);
        assertEq(v.spentInWindow(agent), 0);
    }
}

contract PauseTest is VaultFixture {
    function test_pauseBlocksPayAndUnpauseRestores() public {
        _defaultPolicy();
        vm.expectEmit(true, true, true, true, address(vault));
        emit AgentAllowanceVault.Paused();
        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused());
        assertEq(vault.availableToPay(agent), 0);

        vm.prank(agent);
        vm.expectRevert(AgentAllowanceVault.VaultPaused.selector);
        vault.pay(payee, USDC1, bytes32(0));

        vm.expectEmit(true, true, true, true, address(vault));
        emit AgentAllowanceVault.Unpaused();
        vm.prank(owner);
        vault.unpause();
        assertFalse(vault.paused());
        _pay(USDC1);
        assertEq(usdc.balanceOf(payee), USDC1);
    }

    function test_pauseIsIdempotent() public {
        vm.startPrank(owner);
        vault.pause();
        vault.pause();
        assertTrue(vault.paused());
        vault.unpause();
        vault.unpause();
        assertFalse(vault.paused());
        vm.stopPrank();
    }

    function test_revert_pauseNotOwner() public {
        _defaultPolicy();
        vm.prank(stranger);
        vm.expectRevert(AgentAllowanceVault.NotOwner.selector);
        vault.pause();
        vm.prank(agent);
        vm.expectRevert(AgentAllowanceVault.NotOwner.selector);
        vault.pause();
    }

    function test_revert_unpauseNotOwner() public {
        _defaultPolicy();
        vm.prank(owner);
        vault.pause();
        vm.prank(agent);
        vm.expectRevert(AgentAllowanceVault.NotOwner.selector);
        vault.unpause();
        vm.prank(stranger);
        vm.expectRevert(AgentAllowanceVault.NotOwner.selector);
        vault.unpause();
    }
}

contract PolicyTest is VaultFixture {
    function test_setPolicyStoresAndEmits() public {
        address[] memory list = new address[](2);
        list[0] = payee;
        list[1] = payee2;
        vm.expectEmit(true, true, true, true, address(vault));
        emit AgentAllowanceVault.PolicySet(agent, PER_PAYMENT, PER_DAY, T0 + 7 days, true, 1);
        vm.expectEmit(true, true, true, true, address(vault));
        emit AgentAllowanceVault.PayeeSet(agent, payee, true, 1);
        vm.expectEmit(true, true, true, true, address(vault));
        emit AgentAllowanceVault.PayeeSet(agent, payee2, true, 1);
        vm.prank(owner);
        vault.setPolicy(agent, PER_PAYMENT, PER_DAY, T0 + 7 days, true, list);

        AgentAllowanceVault.Policy memory p = vault.policyOf(agent);
        assertEq(p.maxPerPayment, PER_PAYMENT);
        assertEq(p.maxPerDay, PER_DAY);
        assertEq(p.expiry, T0 + 7 days);
        assertEq(p.payeeEpoch, 1);
        assertTrue(p.restrictPayees);
        assertTrue(p.active);
        assertTrue(vault.isPayeeAllowed(agent, payee));
        assertTrue(vault.isPayeeAllowed(agent, payee2));
        assertFalse(vault.isPayeeAllowed(agent, stranger));
    }

    function test_unrestrictedPolicyAllowsAnyPayeeButNotZeroOrVault() public {
        _defaultPolicy();
        assertTrue(vault.isPayeeAllowed(agent, stranger));
        assertFalse(vault.isPayeeAllowed(agent, address(0)));
        assertFalse(vault.isPayeeAllowed(agent, address(vault)));
        assertFalse(vault.isPayeeAllowed(agent2, stranger), "no policy, no payee");
    }

    function test_replacingPolicyDiscardsOldPayees() public {
        _restricted(agent, payee);
        assertTrue(vault.isPayeeAllowed(agent, payee));
        _restricted(agent, payee2);
        assertFalse(vault.isPayeeAllowed(agent, payee), "old payee must be gone");
        assertTrue(vault.isPayeeAllowed(agent, payee2));
        assertEq(vault.policyOf(agent).payeeEpoch, 2);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentAllowanceVault.PayeeNotAllowed.selector, payee));
        vault.pay(payee, USDC1, bytes32(0));
    }

    function test_revert_setPolicyNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(AgentAllowanceVault.NotOwner.selector);
        vault.setPolicy(stranger, PER_PAYMENT, PER_DAY, T0 + 1 days, false, new address[](0));
    }

    function test_revert_agentCannotChangeItsOwnPolicy() public {
        _defaultPolicy();
        vm.prank(agent);
        vm.expectRevert(AgentAllowanceVault.NotOwner.selector);
        vault.setPolicy(agent, 1_000 * USDC1, 1_000 * USDC1, T0 + 365 days, false, new address[](0));
        vm.prank(agent);
        vm.expectRevert(AgentAllowanceVault.NotOwner.selector);
        vault.setPayee(agent, stranger, true);
        vm.prank(agent);
        vm.expectRevert(AgentAllowanceVault.NotOwner.selector);
        vault.revokeAgent(agent2);
    }

    function test_revert_setPolicyZeroAgent() public {
        vm.prank(owner);
        vm.expectRevert(AgentAllowanceVault.ZeroAddress.selector);
        vault.setPolicy(address(0), PER_PAYMENT, PER_DAY, T0 + 1 days, false, new address[](0));
    }

    function test_revert_setPolicyZeroPerPayment() public {
        vm.prank(owner);
        vm.expectRevert(AgentAllowanceVault.InvalidPolicy.selector);
        vault.setPolicy(agent, 0, PER_DAY, T0 + 1 days, false, new address[](0));
    }

    function test_revert_setPolicyDayBelowPerPayment() public {
        vm.prank(owner);
        vm.expectRevert(AgentAllowanceVault.InvalidPolicy.selector);
        vault.setPolicy(agent, PER_PAYMENT, PER_PAYMENT - 1, T0 + 1 days, false, new address[](0));
    }

    function test_revert_setPolicyCapTooLarge() public {
        vm.prank(owner);
        vm.expectRevert(AgentAllowanceVault.InvalidPolicy.selector);
        vault.setPolicy(agent, PER_PAYMENT, uint256(type(uint128).max) + 1, T0 + 1 days, false, new address[](0));
    }

    function test_revert_setPolicyPayeesWithoutRestriction() public {
        address[] memory list = new address[](1);
        list[0] = payee;
        vm.prank(owner);
        vm.expectRevert(AgentAllowanceVault.InvalidPolicy.selector);
        vault.setPolicy(agent, PER_PAYMENT, PER_DAY, T0 + 1 days, false, list);
    }

    function test_revert_setPolicyExpiryNowOrPast() public {
        vm.startPrank(owner);
        vm.expectRevert(AgentAllowanceVault.ExpiryNotInFuture.selector);
        vault.setPolicy(agent, PER_PAYMENT, PER_DAY, T0, false, new address[](0));
        vm.expectRevert(AgentAllowanceVault.ExpiryNotInFuture.selector);
        vault.setPolicy(agent, PER_PAYMENT, PER_DAY, T0 - 1, false, new address[](0));
        vm.expectRevert(AgentAllowanceVault.ExpiryNotInFuture.selector);
        vault.setPolicy(agent, PER_PAYMENT, PER_DAY, uint256(type(uint64).max) + 1, false, new address[](0));
        vm.stopPrank();
    }

    function test_revert_setPolicyZeroOrVaultPayee() public {
        address[] memory list = new address[](1);
        list[0] = address(0);
        vm.startPrank(owner);
        vm.expectRevert(AgentAllowanceVault.InvalidPayee.selector);
        vault.setPolicy(agent, PER_PAYMENT, PER_DAY, T0 + 1 days, true, list);
        list[0] = address(vault);
        vm.expectRevert(AgentAllowanceVault.InvalidPayee.selector);
        vault.setPolicy(agent, PER_PAYMENT, PER_DAY, T0 + 1 days, true, list);
        vm.stopPrank();
    }

    function test_setPayeeAddsAndRemoves() public {
        _restricted(agent, payee);
        vm.expectEmit(true, true, true, true, address(vault));
        emit AgentAllowanceVault.PayeeSet(agent, payee2, true, 1);
        vm.prank(owner);
        vault.setPayee(agent, payee2, true);
        assertTrue(vault.isPayeeAllowed(agent, payee2));

        vm.prank(owner);
        vault.setPayee(agent, payee, false);
        assertFalse(vault.isPayeeAllowed(agent, payee));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentAllowanceVault.PayeeNotAllowed.selector, payee));
        vault.pay(payee, USDC1, bytes32(0));
        vm.prank(agent);
        vault.pay(payee2, USDC1, bytes32(0));
        assertEq(usdc.balanceOf(payee2), USDC1);
    }

    function test_revert_setPayeeNotOwner() public {
        _restricted(agent, payee);
        vm.prank(stranger);
        vm.expectRevert(AgentAllowanceVault.NotOwner.selector);
        vault.setPayee(agent, stranger, true);
    }

    function test_revert_setPayeeOnAPolicyThatAllowsAnyPayee() public {
        _defaultPolicy(); // open policy: a payee list would have no effect, so the vault says so
        vm.startPrank(owner);
        vm.expectRevert(AgentAllowanceVault.InvalidPolicy.selector);
        vault.setPayee(agent, payee, true);
        vm.expectRevert(AgentAllowanceVault.InvalidPolicy.selector);
        vault.setPayee(agent, payee, false);
        vm.stopPrank();
        _pay(USDC1); // and the agent can still pay anyone, as the policy says
    }

    function test_revert_setPayeeWithoutPolicy() public {
        vm.prank(owner);
        vm.expectRevert(AgentAllowanceVault.NoPolicy.selector);
        vault.setPayee(agent, payee, true);
    }

    function test_revert_setPayeeZeroOrVault() public {
        _restricted(agent, payee);
        vm.startPrank(owner);
        vm.expectRevert(AgentAllowanceVault.InvalidPayee.selector);
        vault.setPayee(agent, address(0), true);
        vm.expectRevert(AgentAllowanceVault.InvalidPayee.selector);
        vault.setPayee(agent, address(vault), true);
        vm.stopPrank();
    }

    function test_revokeStopsTheAgent() public {
        _defaultPolicy();
        _pay(USDC1);
        vm.expectEmit(true, true, true, true, address(vault));
        emit AgentAllowanceVault.AgentRevoked(agent);
        vm.prank(owner);
        vault.revokeAgent(agent);

        AgentAllowanceVault.Policy memory p = vault.policyOf(agent);
        assertFalse(p.active);
        assertEq(p.maxPerPayment, 0);
        assertEq(p.maxPerDay, 0);
        assertEq(p.expiry, 0);
        assertEq(vault.availableToPay(agent), 0);
        assertFalse(vault.isPayeeAllowed(agent, payee));

        vm.prank(agent);
        vm.expectRevert(AgentAllowanceVault.NoPolicy.selector);
        vault.pay(payee, USDC1, bytes32(0));
    }

    function test_revokeIsIdempotentAndSafeForUnknownAgents() public {
        vm.startPrank(owner);
        vault.revokeAgent(agent); // never had a policy
        vm.stopPrank();
        _defaultPolicy();
        vm.startPrank(owner);
        vault.revokeAgent(agent);
        vault.revokeAgent(agent);
        vm.stopPrank();
        assertFalse(vault.policyOf(agent).active);
    }

    function test_revert_revokeNotOwner() public {
        _defaultPolicy();
        vm.prank(stranger);
        vm.expectRevert(AgentAllowanceVault.NotOwner.selector);
        vault.revokeAgent(agent);
    }

    function test_revokeThenNewPolicyDoesNotReviveOldPayees() public {
        _restricted(agent, payee);
        vm.prank(owner);
        vault.revokeAgent(agent);
        _restricted(agent, payee2);
        assertFalse(vault.isPayeeAllowed(agent, payee));
        assertTrue(vault.isPayeeAllowed(agent, payee2));
    }

    function test_revokeThenNewPolicyKeepsSpendingHistory() public {
        _defaultPolicy();
        _pay(10 * USDC1);
        _pay(10 * USDC1);
        vm.prank(owner);
        vault.revokeAgent(agent);
        _defaultPolicy();
        assertEq(vault.spentInWindow(agent), 20 * USDC1);
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(AgentAllowanceVault.ExceedsDailyCap.selector, 10 * USDC1, 5 * USDC1)
        );
        vault.pay(payee, 10 * USDC1, bytes32(0));
    }

    function test_policiesAreIndependentPerAgent() public {
        _open(agent, PER_PAYMENT, PER_DAY, T0 + 1 days);
        _open(agent2, 2 * USDC1, 2 * USDC1, T0 + 1 days);
        _pay(10 * USDC1);
        vm.prank(agent2);
        vault.pay(payee, 2 * USDC1, bytes32(0));
        assertEq(vault.spentInWindow(agent), 10 * USDC1);
        assertEq(vault.spentInWindow(agent2), 2 * USDC1);
        assertEq(vault.totalPaidBy(agent2), 2 * USDC1);
    }
}

contract PayTest is VaultFixture {
    function test_payMovesFundsCountsAndEmits() public {
        _defaultPolicy();
        bytes32 memo = keccak256("invoice-001");
        vm.expectEmit(true, true, true, true, address(vault));
        emit AgentAllowanceVault.Payment(agent, payee, memo, 1, 4 * USDC1, 4 * USDC1);
        vm.prank(agent);
        uint256 id = vault.pay(payee, 4 * USDC1, memo);

        assertEq(id, 1);
        assertEq(vault.paymentCount(), 1);
        assertEq(usdc.balanceOf(payee), 4 * USDC1);
        assertEq(vault.vaultBalance(), 996 * USDC1);
        assertEq(vault.totalPaidBy(agent), 4 * USDC1);
        assertEq(vault.spentInWindow(agent), 4 * USDC1);
        assertEq(vault.availableToPay(agent), PER_PAYMENT);

        vm.prank(agent);
        id = vault.pay(payee2, 6 * USDC1, bytes32(uint256(2)));
        assertEq(id, 2);
        assertEq(vault.spentInWindow(agent), 10 * USDC1);
    }

    function test_payExactlyAtBothCaps() public {
        _open(agent, 10 * USDC1, 20 * USDC1, T0 + 1 days);
        _pay(10 * USDC1);
        _pay(10 * USDC1);
        assertEq(vault.availableToPay(agent), 0);
        assertEq(usdc.balanceOf(payee), 20 * USDC1);
    }

    function test_revert_strangerHasNoPolicy() public {
        vm.prank(stranger);
        vm.expectRevert(AgentAllowanceVault.NoPolicy.selector);
        vault.pay(stranger, USDC1, bytes32(0));
    }

    function test_revert_ownerCannotPayWithoutAPolicy() public {
        vm.prank(owner);
        vm.expectRevert(AgentAllowanceVault.NoPolicy.selector);
        vault.pay(payee, USDC1, bytes32(0));
    }

    function test_revert_expired() public {
        _open(agent, PER_PAYMENT, PER_DAY, T0 + 1 hours);
        vm.warp(T0 + 1 hours - 1);
        _pay(USDC1); // last valid second
        vm.warp(T0 + 1 hours);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentAllowanceVault.PolicyExpired.selector, T0 + 1 hours));
        vault.pay(payee, USDC1, bytes32(0));
        vm.warp(T0 + 30 days);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentAllowanceVault.PolicyExpired.selector, T0 + 1 hours));
        vault.pay(payee, USDC1, bytes32(0));
        assertEq(vault.availableToPay(agent), 0);
    }

    function test_revert_zeroAmount() public {
        _defaultPolicy();
        vm.prank(agent);
        vm.expectRevert(AgentAllowanceVault.ZeroAmount.selector);
        vault.pay(payee, 0, bytes32(0));
    }

    function test_revert_payeeZeroOrVault() public {
        _defaultPolicy();
        vm.startPrank(agent);
        vm.expectRevert(AgentAllowanceVault.InvalidPayee.selector);
        vault.pay(address(0), USDC1, bytes32(0));
        vm.expectRevert(AgentAllowanceVault.InvalidPayee.selector);
        vault.pay(address(vault), USDC1, bytes32(0));
        vm.stopPrank();
    }

    function test_revert_overPerPaymentCap() public {
        _defaultPolicy();
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(AgentAllowanceVault.ExceedsPerPaymentCap.selector, PER_PAYMENT + 1, PER_PAYMENT)
        );
        vault.pay(payee, PER_PAYMENT + 1, bytes32(0));
    }

    function test_revert_payeeNotOnTheList() public {
        _restricted(agent, payee);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentAllowanceVault.PayeeNotAllowed.selector, payee2));
        vault.pay(payee2, USDC1, bytes32(0));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentAllowanceVault.PayeeNotAllowed.selector, agent));
        vault.pay(agent, USDC1, bytes32(0)); // not even itself
        _pay(USDC1); // the listed payee works
    }

    function test_restrictedWithEmptyListCanPayNobody() public {
        vm.prank(owner);
        vault.setPolicy(agent, PER_PAYMENT, PER_DAY, T0 + 1 days, true, new address[](0));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentAllowanceVault.PayeeNotAllowed.selector, payee));
        vault.pay(payee, USDC1, bytes32(0));
    }

    function test_revert_overDailyCap() public {
        _defaultPolicy(); // 10 per payment, 25 per day
        _pay(10 * USDC1);
        _pay(10 * USDC1);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentAllowanceVault.ExceedsDailyCap.selector, 6 * USDC1, 5 * USDC1));
        vault.pay(payee, 6 * USDC1, bytes32(0));
        _pay(5 * USDC1);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentAllowanceVault.ExceedsDailyCap.selector, 1, 0));
        vault.pay(payee, 1, bytes32(0));
        assertEq(usdc.balanceOf(payee), 25 * USDC1);
    }

    function test_dailyCapCountsPaymentsInTheSameSecond() public {
        // Arc blocks can share a timestamp; nothing may slip through between them.
        _defaultPolicy();
        _pay(10 * USDC1);
        vm.roll(block.number + 1);
        _pay(10 * USDC1);
        vm.roll(block.number + 1);
        _pay(5 * USDC1);
        vm.roll(block.number + 1);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentAllowanceVault.ExceedsDailyCap.selector, 1, 0));
        vault.pay(payee, 1, bytes32(0));
    }

    function test_dailyCapStillBindsJustUnder24HoursLater() public {
        _defaultPolicy();
        _pay(10 * USDC1);
        _pay(10 * USDC1);
        _pay(5 * USDC1);
        vm.warp(T0 + 24 hours - 1);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentAllowanceVault.ExceedsDailyCap.selector, 1, 0));
        vault.pay(payee, 1, bytes32(0));
    }

    function test_dailyCapFreesUpWithin25Hours() public {
        _defaultPolicy();
        _pay(10 * USDC1);
        _pay(10 * USDC1);
        _pay(5 * USDC1);
        vm.warp(T0 + 25 hours);
        assertEq(vault.spentInWindow(agent), 0);
        _pay(10 * USDC1);
    }

    function test_dailyCapRollsOffPaymentByPayment() public {
        _defaultPolicy();
        _pay(10 * USDC1); // at T0
        vm.warp(T0 + 6 hours);
        _pay(10 * USDC1);
        vm.warp(T0 + 12 hours);
        _pay(5 * USDC1); // cap reached
        vm.warp(T0 + 25 hours); // only the first payment has left the window
        assertEq(vault.spentInWindow(agent), 15 * USDC1);
        _pay(10 * USDC1);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentAllowanceVault.ExceedsDailyCap.selector, 1, 0));
        vault.pay(payee, 1, bytes32(0));
    }

    function test_loweringTheCapBelowSpendingBlocksFurtherPayments() public {
        _defaultPolicy();
        _pay(10 * USDC1);
        _open(agent, 5 * USDC1, 5 * USDC1, T0 + 1 days);
        assertEq(vault.availableToPay(agent), 0);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentAllowanceVault.ExceedsDailyCap.selector, USDC1, 0));
        vault.pay(payee, USDC1, bytes32(0));
    }

    function test_revert_vaultTooPoor() public {
        _defaultPolicy();
        vm.prank(owner);
        vault.withdraw(owner, 997 * USDC1);
        assertEq(vault.availableToPay(agent), 3 * USDC1);
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(AgentAllowanceVault.InsufficientVaultBalance.selector, 4 * USDC1, 3 * USDC1)
        );
        vault.pay(payee, 4 * USDC1, bytes32(0));
        _pay(3 * USDC1);
        assertEq(vault.vaultBalance(), 0);
    }

    function test_blocklistedPayeeRevertsAndLeavesNoTrace() public {
        _defaultPolicy();
        usdc.setBlocklisted(payee, true);
        vm.prank(agent);
        vm.expectRevert(bytes("Blocklisted address"));
        vault.pay(payee, USDC1, bytes32(0));
        assertEq(vault.paymentCount(), 0);
        assertEq(vault.spentInWindow(agent), 0);
        assertEq(vault.totalPaidBy(agent), 0);
        assertEq(vault.vaultBalance(), 1_000 * USDC1);
    }

    function test_failedPaymentDoesNotUseAllowance() public {
        _defaultPolicy();
        vm.prank(agent);
        vm.expectRevert();
        vault.pay(payee, PER_PAYMENT + 1, bytes32(0));
        assertEq(vault.spentInWindow(agent), 0);
        assertEq(vault.availableToPay(agent), PER_PAYMENT);
    }

    function test_availableToPayTracksEveryLimit() public {
        assertEq(vault.availableToPay(agent), 0, "no policy");
        _defaultPolicy();
        assertEq(vault.availableToPay(agent), 10 * USDC1, "per-payment cap");
        _pay(10 * USDC1);
        _pay(10 * USDC1);
        assertEq(vault.availableToPay(agent), 5 * USDC1, "rest of the day");
        vm.prank(owner);
        vault.withdraw(owner, 978 * USDC1);
        assertEq(vault.availableToPay(agent), 2 * USDC1, "vault balance");
    }
}

contract ReentrancyTest is Test {
    uint256 internal constant USDC1 = 1e6;
    address internal owner = makeAddr("owner");
    address internal payee = makeAddr("payee");
    ReentrantToken internal token;
    AgentAllowanceVault internal vault;

    function setUp() public {
        vm.warp(1_790_000_000);
        token = new ReentrantToken();
        vault = new AgentAllowanceVault(address(token), owner);
        token.mint(address(vault), 100 * USDC1);
        // The hostile token is itself given a policy, so only the lock can stop it.
        vm.prank(owner);
        vault.setPolicy(address(token), 10 * USDC1, 100 * USDC1, block.timestamp + 1 days, false, new address[](0));
    }

    function test_revert_reenterPayDuringPay() public {
        token.arm(address(vault), abi.encodeCall(AgentAllowanceVault.pay, (payee, 10 * USDC1, bytes32(0))));
        vm.prank(address(token));
        vm.expectRevert(AgentAllowanceVault.Reentrancy.selector);
        vault.pay(payee, 10 * USDC1, bytes32(0));
        assertEq(vault.paymentCount(), 0);
        assertEq(token.balanceOf(payee), 0);
    }

    function test_revert_reenterDepositDuringWithdraw() public {
        token.arm(address(vault), abi.encodeCall(AgentAllowanceVault.deposit, (1)));
        vm.prank(owner);
        vm.expectRevert(AgentAllowanceVault.Reentrancy.selector);
        vault.withdraw(owner, 10 * USDC1);
        assertEq(token.balanceOf(address(vault)), 100 * USDC1);
    }

    function test_revert_reenterPayDuringWithdrawAll() public {
        token.arm(address(vault), abi.encodeCall(AgentAllowanceVault.pay, (payee, 10 * USDC1, bytes32(0))));
        vm.prank(owner);
        vm.expectRevert(AgentAllowanceVault.Reentrancy.selector);
        vault.withdrawAll(owner);
        assertEq(token.balanceOf(payee), 0);
    }

    function test_lockReleasesAfterANormalCall() public {
        vm.startPrank(address(token));
        vault.pay(payee, 10 * USDC1, bytes32(0));
        vault.pay(payee, 10 * USDC1, bytes32(0));
        vm.stopPrank();
        assertEq(token.balanceOf(payee), 20 * USDC1);
    }
}
