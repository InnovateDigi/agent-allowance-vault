# Agent Allowance Vault

A small, non-upgradeable contract on [Arc](https://docs.arc.io) that lets a person fund an AI agent with USDC under hard limits.

- The **owner** puts USDC in the vault and can withdraw at any time, pause every agent, or revoke one.
- Each **agent key** gets a policy: a cap per payment, a cap per rolling day, an optional list of allowed payees and an expiry.
- The agent can pay USDC within its policy **and can do nothing else**. Every payment emits an event with a memo hash.

> **Read this first.** All the code here was written by an AI system. It has **not** had a professional security audit. Use small amounts and read [what it does not protect against](#what-it-does-not-protect-against).

## Why it exists

A team of AI agents ran a real 48-hour business experiment under a hard budget, and afterwards wrote the control it wished it had had. A budget that lives in an agent's instructions holds only while the agent follows them. A payment rail should be able to say "this agent may spend at most this much, to these parties, until this date" by itself. In this vault the limits are enforced by the chain, so they hold even if the agent is confused, misled by what it reads, or its key is stolen.

## Why Arc

- **USDC is the gas token.** An agent needs one asset, not two. Its key holds a few cents of USDC for gas; the money stays in the vault. A payment costs about 147,000 gas, roughly 0.003 USDC at Arc's 20 gwei floor.
- **Fees are stable and in dollars**, so a budget in USDC is a budget in fees too.
- **Finality is under a second and deterministic.** A pause or a revoke takes effect at once; a payee can act on a payment after one block.
- **Native and ERC-20 USDC are one balance.** The vault moves funds only through the ERC-20 interface (`0x3600000000000000000000000000000000000000`, 6 decimals), as Arc recommends. It has no payable function, so a plain native send reverts and the code has one path with one set of decimals. On Arc the constructor accepts only that canonical USDC address.
- **It composes with Arc's own tools.** Arc's predeployed `Memo` contract keeps the calling account as `msg.sender`, so an agent can attach a native Arc memo to a vault payment with no change to the vault: the policy still applies, and Arc's `Memo` event carries the same hash as the vault's `Payment` event. This is tested on forks of Arc Testnet and Arc mainnet, and the client has an option for it.

## How it works

`src/AgentAllowanceVault.sol` is one file of about 390 lines with no imports.

| Who | Function | Rule |
|---|---|---|
| anyone | `deposit(amount)` or a plain USDC `transfer` to the vault | adds funds; only the owner can take them out |
| owner | `withdraw(to, amount)`, `withdrawAll(to)` | any time, also while paused |
| owner | `pause()`, `unpause()` | while paused no agent can pay |
| owner | `setPolicy(agent, maxPerPayment, maxPerDay, expiry, restrictPayees, payees)` | replaces the earlier policy and its payee list; never resets spending history |
| owner | `setPayee(agent, payee, allowed)` | only for a policy that restricts payees; on an open policy it reverts, because a list would have no effect |
| owner | `revokeAgent(agent)` | never reverts for the owner |
| agent | `pay(payee, amount, memoHash)` | must pass every check below |
| anyone | `policyOf`, `isPayeeAllowed`, `spentInWindow`, `availableToPay`, `vaultBalance`, `totalPaidBy`, `paymentCount` | views |

`pay` checks, in this order: not paused; the caller has a policy; not expired; amount above zero; payee is not the zero address or the vault; amount within the per-payment cap; payee on the list (if the policy has one); amount fits in the rolling daily cap; the vault holds enough. Then it records the spending, emits `Payment(agent, payee, memoHash, id, amount, spentInWindow)` and transfers. Each refusal is a named error such as `ExceedsDailyCap(amount, remaining)`.

**The rolling day.** Spending is recorded in one-hour buckets, and the cap is checked over the current bucket plus the 24 before it. That span is between 24 and 25 hours long, so it always contains the whole trailing 24 hours. Two guarantees follow, and both are tested as properties:

- *Safety:* at every payment, the agent's total over the trailing 24 hours, including that payment, is at most the daily cap in force at that payment. With an unchanged cap this means no 24-hour window ever holds more than the cap. If the owner raises the cap, the new cap applies at once.
- *Fairness:* a payment is refused for the daily cap only if the last 25 hours plus that payment would exceed the cap. The check is never looser than a 24-hour limit and at most one hour stricter.

**What is deliberately missing.** No proxy, no upgrade, no `delegatecall`, no `selfdestruct`, no owner transfer (the owner and the token are immutable; to rotate the owner, withdraw and deploy a new vault for about 0.03 USDC), no token other than USDC, no fee, no way for anyone but the owner to take funds out except an agent's `pay` within its policy.

## Use it

Requirements: Node 20+, and [Arc Foundry](https://docs.arc.io/arc/tutorials/install-arc-foundry) (`arc-forge`) or plain Foundry (`forge`). The commands below say `forge`; with Arc Foundry type `arc-forge`.

```sh
npm install          # viem and forge-std, both pinned
forge build
forge test           # unit, fuzz and invariant tests on a mock USDC; the 6 fork tests skip themselves
arc-forge test --match-contract ArcForkTest --fork-url https://rpc.testnet.arc.io -vv   # the same vault against Arc's real USDC
node script/check-web-constants.mjs   # the static page agrees with the compiled contract
node script/mutation-check.mjs        # break 15 rules one at a time; the tests must catch each (FORGE=arc-forge with Arc Foundry)
```

Deploy (the key file is a JSON file `{ "privateKey": "0x..." }` kept outside the repository; the scripts never print it):

```sh
export DEPLOYER_KEY_FILE=/absolute/path/outside/the/repo/deployer.json
node script/deploy.mjs --network arc-testnet                    # add --owner 0x... to give the vault to another address
node script/deploy.mjs --network arc-mainnet --yes-mainnet
node script/scenario.mjs --network arc-testnet --out TESTNET.md  # the whole story, with transaction links
```

To rehearse either network without spending anything, run `arc-anvil --network arc --fork-url <the network's RPC>` and add `--fork --rpc http://127.0.0.1:8545` to the same two commands.

An agent uses `client/vault-client.mjs` (one file, one dependency):

```js
import { createVaultClient } from "./client/vault-client.mjs";
const vault = createVaultClient({ network: "arc-mainnet", vault: "0x...", privateKey: process.env.AGENT_KEY });
await vault.status();                                   // caps, what is left today, expiry, gas balance
await vault.check({ to: "0x...", amount: "1.25" });     // { ok: false, reason: "ExceedsDailyCap", args: [...] } costs nothing
await vault.pay({ to: "0x...", amount: "1.25", memo: "invoice 2026-104" });   // refuses locally if the chain would refuse
await vault.pay({ to: "0x...", amount: "1.25", memo: "invoice 2026-104", arcMemo: "order 104" });   // the same, sent through Arc's Memo contract
await vault.payments({ fromBlock });                    // the audit trail from the events
```

A person uses the static page `docs/index.html` (one file, no build step, no external scripts; it can be served by GitHub Pages from `/docs`):

- **Audit (read-only):** no wallet needed. Lists an agent's payments from the `Payment` events, checks that they add up to the vault's own `totalPaidBy`, shows the agent's policy and what it can still spend, and lets anyone check a memo text against the recorded hashes. Link form: `docs/index.html?net=mainnet&vault=0x...&agent=0x...&from=<deployment block>`. With no parameters the page opens the deployment listed in `docs/deployments.json`, which `script/deploy.mjs` writes.
- **Owner dashboard:** connect a wallet, fund, set a policy, allow or remove a payee, revoke, pause, withdraw. Each action is dry-run first so the page can show the vault's own reason for a refusal.

## Threat model

The vault assumes the **owner key is safe** and the **agent key is not**: the agent may be buggy, may be talked into things by text it reads, or its key may be copied.

What a compromised or misbehaving agent key cannot do, whatever it signs:

- pay more than the per-payment cap in one payment, or more than the daily cap in any rolling 24 hours;
- pay anyone outside its payee list, when the policy has one;
- pay after its expiry, while the vault is paused, or after it has been revoked;
- withdraw, change any policy, add a payee, pause or unpause;
- re-enter the vault during a transfer (a lock plus checks-effects-interactions).

So the most a stolen agent key can take is the daily cap per day, limited by the vault balance, to its allowed payees, until the owner pauses or revokes (one transaction, final in under a second) or the policy expires. The agent key also holds a little USDC for gas, which is outside the vault.

### What it does NOT protect against

- **A compromised or lost owner key.** The owner can withdraw everything, and the owner cannot be changed. If the key is lost nobody can withdraw, and agents keep paying within their policies until those expire. Use a multisig or a hardware wallet as the owner, and short expiries.
- **An owner who signs a batch without reading it.** Arc's `Memo` and `Multicall3From` contracts forward calls as the account that signed the transaction, so a transaction to them carries the signer's full authority over the vault. An owner that is a contract (a multisig) cannot be used this way.
- **An account with an EIP-7702 delegation.** An owner or agent address that delegates to other code is only as safe as that code.
- **A bad payment inside the limits.** If an agent is tricked into paying the wrong party for the wrong reason, and the amount and the payee pass the policy, the payment goes through. Without a payee list, "the wrong party" can be anyone. The vault does not check the memo, the invoice or whether anything was delivered. Payments cannot be reversed.
- **A dishonest or compromised allowed payee.**
- **Several agents together.** Caps are per agent. Three agents with a cap of 10 USDC per day can spend 30. The vault balance is the only global limit.
- **The owner's own changes.** A new policy applies at once; raising a cap raises it for the current day too.
- **USDC and Arc themselves.** The USDC issuer can blocklist an address or pause the token: payments to a blocklisted payee revert, and a blocklisted vault could not move funds. Blocklisting an agent's address does not stop that agent, because the vault, not the agent, is the sender of the money; revoke it instead. Arc is run by a permissioned validator set, which could delay or censor transactions. Block timestamps come from the proposer's clock; the vault's hour buckets tolerate that, but expiry is only as exact as block time.
- **Mistakes in this code.** It is small and tested, but it was written by an AI system and nobody has audited it.
- **Everything off the chain.** Where the agent key is stored, a lying RPC endpoint (it cannot steal, but it can mislead), a tampered copy of the web page (check what your wallet shows before you sign).
- **Privacy.** Amounts, payees and times are public. A memo hash of a guessable text can be guessed; add a random salt to the memo if that matters.
- **Lost funds by mistake.** Tokens other than USDC sent to the vault are stuck for good; there is no rescue function, on purpose. Value forced into the vault (for example by a self-destructing contract) simply adds to the balance, without a `Deposited` event; amounts below a millionth of a USDC cannot be moved through the 6-decimal interface.
- **A race on an exact withdrawal.** `withdraw(to, amount)` for the whole balance fails if an agent's payment lands first. `withdrawAll` and `pause` cannot be blocked this way.
- **Running out of gas.** An agent with no USDC on its own address cannot pay. The owner tops it up with a few cents.

## Tests

`forge test` runs three files: 74 unit tests, 4 fuzz tests, 3 invariants and 6 fork tests. On a plain EVM everything passes except the fork tests, which need a fork of Arc and skip themselves. (Arc Foundry 0.8 reports this as 81 passed and 6 skipped; Foundry 1.8 runs the three invariants as one campaign and reports 79 passed and 6 skipped.)

- `test/AgentAllowanceVault.t.sol`: the 74 unit tests, one or more for every rule and every revert, including a blocklisted payee, a token that reports failure, a hostile token that re-enters, and payments in the same second (Arc blocks may share a timestamp).
- `test/DailyCap.property.t.sol`: 4 fuzz tests and 3 invariants. The main one drives 72 random payments at random times (same second, exact hours, just under and just over a day) and checks *safety* and *fairness* of the rolling cap after each. The invariants run random owner and agent actions on three agents and check that no payment ever broke a rule and that funds are conserved.
- `test/ArcFork.t.sol`: 6 tests of the vault against Arc's real USDC on a fork of Arc Testnet or Arc mainnet: the native balance and the ERC-20 balance are one, native sends are refused, a contract payee is paid without its code running, and a payment sent through Arc's `Memo` contract still reaches the vault as the agent and still obeys the policy.

`node script/mutation-check.mjs` breaks the contract in a scratch copy, one rule at a time (the window one bucket short, each cap off by one, expiry off by one second, no payee check, no pause check, and so on). The tests catch all 15 mutants.

A separate AI agent, given only the contract and its intended behaviour, then tried to break it (this is not a professional audit). It found no way to exceed a policy. Its one low-severity finding (`setPayee` used to succeed silently on a policy without a payee list) and its corrections to the wording of the comments are applied.

The static page has no test framework. `script/check-web-constants.mjs` runs the page's own script outside a browser and checks its keccak256, function selectors, event topic, error list and ABI encoding against viem and the compiled contract. Both views were also run in headless Chrome against a local fork: the audit view on the rehearsal's payments, and every owner action through a stand-in wallet.

## Deployed addresses

<!-- deployments:start -->
| Network | Chain id | Vault | Deployment transaction |
|---|---|---|---|
| Arc mainnet | 5042 | not deployed yet | |
| Arc Testnet | 5042002 | not deployed yet | |
<!-- deployments:end -->

Evidence: `script/scenario.mjs` writes `MAINNET.md` and [TESTNET.md](TESTNET.md) when it runs on those networks, with a link for every transaction (until then TESTNET.md says what is missing). [REHEARSAL.md](REHEARSAL.md) is the same 25-transaction scenario on a local Arc Foundry fork of Arc Testnet: a simulation, not evidence from the public network.

## Costs

Measured on a fork of Arc Testnet: deployment 1,606,709 gas; a payment about 147,000 gas (up to 223,000 for an agent's first payment to a new address, 166,000 through Arc's Memo contract); setting a policy 60,000 to 98,000; pause 44,000. At Arc mainnet's gas price of 20 gwei that is about 0.032 USDC to deploy and 0.003 USDC per payment.

## What comes next

- Signed payment intents (EIP-712), so that an agent needs no gas at all and any relayer can submit its payment.
- A per-agent lifetime budget next to the daily cap, and one global daily cap for all agents.
- Funding in one signature with USDC's `transferWithAuthorization` (EIP-3009).
- A professional review, before anyone trusts it with more than pocket money.

## Licence

MIT. See [LICENSE](LICENSE).
