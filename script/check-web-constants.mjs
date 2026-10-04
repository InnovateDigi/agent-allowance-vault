// Checks the static page (docs/index.html) against the compiled contract, without a browser.
// The page carries its own keccak256 and ABI encoding so that it needs no external script;
// this proves they agree with viem and with the ABI.
//
//   forge build && node script/check-web-constants.mjs
//   node script/check-web-constants.mjs --rpc http://127.0.0.1:8545 --vault 0x... --agent 0x... --from 123   (also runs the audit view)
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import vm from "node:vm";
import assert from "node:assert/strict";
import { keccak256 as viemKeccak, toHex, toFunctionSelector, toEventSelector, encodeFunctionData, parseAbi } from "viem";
import { ROOT, artifact, parseArgs } from "./lib.mjs";

const args = parseArgs();
const html = readFileSync(resolve(ROOT, "docs/index.html"), "utf8");
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
assert.equal(scripts.length, 1, "the page must have exactly one inline script");
assert.ok(!/<script[^>]+src=/i.test(html), "the page must not load any external script");
assert.ok(!/<link[^>]+href=/i.test(html), "the page must not load any external stylesheet");

// A minimal stand-in for the DOM: every element is a bag of properties.
const elements = {};
const element = () => ({ value: "", textContent: "", className: "", hidden: false, disabled: false, children: [], replaceChildren(...c) { this.children = c; this.textContent = c.map((x) => (typeof x === "string" ? x : x.textContent)).join(""); }, append(...c) { this.children.push(...c); this.textContent += c.map((x) => (typeof x === "string" ? x : x.textContent)).join(""); }, setAttribute() {} });
const sandbox = {
  document: { getElementById: (id) => (elements[id] ??= element()), createElement: element },
  window: {}, location: { search: "" }, history: { replaceState() {} },
  URLSearchParams, TextEncoder, fetch, setTimeout, console, Date, BigInt, Number, Promise, Set, Object, Array, String,
};
vm.createContext(sandbox);
vm.runInContext(
  scripts[0] + "\n;globalThis.__page = { keccak256, selector, topic, SIGNATURES, PAYMENT_EVENT, ERRORS, NETS, encodeSetPolicy, call, addrWord, word, parseUsdc, formatUsdc, explain, runAudit, rows: () => lastRows };",
  sandbox,
);
const page = sandbox.__page;

// 1. keccak256
for (const text of ["", "a", "invoice-001", "pay(address,uint256,bytes32)", "x".repeat(135), "x".repeat(136), "x".repeat(137), "y".repeat(1000)]) {
  assert.equal(page.keccak256(new TextEncoder().encode(text)), viemKeccak(toHex(text)), `keccak256 differs for ${text.length} bytes`);
}

// 2. function selectors, the event topic and the error list agree with the compiled ABI
const { abi } = artifact();
const byName = (type) => Object.fromEntries(abi.filter((x) => x.type === type).map((x) => [x.name, x]));
const functions = byName("function");
for (const [name, signature] of Object.entries(page.SIGNATURES)) {
  if (name === "transfer") { assert.equal(page.selector(signature), "0xa9059cbb"); continue; } // ERC-20 transfer
  assert.ok(functions[name], `the page calls ${name}, which the contract does not have`);
  assert.equal(page.selector(signature), toFunctionSelector(functions[name]), `selector of ${name}`);
}
assert.equal(page.topic(page.PAYMENT_EVENT), toEventSelector(byName("event").Payment), "Payment event topic");
const abiErrors = abi.filter((x) => x.type === "error").map((x) => `${x.name}(${x.inputs.map((i) => i.type).join(",")})`).sort();
assert.deepEqual([...page.ERRORS].sort(), abiErrors, "error list");

// 3. the hand-written setPolicy encoding equals viem's
const agent = "0x1111111111111111111111111111111111111111";
const payees = ["0x2222222222222222222222222222222222222222", "0x3333333333333333333333333333333333333333"];
for (const [restrict, list] of [[true, payees], [true, []], [false, []]]) {
  assert.equal(
    page.encodeSetPolicy(agent, 1_000_000n, 2_500_000n, 1_800_000_000, restrict, list),
    encodeFunctionData({ abi, functionName: "setPolicy", args: [agent, 1_000_000n, 2_500_000n, 1_800_000_000n, restrict, list] }),
    "setPolicy encoding",
  );
}
assert.equal(page.call("withdraw", page.addrWord(agent), page.word(5n)), encodeFunctionData({ abi, functionName: "withdraw", args: [agent, 5n] }));
assert.equal(page.call("setPayee", page.addrWord(agent), page.addrWord(payees[0]), page.word(1)), encodeFunctionData({ abi, functionName: "setPayee", args: [agent, payees[0], true] }));

// 4. amounts and error messages
assert.equal(page.parseUsdc("1.25"), 1_250_000n);
assert.equal(page.parseUsdc("0.000001"), 1n);
assert.equal(page.formatUsdc(1_234_567_890n), "1,234.56789");
assert.throws(() => page.parseUsdc("1.2345678"));
assert.throws(() => page.parseUsdc("-1"));
const errAbi = parseAbi(["error ExceedsDailyCap(uint256 amount, uint256 remaining)"]);
const errData = encodeFunctionData({ abi: [{ ...errAbi[0], type: "function", outputs: [], stateMutability: "pure" }], functionName: "ExceedsDailyCap", args: [1_000_000n, 500_000n] });
assert.equal(page.explain(errData), "ExceedsDailyCap: 1 against 0.5 USDC");
console.log("static checks passed: keccak256, selectors, event topic, error list, ABI encoding, amounts");

// 5. optional: run the page's audit view against a live RPC
if (args.rpc && args.vault) {
  page.NETS.testnet.rpc = String(args.rpc);
  elements.net = { ...element(), value: "testnet" };
  elements.vault = { ...element(), value: String(args.vault) };
  elements.aAgent = { ...element(), value: String(args.agent || "") };
  elements.aRange = { ...element(), value: args.from ? "from" : "20000" };
  elements.aFrom = { ...element(), value: String(args.from || "") };
  await page.runAudit();
  const rows = page.rows();
  console.log(`audit view: ${elements.aTitle.textContent}`);
  console.log(`audit view: ${elements.aCheck.textContent || elements.aMsg.textContent}`);
  for (const r of rows) console.log(`  #${r.id} ${page.formatUsdc(r.amount)} USDC to ${r.payee} memo ${r.memo.slice(0, 18)}...`);
  if (args.expect) assert.equal(rows.length, Number(args.expect), "number of payments shown by the page");
  if (args.memo) {
    elements.aMemo.value = String(args.memo);
    const hit = rows.filter((r) => r.memo === page.keccak256(new TextEncoder().encode(String(args.memo)))).length;
    console.log(`audit view: memo "${args.memo}" matches ${hit} payment(s)`);
    assert.equal(hit, 1, "memo lookup");
  }
  assert.ok(!elements.aMsg.className.includes("bad"), elements.aMsg.textContent);
}
