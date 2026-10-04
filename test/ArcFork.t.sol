// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AgentAllowanceVault, IUSDC} from "../src/AgentAllowanceVault.sol";

interface IUSDCFull is IUSDC {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Arc's predeployed Memo contract: wraps a call and keeps the original
/// account as msg.sender (https://docs.arc.io/arc/concepts/transaction-memos).
interface IArcMemo {
    function memo(address target, bytes calldata data, bytes32 memoId, bytes calldata memoData) external;
}

/// @notice A payee contract with no way to receive native value.
contract PayeeWithoutReceive {}

/// @notice A payee contract that tries to run code, and to re-enter the vault, when it is paid.
contract PayeeThatReenters {
    AgentAllowanceVault internal immutable vault;
    uint256 public calls;

    constructor(AgentAllowanceVault vault_) {
        vault = vault_;
    }

    receive() external payable {
        ++calls;
        vault.pay(address(this), 1, bytes32(0));
    }

    fallback() external payable {
        ++calls;
    }
}

/// @notice Runs the vault against the real USDC of Arc, on a fork of Arc Testnet
/// or Arc Mainnet. Needs Arc Foundry, because a plain EVM cannot reproduce Arc's
/// native USDC:
///
///   arc-forge test --match-contract ArcForkTest --fork-url https://rpc.testnet.arc.io -vv
///
/// Without a fork of Arc these tests skip themselves.
contract ArcForkTest is Test {
    address internal constant ARC_USDC = 0x3600000000000000000000000000000000000000;
    uint256 internal constant USDC1 = 1e6;

    IUSDCFull internal usdc = IUSDCFull(ARC_USDC);
    AgentAllowanceVault internal vault;
    address internal owner = makeAddr("fork owner");
    address internal agent = makeAddr("fork agent");
    address internal payee = makeAddr("fork payee");
    bool internal onArc;

    function setUp() public {
        onArc = block.chainid == 5042 || block.chainid == 5042002;
        if (!onArc) return;
        vault = new AgentAllowanceVault(ARC_USDC, owner);
        // On Arc the native balance IS the USDC balance: 100 native units (18 decimals) = 100 USDC.
        vm.deal(owner, 100 ether);
        vm.deal(agent, 1 ether);
    }

    function test_fork_nativeBalanceIsTheUsdcBalance() public {
        vm.skip(!onArc);
        assertEq(usdc.decimals(), 6);
        assertEq(usdc.balanceOf(owner), 100 * USDC1, "18-decimal native balance seen through the 6-decimal interface");
    }

    function test_fork_fundPayAndWithdrawWithRealUsdc() public {
        vm.skip(!onArc);
        // fund: once with approve + deposit, once with a plain ERC-20 transfer
        vm.startPrank(owner);
        usdc.approve(address(vault), 30 * USDC1);
        vault.deposit(30 * USDC1);
        assertTrue(usdc.transfer(address(vault), 20 * USDC1));
        address[] memory list = new address[](1);
        list[0] = payee;
        vault.setPolicy(agent, 5 * USDC1, 8 * USDC1, block.timestamp + 1 days, true, list);
        vm.stopPrank();
        assertEq(vault.vaultBalance(), 50 * USDC1);
        assertEq(address(vault).balance, 50 ether, "the vault's USDC is its native balance");

        vm.startPrank(agent);
        vault.pay(payee, 5 * USDC1, keccak256("invoice-001"));
        assertEq(usdc.balanceOf(payee), 5 * USDC1);
        assertEq(payee.balance, 5 ether);

        vm.expectRevert(abi.encodeWithSelector(AgentAllowanceVault.ExceedsPerPaymentCap.selector, 6 * USDC1, 5 * USDC1));
        vault.pay(payee, 6 * USDC1, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(AgentAllowanceVault.ExceedsDailyCap.selector, 4 * USDC1, 3 * USDC1));
        vault.pay(payee, 4 * USDC1, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(AgentAllowanceVault.PayeeNotAllowed.selector, agent));
        vault.pay(agent, 1 * USDC1, bytes32(0));
        vm.expectRevert(AgentAllowanceVault.NotOwner.selector);
        vault.withdrawAll(agent);
        vm.stopPrank();

        vm.startPrank(owner);
        vault.pause();
        vault.withdrawAll(owner);
        vm.stopPrank();
        assertEq(vault.vaultBalance(), 0);
        assertEq(usdc.balanceOf(owner), 95 * USDC1);
    }

    /// @notice An agent can attach a native Arc memo to a vault payment: Arc's Memo
    /// contract forwards the call with the agent still as msg.sender, so the policy applies.
    function test_fork_payThroughArcMemoContractKeepsTheAgentAsSender() public {
        vm.skip(!onArc);
        IArcMemo arcMemo = IArcMemo(0x5294E9927c3306DcBaDb03fe70b92e01cCede505);
        vm.startPrank(owner);
        assertTrue(usdc.transfer(address(vault), 20 * USDC1));
        vault.setPolicy(agent, 5 * USDC1, 8 * USDC1, block.timestamp + 1 days, false, new address[](0));
        vm.stopPrank();

        bytes memory payCall = abi.encodeCall(AgentAllowanceVault.pay, (payee, 2 * USDC1, keccak256("invoice-007")));
        vm.prank(agent, agent); // an EOA calling Memo directly
        arcMemo.memo(address(vault), payCall, bytes32("invoice-007"), bytes("order 7, 2 USDC"));
        assertEq(usdc.balanceOf(payee), 2 * USDC1);
        assertEq(vault.totalPaidBy(agent), 2 * USDC1, "the vault saw the agent, not the Memo contract");

        // The policy still binds through the wrapper.
        bytes memory tooBig = abi.encodeCall(AgentAllowanceVault.pay, (payee, 6 * USDC1, bytes32(0)));
        vm.prank(agent, agent);
        vm.expectRevert();
        arcMemo.memo(address(vault), tooBig, bytes32("too big"), bytes(""));

        // And a stranger gains nothing by going through it.
        vm.prank(payee, payee);
        vm.expectRevert();
        arcMemo.memo(address(vault), payCall, bytes32("stranger"), bytes(""));
        assertEq(usdc.balanceOf(payee), 2 * USDC1);
    }

    /// @notice On Arc a contract's USDC is its native balance. Paying a contract through the
    /// ERC-20 interface must still work when it cannot receive native sends, and must not
    /// hand control to the payee in the middle of a payment.
    function test_fork_contractPayeesGetPaidWithoutRunningCode() public {
        vm.skip(!onArc);
        PayeeWithoutReceive plain = new PayeeWithoutReceive();
        PayeeThatReenters hostile = new PayeeThatReenters(vault);
        vm.startPrank(owner);
        assertTrue(usdc.transfer(address(vault), 20 * USDC1));
        vault.setPolicy(agent, 5 * USDC1, 8 * USDC1, block.timestamp + 1 days, false, new address[](0));
        // Even with a policy of its own, the hostile payee gets no chance to use it mid-payment.
        vault.setPolicy(address(hostile), 5 * USDC1, 8 * USDC1, block.timestamp + 1 days, false, new address[](0));
        vm.stopPrank();

        vm.startPrank(agent);
        vault.pay(address(plain), 2 * USDC1, bytes32(0));
        vault.pay(address(hostile), 3 * USDC1, bytes32(0));
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(plain)), 2 * USDC1);
        assertEq(usdc.balanceOf(address(hostile)), 3 * USDC1);
        assertEq(hostile.calls(), 0, "the payee's code ran during the payment");
        assertEq(vault.paymentCount(), 2);
        assertEq(vault.totalPaidBy(address(hostile)), 0);
    }

    function test_fork_vaultRefusesNativeSends() public {
        vm.skip(!onArc);
        vm.prank(owner);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertFalse(ok, "a native USDC send to the vault must revert");
        assertEq(vault.vaultBalance(), 0);
    }

    function test_fork_payingTheZeroAddressIsImpossible() public {
        vm.skip(!onArc);
        vm.prank(owner);
        vault.setPolicy(agent, 5 * USDC1, 8 * USDC1, block.timestamp + 1 days, false, new address[](0));
        vm.prank(agent);
        vm.expectRevert(AgentAllowanceVault.InvalidPayee.selector);
        vault.pay(address(0), 1 * USDC1, bytes32(0));
    }
}
