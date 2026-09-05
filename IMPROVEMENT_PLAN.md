# Editor improvement plan

## Current delivery — implemented

- Native light/dark editor: compact action header, vertical tool rail, contextual inspector, zoom/status footer.
- Re-edit annotation colors/widths and existing text; resize shapes, blur, and redaction using handles. Preserve undo/redo.
- Opaque redaction, drawn last in previews and exports so overlapping blur cannot reveal the original image.
- Open local image files and drag images into the editor.
- Invalidate changed regions and skip off-region annotations using cached screen-space bounds.
- Bounded mosaic LRU cache; measure cache churn and draw costs before/after.
- Responsive PNG export: retain AppKit drawing on the main actor, encode an immutable image off the main actor, reuse unchanged export results.

## Validation

- Existing geometry and rendering regressions; new editing, redaction, cache, and input tests.
- Compare legacy annotation output; opaque redaction must survive overlapping annotations.
- Inspect 900×620 and larger editor layouts in light and dark appearances.
- Record benchmark fixture, hardware/runtime, sample counts and timing boundary; do not claim end-to-end frame rates from offscreen drawing measurements.
- Keep capture permissions and app deployment separate from code validation.

Current results: 41 automated tests, 15 byte-identical legacy PNG exports, and
four light/dark layout previews with no ambiguity. Local drawing measurements
and their limits are recorded in [PERFORMANCE.md](PERFORMANCE.md).

## Subsequent deliveries

- Nondestructive crop with undo and coordinate remapping.
- Window capture and delay options using ScreenCaptureKit.
- On-device text recognition and opt-in session restoration.
- Change-command history only if memory profiles justify replacing array snapshots.
