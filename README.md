# SALVAGE

Sustainable liquidity and MEV defense on Uniswap v4, built on two real, still-enforceable bodies
of maritime law: **general average** (loss-sharing) and the **law of salvage** (rewarding the
corrector).

> "No cure, no pay."

## The problem

Every concentrated-liquidity AMM leaks value to arbitrageurs correcting its stale price
(loss-versus-rebalancing, LVR), to sandwich bots, and to just-in-time liquidity snipers. Most
designs either tax the bots causing this or let them keep it. SALVAGE takes a third posture:
reward the corrector, fairly, and compensate the LPs who were actually hit — funded by the very
same event.

## Architecture

One v4 hook (`SalvageHook`) per pool owns two internal-library accounting layers and routes into
four independently deployed satellite contracts:

```
SalvageHook (per-pool)
├── ManifestLib     — per-LP tick-range exposure ledger
├── LossMeterLib    — realized-loss measurement + accrual
├── SalvageAuction  — storm-scaled priority bidding ("no cure, no pay")
├── ConvoyBatch     — retail-sized swaps, uniform-price batched
└── GeneralAverageFund — escrow, honest partial-settlement claims
```

Two later-stage additions build on top of the core: `LettersOfMarque` (bonded JIT-liquidity
licensing), `ConvoyPositionAuction` (market-priced payout order), and `FleetSettlement` (bundling
corrections across correlated pools into one bid).

See `SALVAGE_CONTRACT_ARCHITECTURE.md` and the whitepaper for the full design rationale, worked
numeric examples, and honestly-stated open risks.

## Build

```shell
forge build
```

## Test

```shell
forge test
```

The suite includes pure-library unit tests (the LP1/LP2/LP3 partial-overlap fixture for
`ManifestLib`, the seven-block worked payout example for `LossMeterLib`) and a full end-to-end
integration test (`test/SalvageHook.t.sol`) against a real, freshly deployed `PoolManager` — bid,
gated swap, oracle-gap loss measurement, accrual, and a real claim payout, wired together exactly
as the architecture doc's salvage-auction-lane walkthrough describes.

## Deploy

```shell
forge script script/DeploySalvage.s.sol --rpc-url <your_rpc_url> --private-key <your_private_key> --broadcast
```

## Satellite wiring order

Each pool needs its own mined `SalvageHook` address (permission bits must match the deployed
address's low bits — see `HookMiner`) and its satellites registered in this order:

1. Deploy `GeneralAverageFund`, `SalvageAuction` (needs a volatility feed and the fund), `ConvoyBatch`
2. Mine and deploy `SalvageHook` for the target pool key
3. `fund.registerPool(poolId, hook, quoteToken)`
4. `fund.setAuthorizedDepositor(poolId, auction, true)`
5. `auction.registerPool(poolId, hook, quoteToken)`
6. `convoyBatch.registerPool(poolId, key)` — binds the full `PoolKey` so `settleBatch` can call
   `PoolManager.swap()` itself
7. `PoolManager.initialize(key, sqrtPriceX96)`
