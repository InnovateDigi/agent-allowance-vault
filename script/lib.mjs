// Shared helpers for the deploy and scenario scripts. Node 20+, viem only.
import { createPublicClient, createWalletClient, defineChain, http, parseGwei, formatUnits } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

export const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

/** USDC's ERC-20 interface on Arc (6 decimals), the same address on mainnet and testnet. */
export const USDC_ADDRESS = "0x3600000000000000000000000000000000000000";

export const NETWORKS = {
  "arc-testnet": { chainId: 5042002, name: "Arc Testnet", rpc: "https://rpc.testnet.arc.io", explorer: "https://explorer.testnet.arc.io", testnet: true },
  "arc-mainnet": { chainId: 5042, name: "Arc", rpc: "https://rpc.mainnet.arc.io", explorer: "https://explorer.arc.io", testnet: false },
  // A local `arc-anvil --network arc --fork-url https://rpc.testnet.arc.io` node, for rehearsals.
  // To rehearse against a fork of mainnet instead: --network arc-mainnet --fork --rpc http://127.0.0.1:8545
  local: { chainId: 5042002, name: "Local fork of Arc Testnet", rpc: "http://127.0.0.1:8545", explorer: "", testnet: true },
};

export function parseArgs(argv = process.argv.slice(2)) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    if (!argv[i].startsWith("--")) continue;
    const key = argv[i].slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith("--")) out[key] = true;
    else { out[key] = next; i++; }
  }
  return out;
}

export function getNetwork(args) {
  const key = args.network;
  if (!key || !NETWORKS[key]) throw new Error(`--network must be one of: ${Object.keys(NETWORKS).join(", ")}`);
  const net = { key, ...NETWORKS[key] };
  if (args.rpc) net.rpc = args.rpc;
  // --fork: the RPC is a local fork of that network (arc-anvil). Nothing reaches the public chain,
  // the record goes to deployments/local.json and no explorer links are written.
  net.fork = key === "local" || Boolean(args.fork);
  net.recordKey = net.fork ? "local" : key;
  if (net.fork) net.explorer = "";
  net.chain = defineChain({
    id: net.chainId,
    name: net.name,
    nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 }, // gas is USDC with 18 decimals
    rpcUrls: { default: { http: [net.rpc] } },
    testnet: net.testnet,
  });
  return net;
}

/**
 * Load the signing key without ever printing it.
 * DEPLOYER_KEY_FILE: path of a JSON file { "privateKey": "0x..." } kept outside the repository, or
 * PRIVATE_KEY: the key itself in the environment.
 */
export function loadAccount() {
  const file = process.env.DEPLOYER_KEY_FILE;
  let key = process.env.PRIVATE_KEY;
  if (file) key = JSON.parse(readFileSync(file, "utf8")).privateKey;
  if (!key) throw new Error("Set DEPLOYER_KEY_FILE (JSON with a privateKey field) or PRIVATE_KEY.");
  return privateKeyToAccount(key);
}

export function clients(net, account) {
  const transport = http(net.rpc, { retryCount: 5, retryDelay: 400 });
  const publicClient = createPublicClient({ chain: net.chain, transport, pollingInterval: 750 });
  const walletClient = account ? createWalletClient({ account, chain: net.chain, transport }) : null;
  return { publicClient, walletClient };
}

/** Arc drops transactions priced under 20 gwei, so never go below a safe ceiling. */
export async function fees(publicClient) {
  const gasPrice = await publicClient.getGasPrice();
  const floor = parseGwei("40");
  const maxFeePerGas = gasPrice * 2n > floor ? gasPrice * 2n : floor;
  return { maxFeePerGas, maxPriorityFeePerGas: parseGwei("1") };
}

export function artifact() {
  const json = JSON.parse(readFileSync(resolve(ROOT, "out/AgentAllowanceVault.sol/AgentAllowanceVault.json"), "utf8"));
  return { abi: json.abi, bytecode: json.bytecode.object };
}

/** Gas is paid in native USDC with 18 decimals. */
export const feeToUsdc = (wei) => formatUnits(wei, 18);
export const usdc = (units) => formatUnits(units, 6);
export const txLink = (net, hash) => (net.explorer ? `${net.explorer}/tx/${hash}` : hash);
export const addrLink = (net, a) => (net.explorer ? `${net.explorer}/address/${a}` : a);
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
