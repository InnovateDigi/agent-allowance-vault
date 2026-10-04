// Agent Allowance Vault: a tiny client for an AI agent. One file, one dependency (viem).
//
//   import { createVaultClient } from "./vault-client.mjs";
//   const vault = createVaultClient({ network: "arc-mainnet", vault: "0x...", privateKey: process.env.AGENT_KEY });
//   console.log(await vault.status());
//   const receipt = await vault.pay({ to: "0x...", amount: "1.25", memo: "invoice 2026-104" });
//   // optional: publish a memo through Arc's own Memo contract as well: add arcMemo: "order 104"
//
// The agent key only ever needs a little USDC for gas. The money stays in the vault.
import {
  createPublicClient, createWalletClient, defineChain, http, parseAbi, parseUnits, formatUnits, parseGwei,
  keccak256, toHex, isHex, getAddress, decodeEventLog, encodeFunctionData, BaseError, ContractFunctionRevertedError,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

export const NETWORKS = {
  "arc-mainnet": { chainId: 5042, name: "Arc", rpc: "https://rpc.mainnet.arc.io", explorer: "https://explorer.arc.io" },
  "arc-testnet": { chainId: 5042002, name: "Arc Testnet", rpc: "https://rpc.testnet.arc.io", explorer: "https://explorer.testnet.arc.io" },
};

export const VAULT_ABI = parseAbi([
  "struct Policy { uint128 maxPerPayment; uint128 maxPerDay; uint64 expiry; uint32 payeeEpoch; bool restrictPayees; bool active; }",
  "function owner() view returns (address)",
  "function usdc() view returns (address)",
  "function paused() view returns (bool)",
  "function paymentCount() view returns (uint256)",
  "function totalPaidBy(address agent) view returns (uint256)",
  "function policyOf(address agent) view returns (Policy)",
  "function isPayeeAllowed(address agent, address payee) view returns (bool)",
  "function spentInWindow(address agent) view returns (uint256)",
  "function availableToPay(address agent) view returns (uint256)",
  "function vaultBalance() view returns (uint256)",
  "function pay(address payee, uint256 amount, bytes32 memoHash) returns (uint256 id)",
  "function deposit(uint256 amount)",
  "function withdraw(address to, uint256 amount)",
  "function withdrawAll(address to)",
  "function pause()",
  "function unpause()",
  "function setPolicy(address agent, uint256 maxPerPayment, uint256 maxPerDay, uint256 expiry, bool restrictPayees, address[] payees)",
  "function setPayee(address agent, address payee, bool allowed)",
  "function revokeAgent(address agent)",
  "event Payment(address indexed agent, address indexed payee, bytes32 indexed memoHash, uint256 id, uint256 amount, uint256 spentInWindow)",
  "event Deposited(address indexed from, uint256 amount)",
  "event Withdrawn(address indexed to, uint256 amount)",
  "event PolicySet(address indexed agent, uint256 maxPerPayment, uint256 maxPerDay, uint256 expiry, bool restrictPayees, uint32 payeeEpoch)",
  "event PayeeSet(address indexed agent, address indexed payee, bool allowed, uint32 payeeEpoch)",
  "event AgentRevoked(address indexed agent)",
  "event Paused()",
  "event Unpaused()",
  "error NotOwner()",
  "error ZeroAddress()",
  "error ZeroAmount()",
  "error NotUSDC()",
  "error Reentrancy()",
  "error TransferFailed()",
  "error InvalidPolicy()",
  "error ExpiryNotInFuture()",
  "error VaultPaused()",
  "error NoPolicy()",
  "error PolicyExpired(uint256 expiry)",
  "error InvalidPayee()",
  "error PayeeNotAllowed(address payee)",
  "error ExceedsPerPaymentCap(uint256 amount, uint256 maxPerPayment)",
  "error ExceedsDailyCap(uint256 amount, uint256 remaining)",
  "error InsufficientVaultBalance(uint256 amount, uint256 balance)",
]);

/**
 * Arc's predeployed Memo contract (same address on mainnet and testnet). It forwards a call and
 * keeps the calling account as msg.sender, so a payment sent through it is still the agent's
 * payment under the agent's policy, with a memo published in Arc's own Memo event.
 * https://docs.arc.io/arc/concepts/transaction-memos
 */
export const ARC_MEMO = "0x5294E9927c3306DcBaDb03fe70b92e01cCede505";
const ARC_MEMO_ABI = parseAbi(["function memo(address target, bytes data, bytes32 memoId, bytes memoData)"]);

/** USDC amounts: a decimal string such as "1.25" (USDC) or a bigint in base units (6 decimals). */
export const toUnits = (amount) => (typeof amount === "bigint" ? amount : parseUnits(String(amount), 6));
export const fromUnits = (units) => formatUnits(units, 6);

/** The 32-byte memo commitment: keccak256 of the text, or a 32-byte hex value used as is. */
export const memoHash = (memo = "") =>
  isHex(memo) && memo.length === 66 ? memo : keccak256(toHex(String(memo)));

/** Why a call would revert, as { reason, args }, taken from the vault's custom errors. */
export function explainRevert(error) {
  if (error instanceof BaseError) {
    const reverted = error.walk((e) => e instanceof ContractFunctionRevertedError);
    if (reverted instanceof ContractFunctionRevertedError) {
      const name = reverted.data?.errorName ?? reverted.reason ?? "Reverted";
      return { reason: name, args: (reverted.data?.args ?? []).map((a) => (typeof a === "bigint" ? a.toString() : a)) };
    }
    return { reason: error.shortMessage, args: [] };
  }
  return { reason: String(error?.message ?? error), args: [] };
}

/** Arc silently drops transactions priced under 20 gwei, so stay well above the floor. */
export async function arcFees(publicClient) {
  const gasPrice = await publicClient.getGasPrice();
  const floor = parseGwei("40");
  return { maxFeePerGas: gasPrice * 2n > floor ? gasPrice * 2n : floor, maxPriorityFeePerGas: parseGwei("1") };
}

/**
 * @param {object} o
 * @param {string} o.vault        address of the deployed AgentAllowanceVault
 * @param {string|object} [o.network="arc-mainnet"]  "arc-mainnet", "arc-testnet" or { chainId, rpc, name? }
 * @param {string} [o.privateKey] the agent's key (omit for a read-only client)
 * @param {object} [o.account]    a viem account, instead of privateKey
 * @param {string} [o.agent]      agent address for a read-only client
 * @param {string} [o.rpcUrl]     override the RPC URL
 */
export function createVaultClient({ vault, network = "arc-mainnet", privateKey, account, agent, rpcUrl }) {
  const net = typeof network === "string" ? NETWORKS[network] : network;
  if (!net) throw new Error(`unknown network: ${network}`);
  const chain = defineChain({
    id: net.chainId,
    name: net.name ?? `chain ${net.chainId}`,
    nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl ?? net.rpc] } },
  });
  const transport = http(rpcUrl ?? net.rpc, { retryCount: 5, retryDelay: 400 });
  const publicClient = createPublicClient({ chain, transport });
  const signer = account ?? (privateKey ? privateKeyToAccount(privateKey) : null);
  const walletClient = signer ? createWalletClient({ account: signer, chain, transport }) : null;
  const address = getAddress(vault);
  const self = signer ? signer.address : agent ? getAddress(agent) : null;
  const read = (functionName, args = []) => publicClient.readContract({ address, abi: VAULT_ABI, functionName, args });

  return {
    address: self,
    vault: address,
    publicClient,

    /** Everything an agent should know before it spends. Amounts are USDC strings. */
    async status(who = self) {
      const [paused, policy, spent, available, balance, total, gas] = await Promise.all([
        read("paused"), read("policyOf", [who]), read("spentInWindow", [who]), read("availableToPay", [who]),
        read("vaultBalance"), read("totalPaidBy", [who]), publicClient.getBalance({ address: who }),
      ]);
      return {
        agent: who,
        paused,
        active: policy.active,
        maxPerPayment: fromUnits(policy.maxPerPayment),
        maxPerDay: fromUnits(policy.maxPerDay),
        expiry: new Date(Number(policy.expiry) * 1000).toISOString(),
        restrictPayees: policy.restrictPayees,
        spentInWindow: fromUnits(spent),
        availableToPay: fromUnits(available),
        vaultBalance: fromUnits(balance),
        totalPaid: fromUnits(total),
        gasBalance: formatUnits(gas, 18),
      };
    },

    /** Ask the chain whether a payment would go through, without sending anything. */
    async check({ to, amount, memo = "" }) {
      try {
        await publicClient.simulateContract({
          account: self, address, abi: VAULT_ABI, functionName: "pay", args: [getAddress(to), toUnits(amount), memoHash(memo)],
        });
        return { ok: true };
      } catch (error) {
        return { ok: false, ...explainRevert(error) };
      }
    },

    /**
     * Pay USDC from the vault under this agent's policy.
     * Refuses locally, without spending gas, if the chain says the payment would revert.
     *
     * memo:    hashed (keccak256) into the vault's Payment event; the text itself stays private.
     * arcMemo: optional text to PUBLISH on chain through Arc's Memo contract, whose Memo event
     *          then carries this text and, as memoId, the same hash as the Payment event.
     *          The agent key must be a plain account (Arc's Memo contract accepts no contract wallets).
     */
    async pay({ to, amount, memo = "", arcMemo, nonce }) {
      if (!walletClient) throw new Error("read-only client: no key given");
      const args = [getAddress(to), toUnits(amount), memoHash(memo)];
      const verdict = await this.check({ to, amount, memo });
      if (!verdict.ok) {
        const error = new Error(`payment refused by the vault: ${verdict.reason}(${verdict.args.join(", ")})`);
        error.reason = verdict.reason;
        error.args = verdict.args;
        throw error;
      }
      const extra = { ...(await arcFees(publicClient)), ...(nonce === undefined ? {} : { nonce }) };
      const hash = arcMemo === undefined
        ? await walletClient.writeContract({ address, abi: VAULT_ABI, functionName: "pay", args, ...extra })
        : await walletClient.writeContract({
            address: ARC_MEMO, abi: ARC_MEMO_ABI, functionName: "memo",
            args: [address, encodeFunctionData({ abi: VAULT_ABI, functionName: "pay", args }), args[2], toHex(String(arcMemo))],
            ...extra,
          });
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      if (receipt.status !== "success") throw new Error(`payment transaction reverted: ${hash}`);
      let id = null;
      for (const log of receipt.logs) {
        if (log.address.toLowerCase() !== address.toLowerCase()) continue;
        try {
          const event = decodeEventLog({ abi: VAULT_ABI, data: log.data, topics: log.topics });
          if (event.eventName === "Payment") id = event.args.id;
        } catch { /* not a vault event */ }
      }
      return {
        hash,
        id: id?.toString() ?? null,
        payee: args[0],
        amount: fromUnits(args[1]),
        memoHash: args[2],
        arcMemo: arcMemo === undefined ? null : receipt.logs.some((l) => l.address.toLowerCase() === ARC_MEMO.toLowerCase()),
        blockNumber: receipt.blockNumber.toString(),
        feeUsdc: formatUnits(receipt.gasUsed * receipt.effectiveGasPrice, 18),
        explorer: net.explorer ? `${net.explorer}/tx/${hash}` : null,
      };
    },

    /**
     * The audit trail: every Payment event of an agent between two blocks.
     * Arc's public RPC answers at most 10,000 blocks per eth_getLogs call, so this pages.
     */
    async payments({ agent: who = self, fromBlock, toBlock } = {}) {
      const latest = toBlock ?? (await publicClient.getBlockNumber());
      const out = [];
      const event = VAULT_ABI.find((x) => x.type === "event" && x.name === "Payment");
      for (let start = BigInt(fromBlock ?? 0n); start <= latest; start += 9_999n) {
        const end = start + 9_998n < latest ? start + 9_998n : latest;
        const logs = await publicClient.getLogs({ address, event, args: who ? { agent: who } : undefined, fromBlock: start, toBlock: end });
        for (const log of logs) {
          out.push({
            id: log.args.id.toString(), agent: log.args.agent, payee: log.args.payee, amount: fromUnits(log.args.amount),
            memoHash: log.args.memoHash, blockNumber: log.blockNumber.toString(), hash: log.transactionHash,
          });
        }
      }
      return out;
    },
  };
}
