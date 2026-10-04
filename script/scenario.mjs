// Runs the whole story against a deployed vault and writes the evidence as Markdown.
//
//   DEPLOYER_KEY_FILE=/path/outside/the/repo/deployer.json node script/scenario.mjs --network arc-testnet --out TESTNET.md
//
// The owner is the deployer key. The agent is a fresh key made for this run; the owner
// gives it a little USDC for gas and it sends the rest back at the end.
// Refused actions are first simulated (to read the reason) and then really sent with a
// fixed gas limit, so each refusal is also a reverted transaction anyone can look up.
//
// Options: --unit 1 (USDC; the per-payment cap; deposit is 5 units; default 1 on testnet, 0.1 on mainnet),
//          --gas-topup 0.1 (USDC sent to the agent for gas; the unused part is returned at the end),
//          --payee 0x... (default: a fresh address on testnet; the owner on mainnet, so the money comes back),
//          --fork (the RPC is a local arc-anvil fork: a rehearsal that jumps time instead of waiting).
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { encodeFunctionData, decodeErrorResult, parseAbi, parseUnits, getAddress } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { ROOT, USDC_ADDRESS, parseArgs, getNetwork, loadAccount, clients, fees, feeToUsdc, usdc, txLink, addrLink, sleep } from "./lib.mjs";
import { VAULT_ABI, createVaultClient, explainRevert, memoHash } from "../client/vault-client.mjs";

const ERC20 = parseAbi([
  "function approve(address spender, uint256 amount) returns (bool)",
  "function transfer(address to, uint256 amount) returns (bool)",
  "function balanceOf(address account) view returns (uint256)",
]);

const args = parseArgs();
const net = getNetwork(args);
if (net.key === "arc-mainnet" && !net.fork && !args["yes-mainnet"]) throw new Error("Refusing to run on Arc mainnet without --yes-mainnet.");
const deployment = JSON.parse(readFileSync(resolve(ROOT, `deployments/${net.recordKey}.json`), "utf8"));
const VAULT = getAddress(deployment.address);

const ownerAccount = loadAccount();
const agentAccount = privateKeyToAccount(generatePrivateKey()); // lives only in this process
const fresh = () => privateKeyToAccount(generatePrivateKey()).address;
const payeeA = getAddress(args.payee || (net.key === "arc-mainnet" ? ownerAccount.address : fresh()));
const payeeB = fresh(); // never on the list

const owner = clients(net, ownerAccount);
const agent = clients(net, agentAccount);
const pub = owner.publicClient;
const agentClient = createVaultClient({ vault: VAULT, network: { chainId: net.chainId, rpc: net.rpc, name: net.name }, account: agentAccount });

const UNIT = parseUnits(String(args.unit || (net.key === "arc-mainnet" ? "0.1" : "1")), 6);
const u = (x) => (UNIT * BigInt(Math.round(x * 100))) / 100n;
const GAS_TOPUP = parseUnits(String(args["gas-topup"] || "0.1"), 18); // what is not used goes back to the owner at the end

if ((await pub.getChainId()) !== net.chainId) throw new Error("RPC is on the wrong chain");
const vaultOwner = await pub.readContract({ address: VAULT, abi: VAULT_ABI, functionName: "owner" });
if (vaultOwner.toLowerCase() !== ownerAccount.address.toLowerCase()) throw new Error("The loaded key is not the owner of this vault.");

const nonces = new Map();
async function nextNonce(address) {
  if (!nonces.has(address)) nonces.set(address, await pub.getTransactionCount({ address, blockTag: "pending" }));
  const n = nonces.get(address);
  nonces.set(address, n + 1);
  return n;
}

// The public RPC is load-balanced and its backends can be a block or two apart, so give them a
// moment after each transaction and ask again before believing an answer that looks stale.
const settle = () => sleep(net.fork ? 0 : 1500);
async function retry(fn, attempts = net.fork ? 1 : 4) {
  for (let i = 1; ; i++) {
    try {
      return await fn();
    } catch (error) {
      if (i >= attempts) throw error;
      await sleep(1500 * i);
    }
  }
}

const rows = [];
let totalFee = 0n;
let totalGas = 0n;

/** Send a transaction that is expected to succeed. */
async function ok(who, label, tx, expect) {
  const c = who === "owner" ? owner : agent;
  const from = c.walletClient.account.address;
  const gas = tx.gas ?? ((await retry(() => pub.estimateGas({ account: from, ...tx }))) * 12n) / 10n;
  const hash = await c.walletClient.sendTransaction({ ...tx, gas, nonce: await nextNonce(from), ...(await fees(pub)) });
  const receipt = await pub.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`step "${label}" reverted unexpectedly: ${hash}`);
  await settle();
  record(who, label, expect, "ok", hash, receipt);
  return receipt;
}

/** Send a transaction that the vault must refuse; record the reason and the reverted transaction. */
async function refused(who, label, tx, expectedReason) {
  const c = who === "owner" ? owner : agent;
  const from = c.walletClient.account.address;
  const reason = await retry(async () => {
    let seen = "DID NOT REVERT";
    try {
      await pub.call({ account: from, ...tx });
    } catch (error) {
      seen = decodeReason(error);
    }
    if (seen !== expectedReason) throw new Error(`step "${label}": expected ${expectedReason}, got ${seen}`);
    return seen;
  });
  const hash = await c.walletClient.sendTransaction({ ...tx, gas: 300_000n, nonce: await nextNonce(from), ...(await fees(pub)) });
  const receipt = await pub.waitForTransactionReceipt({ hash });
  if (receipt.status !== "reverted") throw new Error(`step "${label}" should have reverted on chain: ${hash}`);
  await settle();
  record(who, label, `refused: ${expectedReason}`, `reverted: ${reason}`, hash, receipt);
}

function decodeReason(error) {
  // call() does not know the ABI: find the raw revert data and decode it against the vault's errors.
  let data;
  for (let e = error; e && !data; e = e.cause) {
    if (typeof e.data === "string" && e.data.startsWith("0x")) data = e.data;
    else if (e.data && typeof e.data.data === "string") data = e.data.data;
  }
  if (!data) return explainRevert(error).reason;
  try {
    return decodeErrorResult({ abi: VAULT_ABI, data }).errorName;
  } catch {
    return `unknown error ${data.slice(0, 10)}`;
  }
}

function record(who, label, expect, result, hash, receipt) {
  const fee = receipt.gasUsed * receipt.effectiveGasPrice;
  totalFee += fee;
  totalGas += receipt.gasUsed;
  rows.push({ n: rows.length + 1, who, label, expect, result, hash, gas: receipt.gasUsed, fee, block: receipt.blockNumber });
  console.log(`${String(rows.length).padStart(2)} ${who.padEnd(5)} ${label} -> ${result} (${receipt.gasUsed} gas)`);
}

const vaultCall = (functionName, callArgs) => ({ to: VAULT, data: encodeFunctionData({ abi: VAULT_ABI, functionName, args: callArgs }) });
const tokenCall = (functionName, callArgs) => ({ to: USDC_ADDRESS, data: encodeFunctionData({ abi: ERC20, functionName, args: callArgs }) });
const payCall = (to, amount, memo) => vaultCall("pay", [to, amount, memoHash(memo)]);
const chainNow = async () => Number((await pub.getBlock({ blockTag: "latest" })).timestamp);
const balanceOf = (a) => pub.readContract({ address: USDC_ADDRESS, abi: ERC20, functionName: "balanceOf", args: [a] });

// ---------------------------------------------------------------- the story
const startBlock = await pub.getBlockNumber();
const ownerBefore = await balanceOf(ownerAccount.address);
const payeeBefore = await balanceOf(payeeA);
console.log(`vault ${VAULT} on ${net.name}; owner ${ownerAccount.address}; agent ${agentAccount.address}`);

// 1. fund the vault, both ways
await ok("owner", `approve the vault to pull ${usdc(u(3))} USDC`, tokenCall("approve", [VAULT, u(3)]), "ok");
await ok("owner", `deposit ${usdc(u(3))} USDC`, vaultCall("deposit", [u(3)]), "ok");
await ok("owner", `fund ${usdc(u(2))} USDC more with a plain USDC transfer`, tokenCall("transfer", [VAULT, u(2)]), "ok");

// 2. give the agent a policy and a little gas
const expiry1 = (await chainNow()) + 3600;
await ok("owner", `set policy: ${usdc(u(1))} per payment, ${usdc(u(2.5))} per rolling day, one allowed payee, expires in 1 hour`,
  vaultCall("setPolicy", [agentAccount.address, u(1), u(2.5), BigInt(expiry1), true, [payeeA]]), "ok");
await ok("owner", `send the agent ${feeToUsdc(GAS_TOPUP)} USDC for gas`, { to: agentAccount.address, value: GAS_TOPUP }, "ok");

// 3. the agent pays inside its policy, through the client an agent would use
async function clientPay(amount, memo, arcMemo) {
  const nonce = await nextNonce(agentAccount.address);
  const r = await retry(() => agentClient.pay({ to: payeeA, amount, memo, arcMemo, nonce }));
  const receipt = await pub.getTransactionReceipt({ hash: r.hash });
  await settle();
  if (arcMemo !== undefined && !r.arcMemo) throw new Error("Arc's Memo contract emitted no event");
  const how = arcMemo === undefined ? "" : `, sent through Arc's Memo contract with the public memo "${arcMemo}"`;
  record("agent", `pay ${usdc(amount)} USDC to the allowed payee, memo "${memo}"${how} (payment #${r.id})`, "ok", "ok", r.hash, receipt);
}
await clientPay(u(1), "invoice-001");

// 4. the agent tries to break each rule
await refused("agent", `pay ${usdc(u(1.5))} USDC (over the per-payment cap)`, payCall(payeeA, u(1.5), "too big"), "ExceedsPerPaymentCap");
await refused("agent", `pay ${usdc(u(0.5))} USDC to an address that is not on the list`, payCall(payeeB, u(0.5), "wrong payee"), "PayeeNotAllowed");
await clientPay(u(1), "invoice-002");
await refused("agent", `pay ${usdc(u(1))} USDC (would pass the daily cap; ${usdc(u(0.5))} left)`, payCall(payeeA, u(1), "over the day"), "ExceedsDailyCap");
await clientPay(u(0.5), "invoice-003", "order 3, paid by the agent"); // the policy binds through Arc's Memo contract too
await refused("agent", `pay 0.000001 USDC (daily cap fully used)`, payCall(payeeA, 1n, "one more"), "ExceedsDailyCap");
await refused("agent", "withdraw everything to itself", vaultCall("withdrawAll", [agentAccount.address]), "NotOwner");
await refused("agent", "give itself a bigger policy", vaultCall("setPolicy", [agentAccount.address, u(100), u(100), BigInt(expiry1), false, []]), "NotOwner");
await refused("agent", "pause the vault", vaultCall("pause", []), "NotOwner");

// 5. the owner pauses
await ok("owner", "pause", vaultCall("pause", []), "ok");
await refused("agent", `pay ${usdc(u(0.1))} USDC while paused`, payCall(payeeA, u(0.1), "paused"), "VaultPaused");
await ok("owner", "unpause", vaultCall("unpause", []), "ok");

// 6. expiry: a new policy with room to spend that expires in about 20 seconds
const expiry2 = (await chainNow()) + 20;
await ok("owner", `set policy again: daily cap ${usdc(u(10))} USDC, expires in 20 seconds`,
  vaultCall("setPolicy", [agentAccount.address, u(1), u(10), BigInt(expiry2), true, [payeeA]]), "ok");
if (net.fork) {
  await pub.request({ method: "evm_increaseTime", params: [30] });
  await pub.request({ method: "evm_mine", params: [] });
} else {
  while ((await chainNow()) <= expiry2) await sleep(2000);
  await sleep(3000);
}
await refused("agent", `pay ${usdc(u(0.1))} USDC after the policy expired`, payCall(payeeA, u(0.1), "late"), "PolicyExpired");

// 7. revoke
const expiry3 = (await chainNow()) + 3600;
await ok("owner", "set a fresh one-hour policy", vaultCall("setPolicy", [agentAccount.address, u(1), u(10), BigInt(expiry3), true, [payeeA]]), "ok");
await ok("owner", "revoke the agent", vaultCall("revokeAgent", [agentAccount.address]), "ok");
await refused("agent", `pay ${usdc(u(0.1))} USDC after being revoked`, payCall(payeeA, u(0.1), "revoked"), "NoPolicy");

// 8. the owner takes the rest back; the agent returns its unused gas
const left = await pub.readContract({ address: VAULT, abi: VAULT_ABI, functionName: "vaultBalance" });
await ok("owner", `withdraw everything (${usdc(left)} USDC)`, vaultCall("withdrawAll", [ownerAccount.address]), "ok");
{
  const f = await fees(pub);
  const dust = (await pub.getBalance({ address: agentAccount.address })) - 2n * 21_000n * f.maxFeePerGas;
  if (dust > 0n) await ok("agent", `return ${feeToUsdc(dust)} USDC of unused gas to the owner`, { to: ownerAccount.address, value: dust, gas: 21_000n }, "ok");
}

// ---------------------------------------------------------------- the audit trail
await sleep(1500);
const payments = await agentClient.payments({ fromBlock: startBlock });
const paidTotal = await pub.readContract({ address: VAULT, abi: VAULT_ABI, functionName: "totalPaidBy", args: [agentAccount.address] });
const vaultEnd = await pub.readContract({ address: VAULT, abi: VAULT_ABI, functionName: "vaultBalance" });
const payeeGot = (await balanceOf(payeeA)) - payeeBefore;
const ownerAfter = await balanceOf(ownerAccount.address);
const eventSum = payments.reduce((s, p) => s + parseUnits(p.amount, 6), 0n);
if (payments.length !== 3 || eventSum !== paidTotal || paidTotal !== u(2.5) || vaultEnd !== 0n) {
  throw new Error(`final checks failed: ${payments.length} payments, events ${eventSum}, total ${paidTotal}, vault ${vaultEnd}`);
}

// ---------------------------------------------------------------- mainnet estimate (read-only)
let mainnetGasPrice = null;
try {
  mainnetGasPrice = await clients(getNetwork({ network: "arc-mainnet" })).publicClient.getGasPrice();
} catch { /* offline: leave the estimate out */ }
const deployGas = BigInt(deployment.gasUsed);

// ---------------------------------------------------------------- write the evidence
const L = [];
const short = (h) => `${h.slice(0, 10)}...${h.slice(-6)}`;
const link = (h) => (net.explorer ? `[${short(h)}](${txLink(net, h)})` : `\`${h}\``);
const alink = (a) => (net.explorer ? `[\`${a}\`](${addrLink(net, a)})` : `\`${a}\``);
L.push(`# ${net.fork ? `Rehearsal on a local fork of ${net.chainId === 5042 ? "Arc mainnet" : "Arc Testnet"} (a simulation, not evidence from the public network)` : net.key === "arc-testnet" ? "Testnet evidence" : "Mainnet evidence"}`);
L.push("");
L.push(`Written by \`script/scenario.mjs\` on ${new Date().toISOString()}. Network: ${net.fork ? "a local fork of " : ""}${net.chainId === 5042 ? "Arc mainnet" : "Arc Testnet"}, chain id ${net.chainId}.`);
L.push("");
L.push(`- Vault: ${alink(VAULT)} (deployed in ${link(deployment.txHash)}, block ${deployment.blockNumber}, ${deployment.gasUsed} gas, ${deployment.feeUsdc} USDC)`);
L.push(`- Owner: ${alink(ownerAccount.address)}`);
L.push(`- Agent (a key made for this run): ${alink(agentAccount.address)}`);
L.push(`- Allowed payee: ${alink(payeeA)}. Address that is not on the list: ${alink(payeeB)}`);
L.push(`- USDC: ${alink(USDC_ADDRESS)}`);
L.push("");
L.push("## What happened");
L.push("");
L.push("| # | Who | Action | Expected | Result | Gas | Fee (USDC) | Transaction |");
L.push("|---|-----|--------|----------|--------|-----|------------|-------------|");
for (const r of rows) L.push(`| ${r.n} | ${r.who} | ${r.label} | ${r.expect} | ${r.result} | ${r.gas} | ${feeToUsdc(r.fee)} | ${link(r.hash)} |`);
L.push("");
L.push("Every refusal above is a transaction that reverted on chain; the reason was read by simulating the same call first.");
L.push("");
L.push("## The audit trail, read back from the Payment events");
L.push("");
L.push("| Payment | Payee | Amount (USDC) | Memo hash | Block | Transaction |");
L.push("|---------|-------|---------------|-----------|-------|-------------|");
for (const p of payments) L.push(`| ${p.id} | \`${p.payee}\` | ${p.amount} | \`${p.memoHash}\` | ${p.blockNumber} | ${link(p.hash)} |`);
L.push("");
L.push(`The memo hashes are keccak256 of the texts "invoice-001", "invoice-002" and "invoice-003": ${["invoice-001", "invoice-002", "invoice-003"].map((m) => `\`${memoHash(m).slice(0, 18)}...\``).join(", ")}.`);
L.push("");
L.push("## Final checks (all enforced by the script)");
L.push("");
L.push(`- Payments found in the events: ${payments.length}; their sum ${usdc(eventSum)} USDC equals \`totalPaidBy(agent)\` = ${usdc(paidTotal)} USDC, which is exactly the daily cap.`);
if (payeeA.toLowerCase() === ownerAccount.address.toLowerCase()) L.push(`- The allowed payee was the owner's own address, so the ${usdc(paidTotal)} USDC paid by the agent went back to the owner. The vault ended at ${usdc(vaultEnd)} USDC.`);
else L.push(`- The payee received ${usdc(payeeGot)} USDC. The vault ended at ${usdc(vaultEnd)} USDC.`);
L.push(`- Owner USDC before ${usdc(ownerBefore)}, after ${usdc(ownerAfter)} (the difference is the payments, the fees and gas left unspent).`);
L.push(`- Refused attempts: ${rows.filter((r) => r.result.startsWith("reverted")).length}, each with the expected reason.`);
L.push("");
L.push("## Cost");
L.push("");
L.push(`- This run: ${rows.length} transactions, ${totalGas} gas, ${feeToUsdc(totalFee)} USDC in fees. Deployment: ${deployGas} gas, ${deployment.feeUsdc} USDC.`);
if (mainnetGasPrice) {
  const round = (wei) => Number(feeToUsdc(wei)).toFixed(4);
  L.push(`- Arc mainnet gas price read when this was written: ${(Number(mainnetGasPrice) / 1e9).toFixed(3)} gwei. At that price the deployment costs ${round(deployGas * mainnetGasPrice)} USDC and this scenario ${round(totalGas * mainnetGasPrice)} USDC: ${round((deployGas + totalGas) * mainnetGasPrice)} USDC in total.`);
  L.push(`- Worst case allowed by the protocol (base fee ceiling 20,000 gwei): ${round((deployGas + totalGas) * 20_000_000_000_000n)} USDC for both.`);
}
L.push("");
const outFile = resolve(ROOT, String(args.out || (net.fork ? "SCENARIO-local.md" : net.key === "arc-testnet" ? "TESTNET.md" : "MAINNET.md")));
writeFileSync(outFile, L.join("\n"));
console.log(`\n${rows.length} transactions, ${feeToUsdc(totalFee)} USDC in fees. Evidence written to ${outFile}`);
