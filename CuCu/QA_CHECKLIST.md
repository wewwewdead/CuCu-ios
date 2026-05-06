# CuCu QA Checklist

## Existing flows (regression)
- Build tab canvas editing: add, select, drag, resize, reorder, undo/redo, delete.
- Text editing with inline styles: enter inline edit, move cursor, select ranges, apply color/highlight/bold/italic/underline/font, commit, reopen.
- Image node add/replace: add local image, replace same node, verify old bytes do not linger.
- Gallery/lightbox: add multiple images, publish/view, open tile lightbox and full gallery.
- Feed like/unlike: rapidly tap like/unlike, pull to refresh, confirm counts and heart state settle correctly.
- Thread reply/like/delete: like root and replies, post a reply, delete a reply, verify root/reply counts update immediately.
- Explore feed: load latest profiles, scroll pagination, open a profile.
- Publish/view profile: publish current draft, open public viewer, test links, gallery, note modal, and page rendering.

## Golden Path
- Fresh install → choose template → Quick Edit → publish → share.
- Explore → Remix → Build opens the copied style → optional Quick Edit → publish → share.
- Remix each template type.
- Remix signed out.
- Remix signed in.
- Remix with existing non-empty draft.
- Remix old/freeform profile.
- Quick Edit all fields.
- Quick Edit save → relaunch → data persists.
- Quick Edit publish → public profile reflects changes.
- Publish success → copy link/share/view profile all work.
- Share card fallback works if image render fails.
- Account switching does not leak drafts, likes, avatars, or remix state.

## Template-first onboarding (Phase 1)
- Fresh install (or `defaults delete` of `cucu.hasPickedTemplate`) lands on the Template Picker, not the bare canvas.
- Pick each of the six templates (K-Pop / Anime Intro / Soft Diary / MySpace Room / Writer Page / Gamer Card); verify the seeded canvas matches the preview swatch's background hex, has hero copy, and contains the expected section cards.
- "Start from a blank page" dismisses the picker and leaves the structured-profile hero in place; relaunch the app and confirm the picker does NOT reappear.
- Existing user with non-empty draft does NOT see the picker on app launch.
- Sign out → sign in as a different account: each account picks its own template; flag is per-device, drafts stay user-scoped.

## Quick Edit (Phase 2)
- Tap the wand toolbar item; the Quick Edit sheet appears with the hero copy / handle / bio populated from the current document.
- Edit Display name, status, short bio, About, Favorites, Links, Music, and Notes; tap Save; verify the canvas reflects the grouped change.
- Replace avatar via Photos picker; verify the previous bytes are gone (turn off the simulator and back on, or kill the app and relaunch — image is the new one).
- "Edit on canvas" dismisses the sheet and leaves the canvas editor open.
- "Publish" dismisses Quick Edit and opens the Publish sheet with the latest saved form values.
- Quick Edit with no avatar set: placeholder `person.fill` shows; pick → real photo replaces placeholder.
- Quick Edit updates About/Favorites/Links/Music on each template type (K-Pop / Anime Intro / Soft Diary / MySpace Room / Writer Page / Gamer Card), adding a missing Links or Music section only after the user enters values.
- Quick Edit changes persist after force quit and relaunch.
- Quick Edit then Publish shows the updated public profile.
- Quick Edit then Share Card shows updated name/avatar/about-style info.
- Old profiles/templates with missing section cards do not crash.

## Publish success (Phase 3)
- Successful publish surfaces "Your CuCu is live" headline with sparkle badge animation, profile preview card (avatar + display name + handle + link), and ordered actions (Share / View / Copy / Done).
- Share button presents the existing ProfileShareSheet.
- Copy button copies the path; "Link copied" alert appears.
- View button pushes PublishedProfileView onto the same nav stack.
- Done dismisses the sheet.
- Failure path still surfaces "Publish failed" with the original message + Try Again / Cancel.

## Share card export (Phase 4)
- Share from PublishedProfileView's toolbar; the share card image generates and the system share sheet opens with the card image + profile path.
- Share from publish-success screen — same.
- Image-heavy profile (≥20 gallery images) does not OOM during share; preload caps concurrent downloads at 6.
- 4s preload timeout still fires when an image is genuinely missing — share completes (with that image as a placeholder) rather than hanging.

## Remix / "Use this style" (Phase 5)
- Tap the visible "Remix this style" / toolbar "Use this style" action on someone else's PublishedProfileView.
  - Signed-out + no local drafts: a new draft is inserted and the app switches to Build with the remix loaded.
  - Signed-in + only the auto-created pristine draft: same path — direct apply, no confirm.
  - Signed-in + non-empty draft: confirmation dialog "Remix this style?" appears and says a new draft will be created. Cancel keeps the existing draft untouched. Confirm creates a NEW draft (the existing one is preserved on disk).
- After remix:
  - Build opens the newly created draft and shows "Style copied — make it yours." Quick Edit does not open automatically.
  - If draft creation fails, the alert explains that nothing changed and offers Try Again.
  - Old/freeform/custom profiles still create a safe remix; Quick Edit explains that finer control may need canvas editing.
  - Hero copy is back to the structuredProfileBlank defaults ("Display Name" / "@username" / "Short bio…").
  - Avatar is empty (no remote URL inherited).
  - About text, favorites, freeform notes, link labels/URLs, music links, and remote URLs are stripped.
  - Page background hex / blur / vignette / pattern preserved.
  - Container backgrounds without photos preserved; container backgrounds with photos cleared.
  - Gallery remote image arrays empty; image nodes have no remote/local user path; link URLs blank with "your link" placeholder; note bodies replaced.
  - Bundled decorative image references (`bundled:...`) are preserved.
  - Layout, fonts, colors, divider styles, icon styles preserved.
- Remix toolbar button is hidden on the user's own profile.
- Account switch on the same device does not surface another account's draft as a "non-empty" warning.
- Remix from a signed-out user can Quick Edit locally; Publish still prompts sign-in through the existing Publish flow.
- Remix from a signed-in user scopes the new draft to that account.
- Remix when the user already has a draft never overwrites the current draft silently.

## Vibe / category metadata (Phase 6)
- Run `Supabase/migration_add_profile_category.sql` in the project's Supabase SQL editor before testing this section.
- Open Publish sheet → vibe picker scrolls horizontally; "None" is leading and selected by default; tap a vibe; tap Publish.
- Re-open the published profile via Explore; the row's category column has the rawValue (`anime`, `kpop`, etc).
- Re-publish without changing the vibe; the previous category remains in place (encoder uses encodeIfPresent).
- Open a pre-migration row's profile; viewer renders with no category (decode tolerant of nil).

## Explore cleanup (Phase 7)
- Open Explore tab — only "Top this week" and "Freshly published" segments exist. No "Online" anywhere.
- Top styles this week carousel header reads "Top styles this week".
- Empty state on Suggested with no rows reads "Find your next vibe".
- Tap each vibe pill ("All" / Anime / K-Pop / Soft Diary / MySpace / Writer / Gamer / Art / Music / Student) — feed re-fetches and only shows profiles tagged with that vibe (or all when "All" is selected).
- Empty state on a vibe with no rows reads "No <Vibe> profiles yet" with the "Try another vibe…" subtitle.
- Tap a card → public profile opens; remix button is in the toolbar.
- Search across vibes still works (search ignores category filter in v1).

## Performance / Instruments
- Allocations + Memory Graph during:
  - Scrolling Explore (paginated load).
  - Opening image-heavy profiles (≥20 gallery images).
  - Generating share cards on those profiles back-to-back.
  - Remixing a heavy profile (transformer is sync — should be tens-of-ms even for 200 nodes).
- Memory peak during share-card preload should be visibly lower than pre-throttle: max ~6 inflight image decodes instead of N.
- Account switching does not leak the previous user's drafts/likes/avatar into the new user's view.

## Edge cases
- Reset profile (Build → Menu → Reset Profile) wipes the canvas and clears `hasPickedTemplate=false` is NOT necessary — the user already crossed onboarding once and the hero seeds back into structuredProfileBlank shape.
- Network offline during template pick: works (templates are bundled, no network).
- Network offline during remix: works for unsigned-in users (anonymous draft); signed-in users get the local draft inserted regardless of network.
- Pre-migration published rows remain visible on Explore under "All" and category-specific queries return empty — no decode crashes.
