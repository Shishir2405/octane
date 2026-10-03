---
'octane': patch
---

Mount a text hole that may receive a signal handle with one runtime call.

A `{props.label as string}` hole can receive a signal handle, so its compiled
mount checked the value's type at every site before calling either the text
writer or the signal binding. The new internal `mountSignalText` makes that
check, and each site now emits a single call. Updates are unchanged.

The 16-file codegen corpus compiles 504 B smaller gzipped. The runtime gains
about 100 minified bytes and each hole sheds about 75, so a bundle with one such
hole grows by 25 raw bytes and one with two or more shrinks. Rendering,
hydration, and signal behavior are unchanged.
