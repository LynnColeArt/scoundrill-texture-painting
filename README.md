# Scoundrill texture painting

Reusable Zig libraries for rendering and authoring textures on 3D surfaces.
**hamudi-1 is intended to become Scoundrill's default viewport rendering engine.**
The painting libraries serve skin and makeup, building and object textures, and
detailing workflows.

The unchanged Rust TextureCraft build established feasibility. It remains a
pinned behavior reference for a complete Zig recreation of the selected systems,
rather than a runtime dependency of the finished libraries.

Status: extraction brief, dependency inventory, baseline evidence index and
performance plan recorded. No Zig renderer or painting implementation exists in
this repository yet. Scoundrill has not switched renderers.

- [Product and acceptance brief](docs/BRIEF.md)
- [Library boundaries and upstream inventory](docs/ARCHITECTURE.md)
- [Movie Maker renderer behavior and acceptance map](docs/RENDERER-BEHAVIOR.md)
- [Performance plan](docs/PERFORMANCE.md)
- [Implementation sequence](docs/ROADMAP.md)
- [Reference provenance](docs/PROVENANCE.md)

This is the permanent project checkout. Temporary references and worktrees belong
under /tmp or ~/work-trees and must be removed when their work is finished.
