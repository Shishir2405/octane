# Root transaction setup

## Contract and scope

Every root commit wave runs inside a root transaction so that a later raw
thenable or uncaught suspension can restore what the wave already wrote
([#833](https://github.com/octanejs/octane/pull/833)). Opening one allocated a
transaction record, its undo log and snapshot map, an `OffscreenCapture` with
eight arrays (an effects array holding three phase arrays, events, event
actions, refs, stores), a saved-globals frame per window, and a fresh list of
pending transactions per commit, even for a one-text update.

The change keeps rollback, holds, retries, effects, refs and cleanup exactly as
they were:

- A committed wave empties its transaction and keeps it as the same root's
  `spareTransaction`. The next wave takes it with fresh created-Block and
  bag-window stamps, so the previous wave's Blocks and bag snapshots never look
  current.
- A wave is not recycled when anything can still reach its transaction, log or
  capture after the commit: a deferred-layout capture or a preserved Hydrate
  activation (`retained`), a hydration attempt, a native transition admission,
  binding-lease presentation receipts, a staged commit, or a root window that
  is still open. Those waves take a fresh shell, as before. Native reads
  qualify, because accepting the capture releases its candidates and
  publication receipts key the queued entries rather than the arrays.
- Windows nest strictly, so the globals each one replaces are saved on one
  shared stack instead of a frame object.
- The pending-transaction list is swapped with a spare instead of reallocated.
- Recycled queues are emptied by popping, which keeps a short queue's backing
  store; a queue longer than 64 entries is released instead.

Focus capture is unchanged. It predates #833, React performs the same
`activeElement` read in `prepareForCommit`, and the only exact precondition for
skipping it is that read itself.

## Measurement

`setup.mjs` builds a production fixture twice. The observed runtime wraps every
object, array, `new` and closure expression in `beginRootRender`,
`endRootRender`, `createOffscreenCapture`, `commitRootRenders` and
`recycleRootTransaction`, then counts those reached over 64 commits after a
16-commit warmup. Four workloads cover a state update (the memo-wall
`parent_rerender_equal_A` shape), a public `root.render` request, commits that
re-run a layout and a passive effect and swap a callback ref, and the same
commits after a boundaryless root hold and its retry. Clean and observed
bundles must agree on text, row identity, the accepted event handler, effect
and cleanup counts, and live ref attachments.

```sh
node benchmarks/root-transactions/setup.mjs /path/to/baseline/runtime.ts
node benchmarks/root-transactions/setup.mjs
```

Node 24.18.0, baseline `950ef0b0bd`, identical fixture and build settings:

| Workload | Commits | Baseline setup allocations | Candidate |
| --- | ---: | ---: | ---: |
| State update | 64 | 896 | 0 |
| `root.render` request | 64 | 896 | 0 |
| Effects and ref swap | 64 | 896 | 0 |
| After a root hold and retry | 64 | 896 | 0 |

These count reached allocation expressions, not heap bytes. As a diagnostic
only, an unminified happy-dom probe of a one-text state update measured V8 heap
growth of about 3,198 bytes per commit on the baseline and 1,966 on the
candidate, with no collection inside the window.

TIMING_PLACEHOLDER

## Size

SIZE_PLACEHOLDER

## Limitations

- The ratio guards pin allocation sites, not latency; timing comes only from
  the same-runner CI comparison above.
- Happy DOM checks the public contract; it does not measure browser layout,
  paint or garbage-collection cost.
- A root keeps one emptied shell between updates. It is released with the
  root; a queue that grew past 64 entries is not retained.
