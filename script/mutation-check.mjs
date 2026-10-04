// Do the tests have teeth? Breaks the contract in a scratch copy, one rule at a time,
// and expects the test suite to fail each time. The repository itself is never modified.
//
//   node script/mutation-check.mjs            (uses `forge`; set FORGE=arc-forge for Arc Foundry)
import { cpSync, mkdtempSync, readFileSync, writeFileSync, symlinkSync, rmSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { ROOT } from "./lib.mjs";

const FORGE = process.env.FORGE || "forge";
const MUTANTS = [
  ["rolling window one bucket short", "uint256 public constant WINDOW_BUCKETS = 25;", "uint256 public constant WINDOW_BUCKETS = 24;"],
  ["per-payment cap off by one", "if (amount > p.maxPerPayment) revert", "if (amount > p.maxPerPayment + 1) revert"],
  ["daily cap off by one", "if (spent + amount > p.maxPerDay) {", "if (spent + amount > p.maxPerDay + 1) {"],
  ["expiry off by one second", "if (block.timestamp >= p.expiry) revert PolicyExpired(p.expiry);", "if (block.timestamp > p.expiry) revert PolicyExpired(p.expiry);"],
  ["payee list not checked", "if (p.restrictPayees && !_payeeAllowed[msg.sender][p.payeeEpoch][payee]) revert PayeeNotAllowed(payee);", ""],
  ["pause not checked", "if (paused) revert VaultPaused();", ""],
  ["revoked agents can still pay", "if (!p.active) revert NoPolicy();\n        if (block.timestamp", "if (block.timestamp"],
  ["old payee list survives a new policy", "uint32 epoch = _policies[agent].payeeEpoch + 1;", "uint32 epoch = _policies[agent].payeeEpoch;"],
  ["spending overwritten instead of added", "_spentInBucket[msg.sender][block.timestamp / BUCKET_SECONDS] += amount;", "_spentInBucket[msg.sender][block.timestamp / BUCKET_SECONDS] = amount;"],
  ["anyone can withdraw", "function withdraw(address to, uint256 amount) external onlyOwner nonReentrant {", "function withdraw(address to, uint256 amount) external nonReentrant {"],
  ["anyone can set a policy", ") external onlyOwner {\n        if (agent == address(0)) revert ZeroAddress();", ") external {\n        if (agent == address(0)) revert ZeroAddress();"],
  ["pay without the reentrancy lock", "function pay(address payee, uint256 amount, bytes32 memoHash) external nonReentrant returns (uint256 id) {", "function pay(address payee, uint256 amount, bytes32 memoHash) external returns (uint256 id) {"],
  ["payee list editable on a policy that ignores it", "if (!p.restrictPayees) revert InvalidPolicy();", ""],
  ["look-alike token accepted on Arc", "if ((block.chainid == 5042 || block.chainid == 5042002) && usdc_ != ARC_USDC) revert NotUSDC();", ""],
  ["vault balance not checked before paying", "if (amount > balance) revert InsufficientVaultBalance(amount, balance);\n\n        // effects", "// effects"],
];

const work = mkdtempSync(join(tmpdir(), "aav-mutants-"));
for (const item of ["src", "test", "foundry.toml"]) cpSync(resolve(ROOT, item), join(work, item), { recursive: true });
symlinkSync(resolve(ROOT, "node_modules"), join(work, "node_modules"));
const original = readFileSync(resolve(ROOT, "src/AgentAllowanceVault.sol"), "utf8");
const target = join(work, "src/AgentAllowanceVault.sol");

let survivors = 0;
for (const [name, find, replace] of MUTANTS) {
  if (!original.includes(find)) { console.log(`STALE     ${name}: the text to mutate was not found`); survivors++; continue; }
  writeFileSync(target, original.replace(find, replace));
  const run = spawnSync(FORGE, ["test"], { cwd: work, encoding: "utf8" });
  const summary = (run.stdout.match(/\d+ tests passed, \d+ failed/) || ["did not compile or run"])[0];
  const killed = run.status !== 0;
  if (!killed) survivors++;
  console.log(`${killed ? "killed  " : "SURVIVED"}  ${name}: ${summary}`);
}
rmSync(work, { recursive: true, force: true });
console.log(`\n${MUTANTS.length - survivors} of ${MUTANTS.length} mutants killed`);
process.exit(survivors ? 1 : 0);
