# Token Vesting Vault

![tests](https://github.com/<Aiidanaqq>/token-vesting-vault/actions/workflows/test.yml/badge.svg)

A single ERC-20 vault that releases tokens to many beneficiaries (team, investors, advisors) on a **cliff + linear** schedule, with optional owner revocation. Built with Foundry and OpenZeppelin v5, and comes with a small web frontend.

## How vesting works

```
t <  start + cliff     → vested = 0
t >= start + duration  → vested = total
otherwise              → vested = total * (t - start) / duration   (rounded down)
```

`cliff` is counted inside `duration`, and the linear part is measured from `start`, not from the end of the cliff. When the cliff ends, everything accrued up to that point unlocks at once.

**Example: 1,000,000 tokens, 12-month cliff, 48 months total**

| Month | Vested | % | |
|---:|---:|---:|---|
| 0 – 11 | 0 | 0% | cliff |
| 12 | 250,000 | 25% | cliff ends, 12/48 unlocks at once |
| 24 | 500,000 | 50% | linear |
| 36 | 750,000 | 75% | linear |
| 48+ | 1,000,000 | 100% | fully vested |

```
100% |                                   ________
     |                              ____/
 50% |                     ____----
 25% |             |------/
  0% |_____________|
     0            12          24          36   48  months
```

If the owner revokes a revocable schedule, vesting **freezes** at `revokedAt`: the unvested part goes back to the owner right away, and the vested part stays claimable by the beneficiary for as long as they like.

## Contract API

| Function | Who | What |
|---|---|---|
| `createSchedule(beneficiary, amount, start, cliff, duration, revocable)` | owner | Creates a schedule. It can only promise tokens the vault holds and has not promised to anyone else. `start` may be in the past. |
| `release(id)` | anyone | Pays out `releasable(id)`, always **to the beneficiary** (so keepers and bots can trigger payouts). |
| `revoke(id)` | owner | Returns the unvested part to the owner and freezes vesting. |
| `withdrawUnallocated(to)` | owner | Rescues tokens that are not promised (`balance - totalAllocated`). |
| `transferSchedule(id, newBeneficiary)` | beneficiary | Moves a schedule to a new wallet. The released amount is kept. |
| `vestedAmount(id)`, `releasable(id)`, `schedulesOf(addr)`, `unallocated()` | view | |

Reverts use custom errors (`ZeroAddress`, `InsufficientUnallocated`, `NothingToRelease`, …), which cost less gas than revert strings.

## Getting started

```bash
# needs Foundry: https://book.getfoundry.sh/getting-started/installation
./setup.sh            # installs forge-std + OpenZeppelin v5.1.0 into lib/
forge build
forge test            # unit + fuzz + invariant tests
forge coverage --no-match-coverage "(test|script)/"
forge snapshot        # gas report
```

### Coverage

<!-- paste the `forge coverage` summary here after the first run -->
| File | Lines | Statements | Branches | Functions |
|---|---|---|---|---|
| src/VestingVault.sol | _run `forge coverage`_ | | | |

### What is tested

- **Formula:** before start, inside the cliff, exactly at the cliff edge, middle, end, after end; rounding (`1000 / 3`); `cliff == duration`; retroactive start.
- **Release:** repeated releases sum exactly to `total`; a third party can trigger a release but tokens still go to the beneficiary; reverts when there is nothing to release or the id is unknown.
- **Revoke:** before the cliff, in the middle and after the end; vesting stays frozen ten years later; schedules that are non-revocable or already revoked can't be revoked.
- **Accounting:** the owner can't promise more than the vault holds; `totalAllocated` goes down on release and revoke; `withdrawUnallocated` never touches promised tokens.
- **Access control:** strangers can't create, revoke or withdraw.
- **Reentrancy:** an ERC-777-style token with a receive hook tries to re-enter `release`, and the attack fails.
- **Bonus:** `transferSchedule` updates `schedulesOf` correctly and keeps the released amount.
- **Fuzz:** `vestedAmount ≤ total` and never decreases over time; random release checkpoints always pay out exactly `total`; after a revoke, refund + payout == `total`.
- **Invariants** (random sequences of fund / create / release / revoke / transfer / withdraw / warp):
  - `token.balanceOf(vault) >= totalAllocated`
  - `totalAllocated == Σ (cap − released)`, where `cap` is `total`, or the frozen vested amount once revoked
  - every schedule appears in `schedulesOf` exactly once, under its current beneficiary

## Frontend

`frontend/index.html` is a single static page with no build step. It uses ethers v6 from a CDN.

- **Simulator:** works without a wallet. It plots the vesting curve with the same formula as the contract and can show the effect of a revoke.
- **Beneficiary view:** your schedules with a vesting chart, vested / released / releasable amounts, a **Release** button and **Transfer** to a new wallet.
- **Owner panel** (shown only to the owner): fund the vault, create schedules with a live preview, revoke, withdraw unallocated tokens.

Try it locally:

```bash
anvil                                    # terminal 1
forge script script/LocalDemo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
npx serve frontend                       # terminal 2, then open the printed URL
```

Add the Anvil network (chain id 31337, RPC `http://127.0.0.1:8545`) to MetaMask and import Anvil account #0 (owner) or #1 (team beneficiary). Then paste the vault address printed by the script. It can also be hosted for free on GitHub Pages: Settings → Pages → `main` / `frontend`.

## Deploy (Sepolia)

```bash
cp .env.example .env && source .env
forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast --verify
```

## Security model

**Roles**

- **Owner:** creates schedules, revokes *revocable* schedules, withdraws tokens that are **not** promised. The owner can't touch vested tokens, can't revoke irrevocable schedules, and can't withdraw promised tokens.
- **Beneficiary:** receives tokens and can move its schedule to another address.
- **Anyone:** can call `release`, but tokens always go to the beneficiary.

**If the owner is malicious or the owner key is stolen**, the attacker can:
- revoke every *revocable* schedule and take the **unvested** part;
- withdraw all unallocated tokens;
- create schedules for themselves out of unallocated tokens.

The attacker **cannot** take vested tokens, change existing schedules, or touch irrevocable schedules. Mitigations: make the owner a multisig (e.g. Safe) and/or a timelock, mark investor schedules as `revocable = false`, and keep the vault funded only for what it actually promises.

**Risks addressed**

- **Reentrancy:** Checks → Effects → Interactions (state updated before `safeTransfer`) plus `nonReentrant` on every function that moves tokens. Tested with a callback (ERC-777-style) token.
- **Over-promising:** `createSchedule` requires `balance − totalAllocated ≥ amount`. The invariant `balance ≥ totalAllocated` is fuzz-tested.
- **Overflow / precision:** Solidity 0.8 checked math. `Math.mulDiv(total, elapsed, duration)` multiplies before dividing and can't overflow even for huge `total`. Time math is done in `uint256`, so `start + duration` can't overflow `uint64`.
- **Non-standard ERC-20s** (no return value, e.g. USDT): handled by `SafeERC20`.
- **Payouts to the wrong address:** `release` pays `beneficiary`, never `msg.sender`.

**Risks not addressed / known limitations**

- **Fee-on-transfer and rebasing tokens are not supported.** The vault assumes the amount it sends is the amount that arrives and that its balance only changes through transfers. A negative rebase can make `balance < totalAllocated`.
- **Owner centralisation:** revocation is a trust assumption by design (see above).
- Rounding leaves dust in intermediate releases (at most 1 base unit per release); the remainder is paid at the end of the schedule.
- `schedulesOf` is an unbounded array. `transferSchedule` loops over the sender's list, so a beneficiary with thousands of schedules (others can transfer schedules *to* you) could find transfers expensive. Payouts are unaffected.
- `start` is not bounded: the owner could set a start far in the future. This is intended for flexibility.
- Blacklisting tokens (USDC/USDT) could block `release` for a blacklisted beneficiary. The beneficiary can still `transferSchedule` to a clean address.
- Timestamps can be nudged slightly by validators (seconds), which does not matter at month-scale schedules.
- No external audit; this is a portfolio project.

## Project layout

```
src/VestingVault.sol             contract
test/VestingVault.t.sol          unit + fuzz tests
test/VestingVault.invariant.t.sol  invariant tests with a handler
test/mocks/                      MockERC20, ERC-777-style callback token + attacker
script/Deploy.s.sol              deploy for an existing token
script/LocalDemo.s.sol           local demo setup for the frontend
frontend/index.html              web UI
.github/workflows/test.yml       CI: build, test, coverage
```

## License

MIT
