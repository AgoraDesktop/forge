# Tabler icons — provenance

**Source:** <https://github.com/tabler/tabler-icons>, `icons/outline/`, taken 2026-10-29.
**Licence:** MIT — see `LICENSE` beside this file (copied verbatim from the repository root).
**Files vendored:** `hammer.svg`, `player-play.svg`, `trash.svg`, `square.svg`, `plus.svg` — the five toolbar verbs.

**Why vendored rather than fetched.** A build must not need the network, and an icon must not be a path that resolves at
run time; these five files are third-party ART, and the project README allows art to be vendored with its provenance
recorded — which is this file.

**How they become pixels.** `tools/embed-glyphs.py` rasterises each one with `rsvg-convert` at 24 and 48 points and writes
a C header of RGBA bytes into the build directory, so the pictures are COMPILED IN: no resource directory, no loader, no
path. The build falls back to the drawn shapes in `src/AGToolbarIcons.m` when `rsvg-convert` is not installed, which keeps
a machine without it building.

**What was not taken:** the rest of the repository. Five outlines and the licence, nothing else.
