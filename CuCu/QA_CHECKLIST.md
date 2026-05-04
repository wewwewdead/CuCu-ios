# CuCu QA Checklist

- Build tab canvas editing: add, select, drag, resize, reorder, undo/redo, delete.
- Text editing with inline styles: enter inline edit, move cursor, select ranges, apply color/highlight/bold/italic/underline/font, commit, reopen.
- Image node add/replace: add local image, replace same node, verify old bytes do not linger.
- Gallery/lightbox: add multiple images, publish/view, open tile lightbox and full gallery.
- Feed like/unlike: rapidly tap like/unlike, pull to refresh, confirm counts and heart state settle correctly.
- Thread reply/like/delete: like root and replies, post a reply, delete a reply, verify root/reply counts update immediately.
- Explore feed: load latest profiles, scroll pagination, open a profile.
- Publish/view profile: publish current draft, open public viewer, test links, gallery, note modal, and page rendering.
- Instruments memory: run Allocations and Memory Graph while scrolling Explore, opening image-heavy profiles, replacing images, and scrubbing page background blur/vignette.
