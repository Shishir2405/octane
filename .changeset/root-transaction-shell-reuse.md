---
'octane': patch
---

Reuse a root's committed render transaction for its next update instead of allocating a new one per commit.

Every root commit opens a transaction so a later suspension can restore what
the commit had already written. Setting one up allocated a record, an undo
log, a snapshot map, a capture with eight queues, a saved frame and a list of
pending transactions, even for a one-text update. A committed transaction is
now emptied and kept for the same root's next update, the saved globals share
one stack, and the pending list is reused, so an ordinary update allocates none
of them. Hydration attempts, staged and deferred commits, native transition
admissions and binding-lease presentations still take a fresh transaction.
Rollback, holds, effects, refs and cleanup behave as before.
