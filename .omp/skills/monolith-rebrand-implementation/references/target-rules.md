# MONOLITH target rules — portable baseline

Read this entire reference before applying the workflow. This bundled baseline is sufficient without the originating repository or authoring plugin. The approved expanded MONOLITH study is the visual/content target, not a production implementation. Current project guidance and consuming code supply present ownership and behavior evidence; they do not silently grant mutation authority. When available, acquire `docs/MONOLITH_DESIGN_SYSTEM.md`, `docs/UI_CONTRACT.md`, current operational guides and relevant `design-concepts/monolith-study/` sources. Resolve material conflicts explicitly. Preserve the project's security/product semantics while applying the authorized identity and selected presentation scope. Old visuals do not veto the approved target; unchanged surfaces are not failures.

## M01 — One working plane

Scenery is atmosphere, never a reading surface. Join account-separated registers on neutral Charcoal glass with open left/right edges, horizontal boundaries and quieter internal dividers. No nested floating content cards, decorative content-card shadows/gradients or colored status-panel fills. This does not ban scenery contrast-shade gradients or native modal elevation. Keep text fully opaque independently of surface opacity.

Regular `--card-surface` is `rgba(18,23,21,.71)`; raised/hover opacity is `.88`, inset controls `.72`. Outer boundaries use 1px `--line` at 23% opacity; internal separators use 1px `--line-interior` at 12%. One shared parent owns glass; adjoining children stay transparent and do not double rules. Buttons, fields, focus indicators, selected controls and dialogs may own necessary backgrounds/outlines. Native modal elevation is not permission for content-card shadows.

## M02 — One foundation and owner

The study's annotated `tokens.css` is the approved foundation, loaded before consumers. Integrate decisions into existing application token/component owners; no designer specimen sheets at runtime, divergent public-token copies, parallel themes or second component system. A public token needs a reusable decision, real consumer and usage comment, one declaration per line under an annotated group. Layout owns composition; specimens own examples. Brand ground/size/tracking, signal size/motion and measurement knobs stay local. Keep literal media conditions beside affected layouts: custom properties cannot serve as media-query thresholds. Generic transitions do not control artwork choreography.

## M03 — Fixed identity, fluid layout

Reuse authored MONOLITH artwork; do not redraw, stretch, shade faces, synthesize weight, add decorative containers or invent a separately named symbol. Outline and Solid are treatments of one identity. Light/dark reproduction plates are proofs, not UI themes; working UI is Charcoal only. Full unlock uses Outline. Compact sidebar uses Solid with negative-space creases cutting through its ground. The mark is never a status/loading icon.

Display stacked lockup: 104px mark, 24px wordmark, `.22em` tracking, 24px gap, at least 16px clear space. Compact horizontal: 32px mark, 15px wordmark, `.16em` tracking, 10px gap from the 44px button-target edge. Both use locally hosted Space Grotesk 500, line-height 1.2. Preserve the 104×104 SVG safe field, 2.4-unit outline, square caps and miter joins. Standalone icon proofs at 24/32/48px are not new lockups. Reflow the container; never shrink/wrap wordmark or vary its tracking per page. Ordinary product-name mentions use normal reading text.

## M04 — Reading typography

Use local Space Grotesk for reading/UI and system monospace for registers/technical metadata. Body 16px/1.55; supporting text 13px. Prose uses sentence case and normal tracking; deliberate exceptions are uppercase/tracked registers and the wordmark. Display headings use fluid 42–82px, section registers 12px/1.6 with `.1em` tracking, account titles 23px/1.25 with `-.03em` tracking; these are not brand lockups. Mail uses 18px/1.8, becoming 17px/1.75 at ≤760px, 68ch reading measure and 76ch outer reader. Introductory copy is bounded at 58ch. Long addresses/subjects/URLs/errors wrap without hiding identity or causing page-level horizontal scroll; scoped table overflow is allowed.

Metric labels default to Space Grotesk 400 at 13px/1.55, uppercase with normal tracking. Use the shared `metric-label` primitive and an 8px label/value gap when stacked above counts. Gmail and GitHub metrics share this default; section registers and technical metadata retain their own presets.

## M05 — Semantic rhythm

Spacing ladder: 4/8/12/16/24/32/48px. Label/control 8px; heading/copy 12px; related content 16px; groups 24px; header/content 32px; independent sections 48px. One parent owns a gap; no stacked child margins/spacers or grid-snapped line heights. Wrapping changes height, not the next semantic gap. Measured unit-04 specimens are relationship examples, not permission to rewrite every margin. Exception: a disclosure following content adds 16px top margin outside its hairline even with parent stack gap. First-child disclosures need none; designer toolbar stays flush.

## M06 — Sidebar and real navigation

Collapsed sidebar is 64px desktop and 48px at ≤760px, showing only the mark. The same ≥44×44px toggle says Expand sidebar / Collapse sidebar and exposes truthful expanded state. Desktop expansion widens the column to 224px and moves content. Narrow expansion is normal flow above content: no overlay/backdrop/custom focus trap, separate mobile header or horizontal product navigation.

Links: 01 Home, 02 Workspaces, 03 Connections, 04 Scenes, 05 Settings. Lock is separate at the bottom. Never import designer Views/Identity/Components/CSS/Voice/Proof into product nav. Account mail activates Home; workspace activity activates Workspaces. Escape collapses expanded navigation and returns focus to the mark; destination selection collapses it and focuses destination heading. Preserve native links, real URLs, reload, Back/Forward and safe requested destination through unlock. Never copy study hash routing.

Working content adds no top padding. Working max width 1440px, 1600px at ≥1700px; desktop outer gutter 32px, content separation 36px. Main Home/workspace readouts stack at ≤1200px. Secondary dense grids simplify at ≤1080px and ≤440px. Shell transition ≤760px does not prohibit content-fit thresholds; connection headers stack at ≤600px with status right-aligned above title/metadata. Identity/rhythm specimen thresholds 1000/800/600px do not add product shell modes.

## M07 — Bounded color and signals

Attention `#70d6eb` / `--attention` means worth reviewing, not failure. Warning `#f2bb63` / `--warning` means known caution/delay/constraint. Danger `#ff9c89` / `--error` means failure/invalid input/explicitly scoped destruction. Success `#79d5b0` / `--success` means a specific observed result, never blanket account health. Use small icons, short labels, counts and fine markers, not broad fills or ordinary reading text. Add explicit words and shape; muted metadata is not disabled.

Reuse six canonical local SVGs: healthy check bars, loading squares, unknown question, waiting hourglass, disconnected brackets, attention triangle. They inherit color, accompany status words and are decorative/nonfocusable. Only loading implies active read; unknown is not polling, waiting is not countdown, disconnected gap never closes. Restrained cycle lengths respectively 3.6/2.4/3.6/3/3.6/3 seconds. Preserve canonical geometry/motion, no generic spinner substitutions. Reduced motion, print and inherited `--signal-motion: none` leave complete static artwork. Obtain current canonical assets when needed; do not invent missing geometry from this prose.

## M08 — Honest state and identity

Keep account name/address or installation owner beside counts, health and content. No aggregate inboxes/agendas/cross-owner GitHub activity. Gmail/Calendar share a Google connection, not consent/health/counts. GitHub selections are snapshot subsets, not total repository counts. Unknown/expired counts use an accessible dash, not fake zero. Zero requires a complete successful observation. Count unread inbox conversations, not messages or a partial page. Gmail last 24h is rolling received time; Calendar Today is browser-local day; GitHub timestamps explicitly identify UTC. Failed refresh/render/local checks do not advance last successful provider observation.

Register digits repeat the nearest numbered section. Uppercase letters identify connections within a family: A01/B01 Email and A02/B02 for the same Google accounts in Calendar; GitHub has its own family. Assign A…Z, AA… in connection order. Filtering/sorting/renaming/membership do not reassign letters. Removal leaves a gap; never reuse it. Retained returning connection retains its letter; new connection gets next unused letter. At least two digits; codes never replace full identity or become security/provider IDs. Durable assignment needs a real approved production design, never filtered-array indices.

## M09 — Intentional accessible controls

Native links navigate; native buttons act. One filled primary per coherent task, neutral supporting actions, no decorative arrows on ordinary navigation. Destructive labels state scope: Remove from workspace is not Disconnect everywhere. Disabled controls retain visible associated reason. Action targets ≥44px; visible interactive focus ring 2px with appropriate clearance (5px exterior, 3px dense inset).

Workspace has separate always-visible ≥44×44px Rename text button at top right aligned to its number, named for that workspace and directly opening the dialog. No hover-only/menu-only action or nesting in destination link. Subview return link is at right of numbered label row above title.

Fields have persistent labels, associated errors, useful nonsecret input preservation and summary-to-field route. Native modal has labelled heading, deliberate initial focus, modal containment, opener restoration. Escape/Cancel closes only modal, preserving drafts without entering scenery. Pause visual idle during modal; sidebar-origin modal restores mark. Ordinary nav never traps focus.

## M10 — Quiet voice and real consequences

State → consequence → specific action. Natural contractions, sentence case, verb/object actions. Page titles end in a period; nav/actions do not. Home alone may say A day in focus. Directory pages have title-only headers. Unlock uses mark/wordmark and Locked, without extra slogan/sidebar/task heading; accessible orientation remains. Preserve Google, Gmail, Calendar, GitHub and Gemini spelling.

No repeated greeting, routine praise, product persona, architectural metaphors, invented cause/repair time or Don't worry reassurance. Missing means confirmed absence; unavailable means unreadable; reconnect specifically repairs authorization. Name actual account and observation. Announce meaningful observed completion, never unchanged polls/timer ticks. Cost/password-loss/provider-storage/destruction/unknown-outcome warnings stay explicit and persistent, not hidden in toast or shortened for decoration.

Saving direction is not generation; local credential readability is not provider verification. Scene generation still needs explicit cost/storage disclosure and fresh confirmation; unknown submission is never automatically retried. Scenery is not privacy/security. These rules are not permission to trigger protected actions during verification.

## M11 — Interruptible, nonessential motion

Canonical `identity.js` choreography: Outline contour ascends opposing descending creases, or Solid rises-and-incises; completed mark rests before eight letter flips, then hold/lift/dissolve. Contour/silhouette 1600ms after 180ms; creases 1100ms after 1100ms and 500ms after 1850ms. Last crease ends 2350ms, leaving 250ms before letters. Letters 600ms after 2600ms plus 85ms each; hold 360ms; mark exit 900ms after 150ms, letters exit at 1.8× speed. About 5.2 seconds total. Completed artwork equals static lockup. No moving shaded faces or Outline clip-wipe substitute.

Inline proof is manual, no autoplay/loop. Replay replaces one sequence without overlap. Stop/Escape, route/selection/scenery changes and print cancel to completed identity; reduced motion shows static completion. Ordinary transitions: scene 800ms, working plane 650ms, navigation 320ms, not artwork timing controls.

Escape/idle is visual scenery only: preserve route/focus/scroll/drafts, no replay on wake. First click/tap/non-Escape key wakes without consuming intended input. Mouse movement neither renews nor wakes; scroll renews but does not wake. Default idle three minutes, configurable 1–60; hidden-tab/sleep time counts. Only explicit Lock protects storage/stops protected work. Preserve real teardown, in-flight cancellation and LiveView patch continuity; static simulator code is not production hook code.

## M12 — Runtime accessibility gate

Measure actual scenery/glass composites: normal text ≥4.5:1; large text and essential control boundaries ≥3:1. Decorative dividers are exempt from control contrast. Colored small text belongs on dark glass. Source tokens/swatches do not certify actual contrast.

Prove keyboard access, visible focus, 320px layout, 200% text zoom and genuine 400% page zoom; long/bidi identities and expanded labels; reduced motion including mid-sequence changes; forced colors; print. Keep names/counts/errors/current nav and wrap without overlap/page-level horizontal scroll. Forced colors removes scenery and uses system colors. Reduced motion/print keeps complete identity/signals. Print preserves readable dark-on-white content/labels/rules, removes decorative chrome/motion; neutral logo reproduction plates have explicit print-polarity exceptions. Programmatically focused heading may suppress its own outline; actionable focus may not. CSS zoom, transforms, viewport resizing and source-only assertions are not browser page/text zoom proof.

## Production invariants and conflicts

The approved whole-codebase identity target is MONOLITH prose/UI, :monolith OTP/config, Monolith/MonolithWeb modules, monolith project-owned libraries/paths/commands/tooling/keychain/storage identifiers and MONOLITH_* environment variables. Third-party names and runtime versions remain unchanged; project-owned configuration/dependency settings may change where needed for this rename. Inspect actual current owners (lib/lovelace, LovelaceWeb and bin/lovelace until cutover), not nonexistent target paths. There are no users and existing data is replaceable: no rebrand-specific preservation, compatibility aliases, credential transfer or data migration requirement. This grants no private-state reads, deletes or resets and no blanket destructive-effect waiver. Authentication, terminal pairing, safe redirect, loopback, single-owner/session, SQLCipher/keychain security, account/connection/client generations, Lock versus idle, consent, private-data boundaries and self-hosted assets remain binding. Ash actions/policies own behavior; web consumes public capabilities; adapters implement contracts without owning orchestration. Oban owns durable work with ID-only jobs, atomic admission, fences, bounded retention and explicit unknown outcomes. No browser-owned provider work, broad infrastructure or live-provider effects for design proof.

Study frozen times/counts/invented users, in-memory settings, local substring search, noneditable credentials and simulated scene/provider actions are limitations, not production requirements. Stale study-only naming does not override the approved codebase identity target; identifier renames do not authorize operations on private storage. Old palette/top-nav/identity/unknown-signal/workspace visuals are replaced only in selected scope; security/state semantics survive. Ordinary-nav no-arrow guidance does not universally ban explicit identity/unlock exceptions. Native modal shadow/backdrop is scoped, not a card convention. No invented pixel tolerances. Whole-codebase identity cutover does not automatically implement every visual surface. Codebase-only namespace/config/path/command changes require relevant source/caller/configuration and synthetic behavior evidence, not a visual browser gate; mark M01–M12 not applicable where presentation is unaffected. Historical screenshots/checklists are not fresh runtime proof. Subjective polish is advisory. Completion needs no confirmed mandatory violation and no verdict-essential unresolved evidence in selected scope; source-only acceptance may satisfy expressly source-only criteria, but never claims visual runtime certification.
