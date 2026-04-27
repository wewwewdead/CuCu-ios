# CuCu Fixed Page Migration Notes

## Transitional JSON Shape

`ProfileDocument` now writes both the new `pages` array and the legacy top-level page fields. The legacy fields mirror page 1 so older app builds and viewers can still render published profiles while clients roll forward.

## Viewer Pagination

The public viewer uses threshold-loaded infinite scroll. It mounts page 1 first, then mounts the next page only when the visitor scrolls near the bottom sentinel, delaying remote image requests for later pages until the visitor approaches them.

## Page Deletion

Page 1 cannot be deleted. It remains the stable fallback page for old clients that read only the legacy top-level fields. Additional pages can be deleted, and deleting a page removes its descendant nodes.

## Legacy Tall Pages

Old documents without `pages` decode into a single page using the legacy height and root children. The migration does not auto-split tall legacy canvases; the first page preserves its authored height exactly.
