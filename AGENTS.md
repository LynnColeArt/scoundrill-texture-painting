# Contributor instructions

Read docs/BRIEF.md, docs/ARCHITECTURE.md, docs/PROVENANCE.md and docs/ROADMAP.md
before implementation. Target Zig 0.16.0 initially, matching Scoundrill.
Use docs/RENDERER-BEHAVIOR.md and its pinned Movie Maker evidence as the initial
renderer behavior contract. Extend coverage where missing rather than restarting
the already completed feasibility experiments.

Build reusable libraries. Scoundrill integration, UI, file dialogs and application
state belong in adapters. Keep rendering independent of painting history, command
registries and editor sessions. All required production host logic must be
recreated in Zig; an unchanged Rust oracle is development tooling only.

This is a source-informed extraction and recreation, not a clean-room claim.
Preserve upstream licenses, notices, pinned revisions, source hashes, fixtures
and original results for adapted code and shaders. Record references before
adapting them. Do not consult rust-anything implementation code, tests or skills.

Establish behavior before optimization. Never regenerate goldens to conceal a
mismatch. Record intentional corrections separately from preserved behavior.
Keep unimplemented scope explicit. Do not claim support from empty modules.

Use explicit allocator and ownership contracts, bounded work and buffers,
cancellation and checked Debug/ReleaseSafe validation. Meaningful tests should
exercise original/candidate behavior, allocation failures and the consumer
workflow. Add runnable checks with the first implementation; none exist yet.

Benchmark the same scene, quality, hardware and workload on both implementations.
Report frame distributions, latency and memory as well as throughput. Keep
readback-free viewport measurements separate from headless capture.
A language change alone does not establish a speedup.

Use /tmp or ~/work-trees for temporary checkouts and worktrees, remove them when
finished, and commit completed work. Preserve unrelated Scoundrill work.
