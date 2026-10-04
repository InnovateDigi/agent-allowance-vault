// What an agent does before and when it spends.
//
//   AGENT_KEY=0x... node client/example-agent.mjs --network arc-testnet --vault 0x... --to 0x... --amount 0.25 --memo "invoice 104"
//
// Without --to it only prints the agent's status.
import { createVaultClient } from "./vault-client.mjs";

const arg = (name, fallback) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > -1 ? process.argv[i + 1] : fallback;
};

const vault = createVaultClient({
  network: arg("network", "arc-mainnet"),
  vault: arg("vault"),
  privateKey: process.env.AGENT_KEY,
});

console.log("status", await vault.status());

const to = arg("to");
if (to) {
  const amount = arg("amount", "0.01");
  const memo = arg("memo", "");
  const verdict = await vault.check({ to, amount, memo });
  if (!verdict.ok) {
    console.log(`the vault would refuse this payment: ${verdict.reason}`, verdict.args);
  } else {
    console.log("paid", await vault.pay({ to, amount, memo }));
  }
}
