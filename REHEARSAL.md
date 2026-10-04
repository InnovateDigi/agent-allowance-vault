# Rehearsal on a local fork of Arc Testnet (a simulation, not evidence from the public network)

Written by `script/scenario.mjs` on 2026-10-04T22:14:00.470Z. Network: a local fork of Arc Testnet, chain id 5042002.

- Vault: `0x4EDFa003D7e31356490A08f17B252C8A5F53457D` (deployed in `0x0b0e57a2b895e01e739a9d6e242bb9630de05f7f92f0970f0207fe3433c63dba`, block 65524194, 1606709 gas, 0.033740889 USDC)
- Owner: `0x8cfE492Cb7A935B83080026C592e717ab34D6D59`
- Agent (a key made for this run): `0x43cD7851a95f75794fd5eA9e83C7fF96d5E08Ba8`
- Allowed payee: `0xEEF8454f35eEc1bA8B1B0A66B5aC9ABD1d586528`. Address that is not on the list: `0x79ca512169504A7d6FdA49C91E26A3Eb75dEfa79`
- USDC: `0x3600000000000000000000000000000000000000`

## What happened

| # | Who | Action | Expected | Result | Gas | Fee (USDC) | Transaction |
|---|-----|--------|----------|--------|-----|------------|-------------|
| 1 | owner | approve the vault to pull 3 USDC | ok | ok | 55438 | 0.001164198 | `0x045cd8880bf337bfcc8cd41ee997293d673daee5e515ea75e3e1433f8450f043` |
| 2 | owner | deposit 3 USDC | ok | ok | 54552 | 0.001145592 | `0xd5f4214c1779df486824c2f32eba15c08ea7bb8a1d4f7cd76996be71bef6843d` |
| 3 | owner | fund 2 USDC more with a plain USDC transfer | ok | ok | 48950 | 0.00102795 | `0x1b479326d593a24b26b004747679608887e402630ca59c5ffe35b33e5c8b7ac4` |
| 4 | owner | set policy: 1 per payment, 2.5 per rolling day, one allowed payee, expires in 1 hour | ok | ok | 97597 | 0.002049537 | `0xa099dbda1a04322a759a09dda7dcb20a45d6087b80c502b8f910bcca9b044672` |
| 5 | owner | send the agent 0.1 USDC for gas | ok | ok | 21000 | 0.000441 | `0xf06fcb115096f3ea1e00d6aa3e11ba8bfcae2445ef2a89486f8c93ffbffaf4c6` |
| 6 | agent | pay 1 USDC to the allowed payee, memo "invoice-001" (payment #1) | ok | ok | 222979 | 0.004682559 | `0x095b44007e3fbd50b3e62af2c2fb5386daec5d76ea7d991748c1995de7627c2a` |
| 7 | agent | pay 1.5 USDC (over the per-payment cap) | refused: ExceedsPerPaymentCap | reverted: ExceedsPerPaymentCap | 34563 | 0.000725823 | `0x1d9c871550ec3e80cc9deb98070353c2db410e9d22187f30e516ad92c76f1dd7` |
| 8 | agent | pay 0.5 USDC to an address that is not on the list | refused: PayeeNotAllowed | reverted: PayeeNotAllowed | 36931 | 0.000775551 | `0xa4b1e4aff6728656998c010e07af50d6969dbb381f8a423e5ef9d9f9d50c57b9` |
| 9 | agent | pay 1 USDC to the allowed payee, memo "invoice-002" (payment #2) | ok | ok | 146679 | 0.003080259 | `0x979736153f0063c5f51c533c75412466a60810358402663915ac0336f9fdc0fc` |
| 10 | agent | pay 1 USDC (would pass the daily cap; 0.5 left) | refused: ExceedsDailyCap | reverted: ExceedsDailyCap | 99083 | 0.002080743 | `0x54a946dc080770dbebdf6b0d29b79235abb473c865e4515a414cb6170ac78650` |
| 11 | agent | pay 0.5 USDC to the allowed payee, memo "invoice-003", sent through Arc's Memo contract with the public memo "order 3, paid by the agent" (payment #3) | ok | ok | 165764 | 0.003481044 | `0xba8bea0e215dc4c6534e00bce08c0ec8b5f27dd3db93e09d79e22a365671bdcd` |
| 12 | agent | pay 0.000001 USDC (daily cap fully used) | refused: ExceedsDailyCap | reverted: ExceedsDailyCap | 98964 | 0.002078244 | `0xe530409786085c8d1b905ffc18609fcfcd7140194faba478ba2199e4123d9123` |
| 13 | agent | withdraw everything to itself | refused: NotOwner | reverted: NotOwner | 22080 | 0.00046368 | `0x520e3a9558b3796b1a3402c4582ec9fba55814b5351348f8895ebbeded17cf35` |
| 14 | agent | give itself a bigger policy | refused: NotOwner | reverted: NotOwner | 24330 | 0.00051093 | `0x4659827b5c0d94a3b43fbeca52dec5f80cf798c55bd7da3f342d814425e42d90` |
| 15 | agent | pause the vault | refused: NotOwner | reverted: NotOwner | 21377 | 0.000448917 | `0xcd9ed8c23f0ee0b3f32cd7d97f68373cd71b1d720bbe549808be19f71db5259e` |
| 16 | owner | pause | ok | ok | 44345 | 0.000931245 | `0xef48e01d5b8be0117c03a21679eb84e5d91476a6227a0678d9ca961b623c3a7b` |
| 17 | agent | pay 0.1 USDC while paused | refused: VaultPaused | reverted: VaultPaused | 29689 | 0.000623469 | `0x816644f822fcfbcbc76e3465f2f9339ef4c57bd3382eec6e5f66dcad96931620` |
| 18 | owner | unpause | ok | ok | 22444 | 0.000471324 | `0xe0e7ce9b06eea0e9dceceb0bba72b3da13d83218a82f40fd71352d6c457c3a1d` |
| 19 | owner | set policy again: daily cap 10 USDC, expires in 20 seconds | ok | ok | 63397 | 0.001331337 | `0x7c6255c744bceac8c46d1974f87c2bf0932a1c32e8136b9db44d1a2405ed7912` |
| 20 | agent | pay 0.1 USDC after the policy expired | refused: PolicyExpired | reverted: PolicyExpired | 34385 | 0.000722085 | `0x119ac4d24280eb5815898cacba5522d732428c298b48bcee6e97168925e00557` |
| 21 | owner | set a fresh one-hour policy | ok | ok | 60597 | 0.001272537 | `0x8e7a87bdb2b7b9b80f3e823eeb818b4545dcb615a83d980fdc76abbfe3e8d370` |
| 22 | owner | revoke the agent | ok | ok | 28483 | 0.000598143 | `0x3eb79ad23f6690abe7427d1d4e8fbc8777a14b2306d5805e6926025db0c85e87` |
| 23 | agent | pay 0.1 USDC after being revoked | refused: NoPolicy | reverted: NoPolicy | 34281 | 0.000719901 | `0xbfeb6d5f5d0896cfb326d61a11c7b8e2509e1ad4702349083f69d9bd9c3502f1` |
| 24 | owner | withdraw everything (2.5 USDC) | ok | ok | 57152 | 0.001200192 | `0x279d5c908e14e65e9d155b4403a28c6fe8700fa774ecd27c3634bdbf5ec06b61` |
| 25 | agent | return 0.077842795 USDC of unused gas to the owner | ok | ok | 21000 | 0.000441 | `0x577ad2d335860efa1080531cf7c1eed1d6a6d1945a84bf7457c977fc40b40e1e` |

Every refusal above is a transaction that reverted on chain; the reason was read by simulating the same call first.

## The audit trail, read back from the Payment events

| Payment | Payee | Amount (USDC) | Memo hash | Block | Transaction |
|---------|-------|---------------|-----------|-------|-------------|
| 1 | `0xEEF8454f35eEc1bA8B1B0A66B5aC9ABD1d586528` | 1 | `0xdbdd9a56ffe3f2a961ae70739d3721a89d1494641310a7fc7b8db6d0836f89bb` | 65524200 | `0x095b44007e3fbd50b3e62af2c2fb5386daec5d76ea7d991748c1995de7627c2a` |
| 2 | `0xEEF8454f35eEc1bA8B1B0A66B5aC9ABD1d586528` | 1 | `0xa3047dab5ba309c6c5bc4d189b7cd3997af1f7885218c913c6ff0f89e843d6a0` | 65524203 | `0x979736153f0063c5f51c533c75412466a60810358402663915ac0336f9fdc0fc` |
| 3 | `0xEEF8454f35eEc1bA8B1B0A66B5aC9ABD1d586528` | 0.5 | `0xa07ee95d4da4d4b3bb46e3c4972d23b9d61ca34887da156baa7db5383e1750ec` | 65524205 | `0xba8bea0e215dc4c6534e00bce08c0ec8b5f27dd3db93e09d79e22a365671bdcd` |

The memo hashes are keccak256 of the texts "invoice-001", "invoice-002" and "invoice-003": `0xdbdd9a56ffe3f2a9...`, `0xa3047dab5ba309c6...`, `0xa07ee95d4da4d4b3...`.

## Final checks (all enforced by the script)

- Payments found in the events: 3; their sum 2.5 USDC equals `totalPaidBy(agent)` = 2.5 USDC, which is exactly the daily cap.
- The payee received 2.5 USDC. The vault ended at 0 USDC.
- Owner USDC before 19.966259, after 17.432468 (the difference is the payments, the fees and gas left unspent).
- Refused attempts: 10, each with the expected reason.

## Cost

- This run: 25 transactions, 1546060 gas, 0.03246726 USDC in fees. Deployment: 1606709 gas, 0.033740889 USDC.
- Arc mainnet gas price read when this was written: 20.000 gwei. At that price the deployment costs 0.0321 USDC and this scenario 0.0309 USDC: 0.0631 USDC in total.
- Worst case allowed by the protocol (base fee ceiling 20,000 gwei): 63.0554 USDC for both.
