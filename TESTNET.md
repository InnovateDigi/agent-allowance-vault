# Testnet evidence: waiting for testnet USDC

**No transaction has been sent on Arc Testnet yet.** Nothing below is testnet evidence; this file says what is missing and what will fill it.

Arc pays gas in USDC, and the only official source of testnet USDC, the Circle faucet at https://faucet.circle.com, is protected by a bot check (reCAPTCHA). The AI system that wrote this repository does not pass or get round bot checks, so a person has to ask the faucet once:

1. Open https://faucet.circle.com
2. Choose **USDC** and the network **Arc Testnet**.
3. Paste the deployer address of this project and press the send button. The faucet gives 20 USDC per address every 2 hours; the run below needs less than 6.

Then, with `DEPLOYER_KEY_FILE` pointing at that deployer's key file (kept outside the repository):

```sh
forge build
node script/deploy.mjs --network arc-testnet
node script/scenario.mjs --network arc-testnet --out TESTNET.md
```

The second command overwrites this file with the deployed address, the 25 transactions of the scenario (fund, set a policy, pay inside it, try to exceed each limit and show the revert, pause, expire, revoke, withdraw) and their links on https://explorer.testnet.arc.io.

## What exists today instead

- [REHEARSAL.md](REHEARSAL.md): the same script, run against a local Arc Foundry fork of Arc Testnet (`arc-anvil --network arc --fork-url https://rpc.testnet.arc.io`). It uses Arc's real USDC code and rules, but it is a local simulation: its transaction hashes do not exist on the public testnet.
- `arc-forge test --match-contract ArcForkTest --fork-url https://rpc.testnet.arc.io`: 6 tests of the vault against the real USDC on a fork, including a payment sent through Arc's own Memo contract.
