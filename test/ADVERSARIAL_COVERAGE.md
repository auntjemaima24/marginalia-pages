# Additional adversarial coverage

These tests extend the accepted suite without changing implementation or configuration files.

| File | Coverage |
| --- | --- |
| `HookBoundaries.t.sol` | Caller authentication, fabricated hook data, exact-output restrictions, foreign pools, transactional rollback, text/target/horizon limits, parent validation, observation and seal time boundaries, forfeitures, unauthorized/duplicate claims, sweeping, and bond round trips. The two fuzz properties run 1,000 cases each. |
| `LaunchBinding.t.sol` | First-pool binding, factory and LP-fee restrictions, invalid pairs, the exact five permissions, pinned EIP-1167 bytecode, constructor rehearsal without external code, absence of common admin entry points, LP fee collection and full withdrawal, a noted buy against a manager seeded only with MARG, and exact fee accounting in both currency orders. |
| `HookAccountingInvariant.t.sol` | A real PoolManager with three funded writers and a separate keeper; 128 runs of 80 randomly selected actions. Unexpected handler reverts fail the campaign. |

The accounting handler maintains an independent ledger from deposits, fees, stamps, gifts,
forfeitures, withdrawals, oracle spending, and prize payments. After every generated action it checks:

- IMD claims equal the sum of all outstanding bonds, daily refund pools, and weekly thesis pools.
- Claims also equal cumulative value credited minus cumulative payments; the manager backs them.
- Each bond equals its outstanding, returned, and forfeited portions, with no duplicate payout.
- Note states and child counts agree with the modeled transitions; completed notes never reopen.
- Weekly thesis counts agree with an independent per-author ledger, including closed theses;
  one author cannot exceed three entries, and the allowance resets in a new week.
- Retractions and refund claims update the remaining writer count correctly.
- Keeper rewards are exactly 10% of applicable forfeitures. Refunds are equal remaining shares capped at one stamp.
- Treasury gifts minus drips equal its actual balance. Oracle requests spend their fixed mock price,
  leave no judge balance or approval, and prizes follow the 50/30/20 ranking with unused shares rolled forward.
- The hook retains no MARG claims. All MARG balances in the generated system sum to the unchanged supply.

Actions include buys, quiet and noted sells, calls, theses, timely children, seals, observations,
settlement, retraction, both claims, funding, treasury drips, day/week sweeps, unauthorized claims,
and judging requests, answers, payments, and abandonment. Initial notes and a deterministic handler
scenario prevent an empty-state campaign from being the only exercised behavior.

The revised handler also attempts fourth theses, late children, and premature judging requests.
Each must revert with the specific hook error, without spending the author's funds, creating a
note, or changing the hook's claims. A first judging request waits until week-end plus the full
seven-day child grace; retries retain their three-day timeout. Deterministic sequences exercise
cap refusal before and after thesis closure, next-week admission, late-child refusal followed by
forfeiture, and early judging refusal followed by a paid retry and empty-head rollover.

## Scope and previous finding

The hook, router, treasury, judge, pricer and PoolManager are the repository implementations.
Companion code is installed at the pinned addresses using the existing fixture. IMD and the Intake
are local mocks; the accounting handler uses the fixture's permissive ERC-1271 signer. Signature
authenticity is covered by the existing oracle tests, not by this accounting mock. Live deployment
identity and live mainnet behavior still require the existing `test/fork` suite and `MAINNET_RPC_URL`.

The previously reported late-child defect is fixed in the supplied implementation revision.
`HookReview.t.sol` and `HookBoundaries.t.sol` retain their deadline regressions. The accounting
handler now exercises both timely and overdue attempts against that fix, checking the deadline
after checkpoint maturation so an hour spent preparing history cannot bypass it. Its conservation
assertions and fail-on-revert setting remain in place.

Run `forge build` and `forge test`. The offline selection is
`forge test --no-match-path 'test/fork/*'`.

Revision validation: `forge build` passed; the full `forge test` run reported 249 passing tests,
zero failures, and the mainnet fork suite skipped without `MAINNET_RPC_URL`. The accounting
invariant completed 128 runs / 10,240 calls with zero unexpected handler reverts. Before the
handler revision, both its invariant and its deterministic payout scenario failed on the new
judging grace with `TooEarly`; all original accounting assertions are retained.
