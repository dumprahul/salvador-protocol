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
