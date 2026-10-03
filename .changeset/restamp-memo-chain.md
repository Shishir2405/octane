---
'octane': patch
---

Fix a context update that could miss a consumer after a value slot switched from a plain render function to a component's element children. The slot keeps the subtree the render function mounted. When the same children came back, the slot skipped its body without knowing that a consumer below it read the context, so the consumer kept the old value.

Memo bails also do less work. A component that bails passes its context reads up to the memo boundaries above it. That walk used to run to the root, and it now stops at the first ancestor with no memo boundary at or above it. In the memo-wall benchmark's one-change list, each bailed row visited 3 ancestors and now visits none.
