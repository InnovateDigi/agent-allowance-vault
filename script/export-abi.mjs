// Writes abi/AgentAllowanceVault.json from the compiled artifact (run `forge build` first).
import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { ROOT, artifact } from "./lib.mjs";
writeFileSync(resolve(ROOT, "abi/AgentAllowanceVault.json"), JSON.stringify(artifact().abi, null, 2) + "\n");
console.log("abi/AgentAllowanceVault.json written");
