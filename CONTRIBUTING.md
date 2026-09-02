# Contributing

## Build order

If you're extending the contract set, follow the architecture doc's build order (section 11):

1. `ManifestLib` + `LossMeterLib` — test against the LP1/LP2/LP3 partial-overlap fixture first.
2. `GeneralAverageFund`, fee-stream only — prove the payout math before adding the auction.
3. `SalvageAuction`, fixed-window — "no cure, no pay" as a revert-path test.
4. Storm-scaled `windowLength()` — property-test against synthetic volatility inputs.
5. `ConvoyBatch` — single-solver model first.
6. `LettersOfMarque`, `ConvoyPositionAuction` — once the core is stable.
7. `FleetSettlement` — last, and budget the most audit time here.

## Before opening a PR

```shell
forge fmt
forge build
forge test
```

CI runs all three plus `forge coverage`. New logic needs new tests — see `test/ManifestLib.t.sol`
and `test/LossMeterLib.t.sol` for the pure-library pattern, and `test/SalvageHook.t.sol` for the
full-pool integration pattern (a real `PoolManager`, a mined hook address, no mocks of v4 itself).

## Security

See `SECURITY.md` for known open risks and how to report a vulnerability.
