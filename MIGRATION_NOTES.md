# MIGRATION_NOTES

Refactor pass for performance + architecture against the v2 canvas
builder. Every step ran a clean `xcodebuild` against
`generic/platform=iOS Simulator` and the new
`ProfileDocumentParentIndexTests` suite was kept green throughout.

This file captures the behavior-preservation checks that were run
mentally for each step and the spots where a deliberate trade-off
was made.

---

## Step 1 — `ProfileDocument.parentIndex`

**Behavior-preservation checks**
- `parent(of:)` returns the same value as the previous linear scan
  for: root children (`nil`), nested children (correct parent),
  unknown IDs (`nil`).
- `subtree(rootedAt:)` is unaffected — it walks `nodes[id]?.childrenIDs`,
  which the index does not gate.
- `insert`, `remove`, `duplicate`, `cloneSubtree`, `bringToFront`,
  `sendBackward` all maintain the index in sync. `bringToFront` /
  `sendBackward` are explicit no-ops on the index because reordering
  within a parent doesn't change parentage.
- `init(from:)` rebuilds the index from `nodes` so legacy decoded
  documents are self-consistent on first read.
- Custom `==` and `hash(into:)` exclude `parentIndex` so two
  content-equal documents always compare and hash equal regardless of
  how their indexes were constructed.
- Codable shape unchanged: `CodingKeys` does not include
  `parentIndex`. The on-disk JSON is byte-identical.
- `Hashable` semantics preserved (used by `Set<ProfileDocument>` and
  SwiftUI diffing).

**Trade-off**
- Kept the linear scan as a fallback gated by `assertionFailure`
  inside `parent(of:)`. Index drift should never happen in normal
  flow, but if it ever does (a legacy decoded doc that mutates a
  node's `childrenIDs` outside the helpers), production self-heals
  silently while debug builds catch it.

**Tests added**
- `CuCuTests/ProfileDocumentTests.swift`: 11 black-box tests covering
  parent / nested-parent / unknown-ID / subtree / remove (incl. root
  child) / duplicate (root + nested) / bringToFront / sendBackward /
  encode-decode roundtrip.

---

## Step 2 — Decompose `ProfileCanvasBuilderView`

**Files added**
- `CuCu/Views/CanvasSheetCoordinator.swift` (`@Observable` class)
- `CuCu/Views/CanvasMutator.swift` (struct)
- `CuCu/Views/CanvasPresetBuilder.swift` (enum namespace)
- `CuCu/Views/CanvasBuilderSheets.swift`
  (`CanvasBuilderSheetsModifier` ViewModifier)

**Behavior-preservation checks**
- All sheet/cover toggling and chain transitions
  (`PageBackground → BackgroundEffects`,
  `Inspector → ContainerBackgroundEffects`) preserved by routing the
  same boolean flags through coordinator intent methods. The
  `onDismiss` chain hand-offs still validate the target
  (`document.nodes[id]?.type == .container`) before promoting.
- Long-press shortcut: same guard set — modal active → no-op,
  selection-via-canvas-tap allowed.
- `selectedID` change handler preserved: collapse selection bar,
  tear down inspector + container effects target on `nil`, drop
  effects sheet when selection moves to a different node.
- Toolbar buttons unchanged (Add, Preview, Publish, overflow menu) —
  same icons, same `disabled` rules, same accessibility labels.
- All mutation methods kept their public-facing semantics: each one
  performs exactly one `store.updateDocument(...)` at the end, just
  like the inline versions.
- Section presets produce the same trees because
  `CanvasPresetBuilder.makeHeroPreset` (and friends) are byte-for-byte
  copies; only their host moved.
- File JSON formats untouched.
- `ProfileCanvasBuilderView.swift` is now 347 lines (was 1312); the
  sheet/cover stack lives in `CanvasBuilderSheets.swift` so the
  view file stays under 350.

**Trade-off**
- `addSectionPreset` and `insertPresetTree` live in
  `CanvasPresetBuilder` per the spec, even though they perform side
  effects (mutate document, set `selectedID`, persist, fire haptic).
  Took dependencies as parameters so the type still has no instance
  state.

---

## Step 3 — Single `DraftStore` lifetime

**Behavior-preservation checks**
- `DraftStore` is created once in `.onAppear` and reused for the
  view's lifetime. The previous computed-getter pattern allocated a
  fresh struct on every read (cheap, but noisy in tight loops like
  `.onChange(of: titleDraft)` and the canvas's per-gesture commit).
- `resolvedStore` falls back to a fresh store if `@State` is still
  `nil` (only possible during the first body evaluation before
  `onAppear` fires). This means there is no observable behavior
  change at first paint either — every persistence call still hits
  the model context.
- Same `context` is read from `@Environment(\.modelContext)` for the
  cached store; the env value is identical to what a per-access
  store would have closed over.

**Trade-off**
- Kept `resolvedStore` as a fallback rather than gating the entire
  body on `if let store`. The latter would have delayed the canvas's
  first paint until after `onAppear` resolves. The fallback is a
  one-time cost during the first render frame.

---

## Step 4 — Remove dead `.onChange(of: selectedID)`

**Behavior-preservation checks**
- The old file had two `.onChange(of: selectedID)` modifiers: one at
  ~line 180 doing real work (collapse bar, tear down inspector) and
  one at ~line 518 that was `_ = newID` — a no-op. The Step 2 body
  rewrite consolidated to one handler that calls
  `sheets.handleSelectionChanged(newID:)` (the live one). The
  no-op handler was dropped during that consolidation.
- Net effect on selection behavior: identical.

---

## Step 5 — Chained sheet hand-off for Publish

**Behavior-preservation checks**
- The old code dismissed the preview cover and then fired
  `DispatchQueue.main.asyncAfter(deadline: .now() + 0.35)` to present
  the publish sheet. Replaced with the same pattern used elsewhere
  in this view: arm `pendingShowPublishSheet` from `onPublish`,
  promote it to `showPublishSheet = true` inside the cover's
  `onDismiss`. Result: the publish sheet appears the moment the
  cover finishes its dismissal animation — no fixed delay, no
  "present from a view that's being dismissed" race.
- Cancel path (`onClose`) doesn't arm the flag, so closing the
  preview without publishing leaves the publish sheet unopened, just
  like before.

**Trade-off**
- Replaced a fixed 350ms delay with an event-driven hand-off. On
  fast devices the publish sheet may appear marginally sooner; the
  user-perceived flow is unchanged but tighter.

---

## Step 6 — Cheaper `NodeRenderSignature`

**Behavior-preservation checks**
- The new signature includes every field that
  `NodeRenderView.apply(node:)` reads: `frame`, `style`, `content`,
  `name`, and `opacity`. Plus the three modification dates so a
  same-path file replace still triggers a re-decode.
- Dropped from the previous "store the whole CanvasNode" form:
  - `childrenIDs` — z-order is reapplied separately via
    `applyZOrder`, and child subviews are managed by `applyNode`
    recursion. Verified by reading every `apply(node:)` override
    (no override touches `childrenIDs`).
  - `id` — immutable once a node is in the document.
  - `type` — type changes go through `expectedType(for:)`, which
    recreates the render view; signature comparison is bypassed in
    that branch.
  - `zIndex` — never read by `apply(node:)`.
- A `#if DEBUG` counter (`CanvasEditorRenderStats.applyCount`)
  increments each time `view.apply(node:)` is called. Idle
  re-applies of an unchanged document produce zero hits — the
  signature compares equal so the call is skipped.

**Trade-off**
- The spec listed only "frame, style, content, name, and the three
  modification dates." Kept `opacity` in the signature because
  `apply(node:)` writes `alpha = CGFloat(node.opacity)`; omitting
  it would have caused a behavior regression on opacity changes.
  The hard constraint of preserving behavior beat strict adherence
  to the spec list.

---

## Step 7 — Batch z-order in `CATransaction`

**Behavior-preservation checks**
- Z-order semantics unchanged: root layer ordering, container
  layer ordering, background-image-to-back, and overlay-to-front
  fire in the same sequence as before.
- `setDisableActions(true)` only suppresses *implicit* CALayer
  animations (the OS's default 0.25s fade/move that
  `bringSubviewToFront` would otherwise schedule for each
  reordered layer). UIView/UIKit animation contexts initiated
  outside this block (e.g., text-node lift on keyboard show) are
  unaffected.
- `bringEffectOverlaysToFront` and `pageView.sendSubviewToBack`
  inside `applyZOrder` benefit from the same coalescing.

---

## Step 8 — LRU(3) for background images

**Behavior-preservation checks**
- Cache lookup: hits with the same `(path, mtime)` return the
  cached image. The previous single-entry tuple did the same.
- Cache miss with same path but different mtime evicts the stale
  entry on insert (`entries.removeAll { $0.path == path }`). The
  previous tuple effectively did the same by overwriting itself.
- Background cleared / load failure: the previous code wiped the
  cache (`cachedBackgroundOriginal = nil`). The LRU does *not*
  wipe — it keeps prior entries warm, which is the win. The
  display still goes blank because `backgroundImageView.image =
  nil` and `isHidden = true` still fire on that branch.
- Async-fetch path uses the same race-guard
  (`document.pageBackgroundImagePath == path`) and inserts into the
  LRU on success.
- Capacity 3: chosen so user can bounce between current + previous
  background without re-decoding either, with one slot of headroom.

**Trade-off**
- Changed the property name from `cachedBackgroundOriginal` to
  `backgroundImageCache` (with type `BackgroundImageLRUCache`) —
  every call site was inside this single file, so the rename is
  contained.

---

## Step 9 — `Equatable` on stable subviews

**Behavior-preservation checks**
- `SelectionBottomBar` / `CollapsedSelectionBar`: equality on
  `(selectedID, document)`. Both views walk
  `document.nodes[selectedID]` plus ancestors / siblings /
  children, so document-level equality is the right grain. Closures
  are not part of equality — they capture references (`mutator`,
  `sheets`) whose internals stay current even when the closure
  value is reused across cached renders.
- `LayersPanelView`: equality on `(selectedID, document)`. Same
  reasoning. `selectedID` is a `@Binding` so the wrapped value is
  compared (Swift's property-wrapper semantics give us the wrapped
  value when accessed by name).
- `CanvasEmptyStateView`: takes only closures. `==` always returns
  `true`, which means SwiftUI never re-evaluates the body once
  mounted. The staggered-reveal animations are driven by `@State`
  flags inside the view; those are preserved across cached
  renders.
- `ProfileDocument`'s custom `==` excludes `parentIndex` so equal
  document content always compares equal regardless of how its
  index was built.

**Trade-off**
- For `SelectionBottomBar` we compare the *entire* document, even
  though the bar only renders a localized subtree around
  `selectedID`. A finer-grained signature (e.g., the selected node
  + its parent + immediate siblings + immediate children) would
  re-render less often, but it would also have to handle every
  edge case of the bar's rendering logic. Document-level equality
  is correct and simple; the fast-path it does deliver is
  "no document mutation since last render," which is the common
  idle case.

---

## Files touched

```
M  CuCu/Components/CanvasEditorView.swift
M  CuCu/Models/ProfileDocument.swift
M  CuCu/Views/CanvasEmptyStateView.swift
M  CuCu/Views/CollapsedSelectionBar.swift
M  CuCu/Views/LayersPanelView.swift
M  CuCu/Views/ProfileCanvasBuilderView.swift
M  CuCu/Views/SelectionBottomBar.swift
A  CuCu/Views/CanvasBuilderSheets.swift
A  CuCu/Views/CanvasMutator.swift
A  CuCu/Views/CanvasPresetBuilder.swift
A  CuCu/Views/CanvasSheetCoordinator.swift
A  CuCuTests/ProfileDocumentTests.swift
A  MIGRATION_NOTES.md
```

No `project.pbxproj` edits were necessary — both targets use
`PBXFileSystemSynchronizedRootGroup`, which auto-includes new
`.swift` files dropped under `CuCu/` and `CuCuTests/`.
