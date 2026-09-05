# Rendering measurements

Measured locally on 2026-09-05, Apple M5, macOS 27.0 (26A5388g), Apple Swift 6.4
(swiftlang-6.4.0.23.5). Standalone probes compiled with `swiftc -O`, Swift 6 mode,
deployment target `arm64-apple-macos14.0`.

## Partial redraw

Compared the pre-improvement canvas to the current implementation using the same
fixture. Each annotation is a 64-point stroke. Source image dimensions are native
pixels at 100% zoom. Destination bitmap: 1280×800; dirty rectangle: 180×100. Strokes
are spread over the source image, so most do not overlap the dirty rectangle.

Each case has 5 warmup calls and 30 measured `draw(_:)` calls. p95 is the 29th
sorted sample. Timings measure synchronous offscreen drawing work, not input
latency, compositing, GPU completion, capture latency, or end-to-end frame rate.

| Source | Annotations | Before p95 (ms) | After p95 (ms) |
|---|---:|---:|---:|
| 3840×2160 | 10 | 0.157 | 0.097 |
| 3840×2160 | 100 | 0.988 | 0.044 |
| 3840×2160 | 500 | 2.094 | 0.058 |
| 7680×4320 | 10 | 0.108 | 0.063 |
| 7680×4320 | 100 | 0.494 | 0.063 |
| 7680×4320 | 500 | 2.099 | 0.038 |

The improvement comes from retaining completed annotation bounds, invalidating
only changed regions during drags, and skipping nonintersecting annotations.
Full redraws still process every visible annotation. No whole-app speedup or
60-fps guarantee is inferred from this benchmark.

## Memory and export boundaries

- Mosaic cache: at most 64 entries and 16 MiB of accounted decoded image data;
  least recently used entries are evicted individually. This is not a total
  process-memory limit: source images, canvas backing stores, undo history,
  compressed PNGs, and framework allocations are separate.
- Forty distinct mosaics survive a second render without eviction (40 hits,
  40 initial misses). Eviction and cost-limit behavior have regression tests.
- AppKit image compositing remains on the main actor. PNG encoding and saving
  run separately; this improves responsiveness but does not make compositing
  itself asynchronous.
- PNG reuse is invalidated by document or appearance changes. Export locks
  settle pending gestures and text edits before taking the image snapshot.

### Cache policy comparison

A separate unoptimized (`-Onone`) probe compared the original full-clear policy
with LRU using the same 256×256 solid source and 40 distinct small mosaic regions.
After 5 warmup passes, each of 30 samples averaged 100 render passes. These
figures describe sample-average per-pass time, not individual-frame percentiles.

| Cache policy | Median sample average (ms/pass) | p95 sample average (ms/pass) |
|---|---:|---:|
| Clear all at 32 entries | 1.100 | 1.463 |
| LRU, 64 entries / 16 MiB | 0.452 | 0.537 |

Both probes produced identical output (3126-byte PNG, matching checksum).
This tiny-source cache workload is not a large-image export benchmark and
does not establish an overall application speedup.

## Regression evidence

- 41 automated tests passed, including native field-editor typing and undo.
- Fifteen existing annotation PNG export fixtures remain byte-identical.
- Light/dark offscreen editor previews at 900×620 and 1200×780 have no
  ambiguous view layouts.
- Capture permissions and live screen-capture/hotkey interaction were not
  exercised by these offscreen probes; the installed app was not replaced.
