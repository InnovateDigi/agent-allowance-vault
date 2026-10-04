// Deploys AgentAllowanceVault to Arc.
//
//   forge build
//   DEPLOYER_KEY_FILE=/path/outside/the/repo/deployer.json node script/deploy.mjs --network arc-testnet
//   DEPLOYER_KEY_FILE=/path/outside/the/repo/deployer.json node script/deploy.mjs --network arc-mainnet --yes-mainnet
//
// Options: --owner 0x... (default: the deployer), --rpc URL, --dry-run (estimate only),
//          --fork (the RPC is a local arc-anvil fork: a rehearsal, recorded in deployments/local.json).
import { writeFileSync, mkdirSync, readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { encodeDeployData, getAddress } from "viem";
import { ROOT, USDC_ADDRESS, NETWORKS, parseArgs, getNetwork, loadAccount, clients, fees, artifact, feeToUsdc, txLink, addrLink } from "./lib.mjs";

const args = parseArgs();
const net = getNetwork(args);
if (net.key === "arc-mainnet" && !net.fork && !args["yes-mainnet"] && !args["dry-run"]) {
  throw new Error("Refusing to deploy to Arc mainnet without --yes-mainnet.");
}
const account = loadAccount();
const owner = getAddress(args.owner || account.address);
const { publicClient, walletClient } = clients(net, account);
const { abi, bytecode } = artifact();

const chainId = await publicClient.getChainId();
if (chainId !== net.chainId) throw new Error(`RPC reports chain ${chainId}, expected ${net.chainId}`);

const data = encodeDeployData({ abi, bytecode, args: [USDC_ADDRESS, owner] });
const fee = await fees(publicClient);
const gas = await publicClient.estimateGas({ account: account.address, data });
const gasPrice = await publicClient.getGasPrice();
const balance = await publicClient.getBalance({ address: account.address });
console.log(`network   ${net.name} (chain ${chainId})`);
console.log(`deployer  ${account.address}  balance ${feeToUsdc(balance)} USDC`);
console.log(`owner     ${owner}`);
console.log(`estimate  ${gas} gas x ${gasPrice} wei = ${feeToUsdc(gas * gasPrice)} USDC`);
if (args["dry-run"]) process.exit(0);
if (balance < gas * fee.maxFeePerGas) throw new Error("Deployer balance is too low to pay for gas.");

const hash = await walletClient.sendTransaction({ data, gas: (gas * 12n) / 10n, ...fee });
const receipt = await publicClient.waitForTransactionReceipt({ hash });
if (receipt.status !== "success") throw new Error(`Deployment reverted: ${hash}`);
const address = receipt.contractAddress;
const cost = receipt.gasUsed * receipt.effectiveGasPrice;

const record = {
  network: net.fork ? `local fork of ${net.key === "local" ? "arc-testnet" : net.key}` : net.key,
  chainId,
  address,
  owner,
  usdc: USDC_ADDRESS,
  deployer: account.address,
  txHash: hash,
  blockNumber: Number(receipt.blockNumber),
  gasUsed: Number(receipt.gasUsed),
  feeUsdc: feeToUsdc(cost),
  deployedAt: new Date().toISOString(),
  explorer: addrLink(net, address),
};
mkdirSync(resolve(ROOT, "deployments"), { recursive: true });
writeFileSync(resolve(ROOT, `deployments/${net.recordKey}.json`), JSON.stringify(record, null, 2) + "\n");

if (!net.fork) refreshReadme();
console.log(`deployed  ${address}`);
console.log(`tx        ${txLink(net, hash)}`);
console.log(`cost      ${record.feeUsdc} USDC (${receipt.gasUsed} gas)`);
if (net.explorer) {
  console.log(`\nPublish the source on the explorer (no key needed):`);
  console.log(
    `forge verify-contract ${address} src/AgentAllowanceVault.sol:AgentAllowanceVault --chain-id ${chainId} ` +
      `--verifier blockscout --verifier-url ${net.explorer}/api/ ` +
      `--constructor-args $(cast abi-encode "constructor(address,address)" ${USDC_ADDRESS} ${owner})`,
  );
}

/** Rewrites the "Deployed addresses" table of the README and docs/deployments.json (read by the static page). */
function refreshReadme() {
  const page = {};
  for (const [key, short] of [["arc-mainnet", "mainnet"], ["arc-testnet", "testnet"]]) {
    const path = resolve(ROOT, `deployments/${key}.json`);
    if (!existsSync(path)) continue;
    const d = JSON.parse(readFileSync(path, "utf8"));
    page[short] = { address: d.address, blockNumber: d.blockNumber, txHash: d.txHash };
  }
  writeFileSync(resolve(ROOT, "docs/deployments.json"), JSON.stringify(page, null, 2) + "\n");

  const file = resolve(ROOT, "README.md");
  const readme = readFileSync(file, "utf8");
  const start = "<!-- deployments:start -->", end = "<!-- deployments:end -->";
  if (!readme.includes(start) || !readme.includes(end)) return;
  const lines = ["| Network | Chain id | Vault | Deployment transaction |", "|---|---|---|---|"];
  for (const [key, label] of [["arc-mainnet", "Arc mainnet"], ["arc-testnet", "Arc Testnet"]]) {
    const n = NETWORKS[key];
    const path = resolve(ROOT, `deployments/${key}.json`);
    if (!existsSync(path)) { lines.push(`| ${label} | ${n.chainId} | not deployed yet | |`); continue; }
    const d = JSON.parse(readFileSync(path, "utf8"));
    lines.push(`| ${label} | ${n.chainId} | [\`${d.address}\`](${n.explorer}/address/${d.address}) | [\`${d.txHash.slice(0, 18)}...\`](${n.explorer}/tx/${d.txHash}) |`);
  }
  const head = readme.slice(0, readme.indexOf(start) + start.length);
  const tail = readme.slice(readme.indexOf(end));
  writeFileSync(file, `${head}\n${lines.join("\n")}\n${tail}`);
}
