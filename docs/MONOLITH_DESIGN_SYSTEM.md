# MONOLITH design system

## Authority and cutover boundary

This document defines the approved visual and experience requirements for the production application. The retired design gallery and study are not required to implement or verify this system. Presentation requirements do not authorize provider work.

The approved rebrand is the full application identity: MONOLITH in prose/UI, `:monolith` for OTP/configuration, `Monolith`/`MonolithWeb` modules, `monolith` project-owned libraries, paths, commands, storage/keychain names and tooling, and `MONOLITH_*` environment variables. Third-party names remain upstream-owned. All production application routes are selected for this presentation; there is no phase-1-only browser identity exception.

There are no users and existing local data is replaceable. This pre-user cutover requires no data-preservation migration, credential transfer, backward compatibility or legacy aliases. Preparing enforcement artifacts does not rename application source or perform storage operations. Ordinary security and authorization requirements still apply to actual effects; preserve authentication, safe requested destinations, account/generation fences, durable-work ownership and provider consent.

This document is the single presentation authority for the production application. [UI_CONTRACT.md](UI_CONTRACT.md) retains operational, security, route and lifecycle requirements without a second visual system. Complete all callers within an assigned change; do not add compatibility aliases, duplicate themes or a second component system. Selection of the whole UI does not itself establish implementation or runtime acceptance evidence.

### Source map

Current production owners supply implementation evidence:

| Decision | Primary owner |
| --- | --- |
| Public values and usage | `assets/css/themes.css` |
| Mark and lockups | `lib/monolith_web/components/layouts.ex` |
| Identity choreography | `assets/js/hooks/brand_reveal.js`; `assets/css/onboarding.css` |
| Signals and motion | `lib/monolith_web/components/status_components.ex`; `assets/css/status.css` |
| Working plane, shell and responsive composition | `assets/css/app.css`; `lib/monolith_web/components/layouts.ex` |
| Product/security behavior | `docs/UI_CONTRACT.md`; relevant Gmail, Calendar, development and stage guides |

Read actual consuming components, selectors and hooks to establish current behavior; this document defines their acceptance requirements, not a claim that every implementation passes.

## Core rules

### M01 — One working plane, not a dashboard

Scenery supplies atmosphere and the app-wide contrast treatment. All content components use transparent working planes with open left/right edges, horizontal boundaries and quieter internal dividers. No persistent charcoal content fills, component-level backdrop blur, nested floating content cards, decorative card shadows/content gradients or colored status-panel fills. Keep text fully opaque; changing surface opacity must not dim its descendants.

`--card-surface: transparent` is the shared resting content surface across Home, Workspaces, Connections, GitHub activity, Scenes, Settings, onboarding, setup and public error content. Outer boundaries use 1px `--line` at 23% opacity; inner separators use 1px `--line-interior` at 12%. Adjoining sections avoid doubled rules. Hovered interactive rows/tiles use light white frosting (`--surface: rgba(255,255,255,.08)`), never charcoal or component blur. Filled buttons and inputs use the same opaque off-white ground as current navigation (`#f3f1e9`) with dark text; filled-button hover is white. Quiet/text/destructive actions keep their semantic distinction. Transient menus/notices and native dialogs use the same light ground with readable dark text and locally appropriate signal colors. Native modal elevation is not permission to add content-card shadows.

This app-wide addendum extends the existing transparent Home and Gmail treatment to every component. Preserve the shared scenery blur/shade, opaque text, horizontal dividers, visible keyboard focus and system-color backgrounds in forced colors. Only hovered interactive rows/tiles gain a transient surface; neighboring content stays transparent. The Gmail reader header stays in normal flow so scrolled correspondence cannot overlap transparent sticky controls.

### M02 — One foundation, one owner per decision

`assets/css/themes.css` owns the annotated shared foundation, loaded before consumers. Reuse shared controls and semantic tokens before adding variants. Integrate with existing token/component owners; do not maintain divergent copies of the same public decision or add alternate theme systems.

Add a public token only for a reusable decision with a real consumer and usage comment, one declaration per line under an annotated group. Keep composition in layout owners and examples in specimens. Brand ground/size/ tracking, signal size/motion and measurement knobs remain local. Keep literal media conditions beside the affected layout; CSS custom properties are not usable media-query thresholds. Generic transition tokens do not own artwork choreography.

### M03 — Fixed identity, fluid surrounding layout

Use the authored MONOLITH mark, not a redrawn approximation or separately named symbol. Outline and Solid are treatments of one identity. Light/dark plates prove reproduction; they do not create interface themes. The working interface uses transparent planes over shaded scenery, white frosting on hover and light controls. Full unlock uses Outline; the compact sidebar uses Solid with negative-space creases cutting through its ground. Its button has no pointer-hover outline/border, but retains visible keyboard focus. Do not use the mark as a status/loading icon.

| Preset | Mark | Wordmark | Tracking | Gap |
| --- | --- | --- | --- | --- |
| Display, stacked | 104px | 24px | .22em | 24px |
| Compact, horizontal | 32px | 15px | .16em | 10px from the 44px button target edge |

Both use locally hosted Space Grotesk, weight 500, line-height 1.2. Display clear space is at least 16px. Preserve the 104×104 SVG safe field, 2.4-unit outline, square caps and miter joins. Standalone icon proofs are 24/32/48px, not new lockups. Reflow containers; never shrink/wrap the wordmark, change its tracking per page, stretch geometry, synthesize weight, shade faces or add decorative containers. Ordinary product-name mentions remain normal reading text.

### M04 — Typography serves reading

Local Space Grotesk is the reading/UI face; system monospace serves registers and technical metadata. Body is 16px/1.55, supporting text 13px. Normal prose uses sentence case and normal tracking; uppercase/tracked registers and the wordmark are deliberate exceptions.

Metric labels default to Space Grotesk 400 at 13px/1.55, uppercase with normal tracking.
Use the shared `metric-label` primitive and an 8px label/value gap when stacked above counts.
Gmail and GitHub metrics share this default; section registers and technical metadata retain their own presets.

Display headings use the fluid 42–82px preset; section registers use 12px/1.6 with .1em tracking; account titles use 23px/1.25 with -.03em tracking. These are not brand presets. Mail is 18px/1.8, reducing to 17px/1.75 at ≤760px, with a 68ch reading measure and 76ch outer reader. Introductory copy is bounded at 58ch. Long addresses, subjects, URLs and errors wrap without losing identity or causing page-level horizontal scrolling; scoped table overflow is allowed.

Home email metrics use the shared GitHub `metric-label` style above counts: **UNREAD** and **LAST 24H**. Accessible descriptions retain unread inbox-conversation and rolling received-time meanings. Home omits per-account connection-warning copy; workspace readouts retain it, and connection recovery remains available.

Home Calendar keeps the concise **No events today** heading without repeating it in supporting copy. Calendar-selection guidance and workspace agenda copy remain unchanged.

### M05 — Semantic rhythm, not baseline snapping

The spacing ladder is 4/8/12/16/24/32/48px. Default relationships: label/control 8px; heading/copy 12px; related content 16px; groups 24px; header/content 32px; independent sections 48px. One parent owns each gap; do not stack child margins/spacers onto it or force readable line heights onto a grid. Wrapping changes block height, not the next semantic gap.

Apply these relationships semantically, not as authorization to mechanically rewrite every existing margin. Explicit exception: a disclosure following content has an additional 16px top margin outside its hairline, even with a parent stack gap. First-child disclosures need no extra margin.

Workspace integration headings use a single interior bottom hairline and 20px/24px header inset. Provider account headers separate full identity from adjacent status; at ≤600px status sits above the title, right-aligned. GitHub keeps authorized accounts and joined installation-owner rows on independently ruled transparent planes, with single internal separators. Integration credential-modal triggers belong in the main card; registration instructions belong in the right context column, stacked after the main content on narrow screens. GitHub's setup guide starts collapsed and uses a plain, non-underlined disclosure summary. Google/Gemini add-settings actions have no redundant rule above them.

Individual Connections integrations, Scenes task cards and Settings cards share the Gemini-derived primary header: uppercase label, 23px regular title, then one full-width interior hairline. Use the shared `card-section-heading` owner with 24px padding (16px inline at ≤600px), with adjacent status/action on the right; narrow screens place it above the label/title. This header remains present through loading, setup and connected states, separate from account identity rows and the outer numbered page title.

### M06 — Sidebar is a column, not a drawer

Collapsed navigation is 64px on desktop and 48px at ≤760px, showing only the mark. The same ≥44×44px button toggles **Expand sidebar / Collapse sidebar** with truthful expanded state. Desktop expansion widens the existing column to 224px and moves content. Narrow expansion sits in normal flow above content: no overlay, backdrop, custom focus trap, separate mobile header or horizontal product navigation.

Product links are 01 Home, 02 Workspaces, 03 Connections, 04 Scenes, 05 Settings. Lock sits at the top right of every working page header, not in the sidebar; it remains a native CSRF-protected POST within the working gate. Account mail activates Home; workspace activity activates Workspaces. Escape collapses expanded navigation and returns focus to the mark; destination selection collapses it and focuses the destination heading. Preserve native links, URLs, reload, Back/Forward and safe deep-link return through unlock.

Working content has no added top padding. Default working max width is 1440px, 1600px at ≥1700px; desktop outer gutter 32px and content separation 36px. Main Home/workspace readouts stack at ≤1200px; secondary dense grids simplify at ≤1080px and ≤440px. The ≤760px shell transition is not a ban on other content-fit thresholds: connection headers stack at ≤600px, status right-aligned above title/metadata.

The shared shell owns the outer top inset: 24px, or 20px at ≤950px. Top-level numbered registers occupy a 44px row centered with the sidebar mark; content itself adds no top padding. Lock stays right-aligned beside the register/account context; at ≤760px return links wrap onto a following row. Home places **01 / Home** above the entire date/focus hero. The hero has no top or bottom hairline; its interior date divider and separate readout boundaries remain. Its Gmail empty state retains the decorative mail service icon; omit the redundant “Separate inboxes” label. The GitHub activity header has one bottom interior hairline, without doubled first-row borders.

Home's date stacks the weekday above the large day number, with month/year below at every viewport. The weekday uses responsive 24–32px uppercase type and month/year uses 16px, with 8px gaps. The date container fits its contents within the available column width. Keep the browser-local date, midnight/resume updates and accessible full-date label.

### M07 — Color and signals communicate bounded facts

| Role | Token/value | Meaning |
| --- | --- | --- |
| Attention | `--attention: #70d6eb` | Worth reviewing, not failure |
| Warning | `--warning: #f2bb63` | Known caution, delay or constraint |
| Danger | `--error: #ff9c89` | Failure, invalid input or explicitly scoped destruction |
| Success | `--success: #79d5b0` | A specific observed result, not blanket account health |

Use color on small icons, short labels, counts and fine markers, not broad fills or ordinary reading text. Pair it with explicit words and shape; metadata is not disabled merely because it is muted.

Reuse the six canonical local SVGs: healthy check bars, loading squares, unknown question, waiting hourglass, disconnected brackets and attention triangle. They accompany status text, inherit color, and are decorative/nonfocusable. Only loading implies an active read. Unknown is not polling; waiting is not a countdown; the disconnected gap never closes. Restrained cycles are respectively 3.6/2.4/3.6/3/3.6/3 seconds. Preserve canonical geometry/motion rather than substitute a generic spinner. Reduced motion, print and inherited `--signal-motion: none` yield complete static artwork.

### M08 — State and identity outrank atmosphere

Keep account name/address or installation owner adjacent to counts, health and content. Do not aggregate inboxes, agendas or cross-owner GitHub activity. Gmail/Calendar share a Google connection, not consent, health or counts. GitHub selections are snapshot subsets, not complete repository totals. Unknown/expired counts use an accessible dash, never fake zero; zero needs a complete successful observation. Count unread inbox conversations, not messages or a partial page. Gmail last 24h is a rolling received-time window; Calendar Today is browser-local day. GitHub timestamps explicitly identify UTC. Failed refresh/render/local checks do not advance the last successful provider observation.

Production deliberately omits account-letter register codes rather than introducing durable assignment. Retain numbered section labels and adjacent full account name/address or installation owner beside counts, health and content. Do not derive letters from array positions, replace identity with a code, or use display numbering as provider/security identity.

### M09 — Controls name intent and scope

Native links navigate; native buttons act. One filled primary action per coherent task, neutral supporting actions, no decorative arrows on ordinary navigation. Destructive labels name scope: **Remove from workspace** is not **Disconnect everywhere**. Disabled controls retain a visible associated reason. Minimum action target is 44px; interactive focus uses a visible 2px ring with appropriate clearance (5px exterior, 3px dense inset).

Workspace cards have a separate, always-visible, bordered ≥44×44px Rename text button at top right aligned with the number and named for that workspace; it opens the dialog directly. The workspace detail Rename uses the same bordered control. Do not hide the single action in a menu, make it hover-only or nest it inside the destination link. Subview return links sit at the right of the numbered label row above the title.

Fields keep persistent labels, associated errors, useful nonsecret input and a route from rejection summary to field. Native modal dialogs have labelled headings, deliberate initial focus, modal containment and opener restoration. Modal Escape/Cancel closes only the modal, preserves drafts and does not enter scenery. Pause visual idle while modal; sidebar-origin dialogs restore the mark. Ordinary navigation never traps focus.

Google, Gemini and GitHub credential editors reuse the native modal shell and client lifecycle. Opening and dismissal stay local; blank secret fields submit only through the existing protected POST boundaries, never LiveView events. Unsaved values survive dismissal and unrelated patches only in the mounted browser form, not server state. Closed credential dialogs do not pause idle or restore focus when navigation removes them. Modal fields retain the dedicated essential-control border token.

### M10 — Quiet language, explicit consequences

Voice is quiet, clear, considerate: state → consequence → specific action. Use natural contractions, sentence case and verb/object actions. Directory headings and navigation/actions have no added terminal period; preserve owner-entered workspace names as written. Home alone may use **A day in focus.** Directory pages use title-only headers. Unlock uses mark/wordmark without a redundant **Locked** label, extra slogan/sidebar/task heading; accessible orientation must still exist. Preserve Google, Gmail, Calendar, GitHub and Gemini spelling.

No repeated greetings, praise for routine work, product persona, architectural metaphors in working copy, invented causes/repair times or reassuring “Don't worry.” Missing means confirmed absence; unavailable means unreadable; reconnect specifically repairs authorization. Name the account and actual observation. Announce real meaningful completion, not unchanged polls/timer ticks. Do not hide cost, password loss, provider storage, destruction or unknown-outcome warnings in transient toasts or shorten them to fit a decorative layout.

Saving direction does not generate; local credential readability is not provider verification. Scene generation still needs explicit cost/storage disclosure and fresh confirmation; unknown submissions are not automatically retried. Scenery is not privacy or security. These examples express real boundaries, not permission to initiate those operations during design verification.

Automatic startup generation requires both the Ash-persisted opt-in and enabling environment configuration. An absent preference is off; `MONOLITH_STAGE_ENABLED=false` is a hard veto on new automatic work. Saving opt-in neither generates nor cancels already authorized work. Manual generation remains independently confirmed; the persisted 24-hour cooldown applies to automatic startup.

### M11 — Motion is interruptible and nonessential

Canonical identity choreography uses opposing ascending Outline contour/descending creases, or Solid rise-and-incise; completed mark rests before eight letter flips; then hold, lift and dissolve. Contour/silhouette lasts 1600ms after 180ms; creases 1100ms after 1100ms and 500ms after 1850ms; letters 600ms after 2600ms plus 85ms each. The last crease ends at 2350ms, leaving 250ms before letters. Hold 360ms; mark exit 900ms after 150ms, letters exit at accelerated 1.8× timing. About 5.2 seconds total. Completed artwork equals the static lockup; no moving faces/shading or Outline clip-wipe substitute.

Inline proof is manual, no autoplay/loop; Replay replaces one sequence, never overlaps. Stop/Escape, route/selection/scenery changes and print cancel it, restoring completed identity; reduced motion shows static completion. Ordinary UI transitions remain scene 800ms, working plane 650ms, navigation 320ms, not identity timing controls.

Escape/idle is visual scenery only. Preserve route, focus, scroll and drafts; no replay on wake. First click/tap/non-Escape key wakes without consuming intended input; mouse movement neither renews nor wakes, scroll renews but does not wake. Default idle is three minutes, configurable 1–60; elapsed hidden-tab/sleep time counts. Only explicit Lock protects storage/stops protected work. Keep real lifecycle teardown, in-flight cancellation and LiveView patch continuity; a static simulator is not production hook code.

### M12 — Accessibility is a release requirement

Measure actual scenery composites: ordinary text ≥4.5:1; large text and essential control boundaries ≥3:1. Decorative dividers are exempt from control contrast. Colored small text must remain readable over the shared scenery contrast treatment. Swatches and source inspection do not certify contrast.

Prove keyboard access, visible focus, 320px layout, 200% text zoom and 400% page zoom, long/bidi identities and expanded labels, reduced motion including mid-sequence changes, forced colors and print. Preserve names/counts/errors/current navigation, wrap without overlap or page-level horizontal scroll. Forced colors removes scenery and uses system colors; reduced motion/print preserves complete identity/signals. Print keeps readable dark-on-white content/labels/rules and removes decorative chrome/motion. Neutral logo reproduction plates have explicit print-polarity exceptions. Programmatically focused headings may suppress their own outline; actionable focus may not.

## Non-rules and evidence limits

- Retired palettes and alternative designs are not additional requirements. Preserve security/state invariants, including no implication that unknown means an active check.
- Ordinary-navigation guidance is not a universal icon ban. Native modal shadow/backdrop is a scoped exception, not a content-card convention.
- Identity playback cancellation and sidebar Escape/focus behavior must both remain correct when combined.
- Frozen demo data, hash routing and simulated provider operations are not production implementations.
- Checklists, source assertions and historical screenshots are not fresh runtime evidence. This document defines acceptance, not a claim that the app passes it. Unresolved material conflicts require caller resolution, not silent invention.

## Enforcement and evidence

Use `monolith-rebrand-implementation` before a scoped cutover and `monolith-design-verification` to exercise it. Dispatch `monolith-visual-system-reviewer` for M01–M05 and visual portions of M06/M07/M11/M12; dispatch `monolith-experience-reviewer` for M06–M12 interaction, state, voice and semantics. Both are read-only source reviewers, not browser certification. Preserve existing LiveView, security, account-isolation, boundary, background-work and cross-file specialists where affected; [REVIEWERS.md](REVIEWERS.md) owns invocation details.

| Gate | Required evidence |
| --- | --- |
| Before editing | Named codebase/presentation targets, applicable rule IDs, actual owners/callers, complete identity replacement map and unchanged product behavior |
| Source review | Target and standard `file:line`, concrete failure scenario, severity, rule coverage checked/not applicable/unresolved; no fabricated baseline |
| Runtime acceptance | Exercise the changed surface: actual routes/states/output modes and browser evidence for UI; real module/configuration/command behavior for codebase-only changes. No browser gate for a nonvisual-only change |
| Regression paths | Sidebar/Escape precedence, modal restoration, deep links/history, first-input wake/drafts, honest unknown/stale/failure, account-switch fences, teardown as affected |
| Project checks | Use `bin/monolith check`, `bin/monolith audit`, and, for affected UI behavior, `bin/monolith mix test.ui`. Report failures/unrun checks separately |

Acceptance requires no confirmed mandatory-rule violations and no unresolved verdict-essential evidence within the selected scope. Subjective polish is advisory; do not invent pixel tolerances or demand unrelated rebrand completion. Missing browser evidence prevents a visual-verification pass, not a scoped source-only verdict when source evidence is complete.

Verdicts follow selected routes/states, not every behavior in a shared file. Preserve out-of-scope findings separately. A changed shared owner requires tracing affected consumers/regressions; a current-state Home-only review must not reject solely for an unrelated Identity-only scenario. Neither scope-limited approval nor an unexamined route implies whole-system acceptance.
