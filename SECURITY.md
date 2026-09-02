# Security

SALVAGE is a paper design with a working reference implementation; every individual mechanism is
proven elsewhere (fee-accounting accumulators, priority auctions, frequent batch auctions), but
this specific combination is untested in production. Honest risks, carried over from the
whitepaper (section XII) and the architecture doc (section 15):

- **Oracle dependency.** LVR measurement depends on `IPriceOracle`; a stale or wrong reference
  price corrupts every downstream payout. `LossMeterLib.measureLoss` currently zeroes the
  measurement on staleness rather than reverting the trade — the alternative (pausing the
  salvage-auction lane entirely) is a real, undecided trade-off.
- **Partial-overlap loss attribution.** `LossMeterLib.accrue` settles loss directly against the
  exact exposed-position list `ManifestLib.getExposedRanges` computes, which is correct under
  partial overlaps — but costs O(exposed positions) per swap rather than the O(1) a full
  `lossGrowthOutside` tick-walk would achieve.
- **Off-chain solver trust.** `ConvoyBatch` currently trusts a single authorized solver's clearing
  price outright (`solverProof` is accepted but not yet verified against a commitment or
  recomputed on-chain) — the roadmap's deliberate "trusted single-solver model" starting point.
  Do not treat batch settlement as verified on-chain until that verification lands.
- **`FleetSettlement` is the highest-risk surface.** Bundling two funds' worth of money through
  one settlement point, across pools with independently-measured gaps, needs the most careful
  testing and audit time of anything in this repo — build order deliberately puts it last.
- **Minimal access control.** Every satellite contract uses a simple deployer-owner for
  registration (`registerPool`, `setAuthorizedDepositor`, `setHook`) rather than a
  governance/timelock design — deliberately out of scope per architecture doc section 15, but not
  yet replaced with anything production-grade.
- **No external audit.** This codebase has not been professionally audited. Do not deploy with
  real funds without one.

## Reporting a vulnerability

Please open a private security advisory on this repository rather than a public issue.
