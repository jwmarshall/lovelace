# LOVELACE — visual and interaction contract

This is the current contract for all owner, workspace and mail surfaces. Keep visual and
interaction decisions here and durable product/safety rules in [AGENTS.md](../AGENTS.md).
Later approved decisions replace old requirements rather than accumulating a chronology.
Verify implementation in code; the coverage map below is not evidence that checks passed.

## Direction and shared stage

- Warm cinematic minimalism inspired by quiet brutalist architecture, not film branding,
  neon cyberpunk, a marketing page or a decorative widget wall.
- One edge-to-edge, nearly transparent glass stage spans unlock/setup, workspace and mail
  views, including empty/error states. Keep the outer stage borderless; control/card borders
  and keyboard focus outlines remain. Do not turn the shell into a centered dashboard card.
- Charcoal, Earth, Sea Glass and Mist offer restrained dark palettes with pale text,
  strong geometry, fine dividers,
  deliberate negative space and practical working density. Use a consistent compact gap below
  navigation across primary views, shallow workspace/integration cards and restrained list spacing;
  do not fill spare stage space with explanatory copy. Keep health, freshness and actionable warnings
  visible; occasional setup, billing-policy and disconnect guidance can use native disclosures.
  Billing confirmation remains explicit before generation. Semantic warnings/errors remain distinct.
  Sea Glass is the default; Earth uses warm accents, Charcoal neutral accents and Mist cool slate/silver.
  Scenery colors are independent. `assets/css/themes.css` owns palette literals and shared semantic
  tokens; components consume those tokens rather than defining their own UI colors.
- `--color-attention` is a palette-tuned soft violet for items needing the owner's
  attention, such as review/check/run counts. Keep it separate from primary navigation
  accents, amber degraded-service warnings, and coral errors/destructive actions.
  All four palettes define it through `--theme-attention`; components never substitute
  warning ink. Target at least 4.5:1 text contrast on the three base surfaces and a
  distinct hue from chromatic primary, warning and error inks. Labels/tooltips still
  communicate meaning without color; forced colors uses system text.
- Self-host Space Grotesk with system fallbacks. Keep the name **LOVELACE** uppercase and
  the original double-cursive-`l` monogram. Wordmark tracking/light weight must not leak
  into long-form mail typography. Readability and contrast outrank cinematic dimness.
- Scripts/fonts/imagery are local, with applicable licenses, provenance and checksums for
  vendored assets. No runtime CDN, font service, remote browser imagery, animated scenery
  or parallax. Server-side opted-in Gemini output is validated and served locally;
  generation/cost/storage rules belong in [STAGE_DESIGNER.md](STAGE_DESIGNER.md).
  The sole remote browser-content exception is a freshly click-loaded official YouTube
  nocookie iframe. Its contents remain YouTube-controlled; parent assets and thumbnails
  stay local/absent. No ad-free or tracking-free promise.

## Action hierarchy

Choose emphasis by intent, not by provider, page, or whether the element is a link or button.
Use the same hierarchy on static setup/unlock pages and authenticated views.

| Intent | Treatment | Shared class | Examples |
| --- | --- | --- | --- |
| Main next step | Filled theme accent | `workspace-action workspace-action-primary` | New workspace, Connect Google, Save selection, dialog confirmation |
| Supporting operation | Neutral outline and quiet fill | `workspace-action` | Refresh, Check Keychain, Search, Download, Cancel |
| Contextual navigation | Underlined accent text, no box | `workspace-action workspace-action-link` | All connections, Back to results, Manage connections, URL pagination, external setup documentation |
| Destructive operation | Error-colored outline and explicit wording, never an accent fill | `workspace-action workspace-action-danger` | Remove from workspace, Disconnect everywhere, Remove API key |
| Command inside a management menu | Neutral unboxed row | `workspace-action workspace-action-quiet` | Rename |

- Use at most one accent-filled action per coherent task group: a page-level creation action,
  an independently editable form, or a modal. Do not make every account-row operation primary.
  Separate Scenes direction/save and generation forms are independent tasks; repeated gallery
  selections and refresh controls remain secondary. A page need not contain a primary action.
- A sole enabling action in a setup/empty-state card may be primary even when it navigates
  to a prerequisite, such as **Set up Gemini**. Home's parallel service readouts instead use
  equal-weight text links; do not turn each into a competing primary setup button.
  Empty and populated Workspaces use the same primary **New workspace** treatment.
- A primary setup disclosure transfers emphasis when opened: its summary becomes a secondary
  outline and its form's submit becomes primary. Informational disclosures remain quiet,
  unboxed summaries with a disclosure indicator. Opening help is not a destructive action.
  Provider-wide help and billing/disconnect disclosures sit below the provider's cards and
  forms, aligned to the content edge, not inside an individual setup card. Keep current
  credential health, actionable warnings and brief cost/startup notices visible with their
  controls; moving policy details must not hide consent or billing confirmation.
- Back/manage/reconnect navigation is a text link; actually submitting authorization is an
  operation. New connection forms use primary submit; repeated existing-account reconnect
  operations stay secondary. Optional onboarding continuation/skip is secondary when a setup
  action is offered; refresh/load is secondary, never another accent-filled CTA.
- Keep top/provider navigation and large workspace/account/provider link surfaces in their
  existing navigation grammar, with active indicators or directional cues; do not style them
  as command buttons. Links embedded in prose stay underlined and inherit readable body sizing.
  Regular text links have text-only labels: no decorative arrow icons or arrow glyphs.
  Keep accessible new-tab notices, disclosure indicators and functional status/service icons;
  large account/workspace/provider navigation surfaces retain their separate visual grammar.
  Creation and attachment actions also use text-only labels: no decorative plus icon or
  `+` prefix on **New workspace**, **Add integration**, **Add to workspace**, or **Add Gmail account**.
- Preserve native semantics: destinations are links with real `href`s; mutations/submissions
  are buttons; disclosures use `details`/`summary`. Visual variants never change consent,
  confirmation, CSRF, disabled/loading guards, modal focus restoration or account context.
  On Scenes without available Gemini credentials, **Set up Gemini** is the setup card's only
  action; omit **Refresh status** and direct access recovery through Gemini settings.
  Keep **Refresh status** in the connected designer, where it reads local state only.
  Danger color supplements explicit removal/disconnect wording and existing confirmations.
- Shared actions have at least 44×44px targets, wrapping labels and visible keyboard focus.
  Inline prose links are not padded into buttons. Secondary hover stays neutral; accent is
  reserved for primary actions and navigation. Disabled actions do not gain hover emphasis.
  Use theme tokens in every palette, system ButtonText/ButtonFace for operations and LinkText
  for navigation in forced colors; do not rely on color alone to explain a destructive action.
  Use `workspace-action-link` without the `workspace-action` base on inline prose links
  and rich content titles that must retain their own typography rather than button padding.

## Focal planes and inactivity

- At rest, scenery is sharp; working content softly blurs and dims, and branding is hidden.
  Intentional focus sharpens content and softens scenery. Idle blur includes headings/mail
  (currently 3px); exact token/blur values are not immutable design requirements.
- Escape or configurable inactivity (default three minutes, range 1–60) restores scenery.
  Click, keyboard, scroll and touch renew activity; mouse movement neither renews nor wakes.
  Scroll/wheel/touchmove alone renew activity but do not wake an unfocused pane.
- Click/tap or non-Escape keyboard input wakes without consuming the first intended input,
  moving focus off its control or discarding current navigation, scroll or unsaved forms.
  No invisible full-pane activation control may cover working controls after entrance.
- The timer/focal-plane switch is client-only. Hidden-tab/sleep elapsed time counts;
  LiveView patches and background updates do not reset the activity timestamp. Hook teardown
  removes timers/listeners. No page load, wake or idle action starts background generation.
- Cross-origin YouTube player keys/activity cannot reach the parent. While its iframe
  visibly holds focus, scenery idle is suspended. Tab/Shift+Tab returns to parent controls,
  including adjacent **Unload player**, and restarts the normal idle interval. Hidden-tab
  elapsed time still counts and unloads an expired player on return. Escape inside belongs
  to YouTube; outside it retains LOVELACE's normal scenery behavior. Explain this boundary
  beside the player rather than silently interrupting keyboard playback.
- This is **visual scenery mode, not authentication, Lock or a privacy guarantee**.
  Explicit **Lock** revokes all owner sessions, stops protected background work, closes
  the encrypted Repo and locks the dedicated credential keychain. Visual focus changes
  do not. Startup requires password unlock before protected persistence/jobs start;
  there is no password recovery or public/unpaired signup.
  Detected native keychain authorization/access failures trigger the same global Lock,
  including session disconnection and protected-work shutdown; missing individual
  credentials and locally invalid input do not. This is access-time detection, not
  continuous monitoring of macOS authorization.

## YouTube

- Keep per-account chronological feeds bounded and separate, with no remote thumbnails,
  recommendations, comments, infinite scroll or auto-next. Channel selection is explicit.
- Feed/watch URLs preserve reload, history and unlock destination. A player requires a
  fresh trusted Load click, never route entry, reconnection or returning through history.
- Unload on scenery idle/Escape, navigation, Lock, connection loss, account/grant/selection
  invalidation and hook teardown. Explicit Unload restores focus to Load; other invalidations
  must not steal focus. Player input follows the cross-origin boundary above.
- Keep authorization, freshness, loading, empty, truncation and provider failure distinct.
  Unavailable local state is not confirmed disabled consent and must not offer Enable as
  recovery. Rate-limit cooldown cannot be bypassed by Refresh. Local job observation is
  bounded and never owns the accepted durable work.
- YouTube observes shared Google client diagnostics while its Connections page is active.
  Keep consent disabled and show a neutral busy status until the check completes; a pending
  check is not missing settings. Stored settings enable consent without replacing credentials.

## Entrance, gate and persistent identity

- First activation traces the centered monogram, then flips the eight LOVELACE letters
  left-to-right. The completed logo holds briefly, then letters flip upward and out
  left-to-right while the monogram erases from the opposite end of its entrance trace.
  Working content becomes interactive only after exit. Current choreography uses a roughly
  1.35s trace, 250ms hold and 1.8× exit; equivalent restrained choreography may preserve
  the same contract.
- Duplicate activation does not restart an active sequence. Escape interrupts an unfinished
  entrance/exit; fresh activation replays it from the start at normal speed. Once completed,
  Escape/idle wake resumes immediately without replay. Full reload starts a fresh entrance.
- Local redirects back to an already authenticated, unlocked session (including OAuth
  and credential-form returns) open their destination immediately, without entrance
  animation or another activation click. A short-lived, session-bound return marker
  applies only to the matching destination once. It grants no authorization. Ordinary
  visits/reloads and initial unlock retain the entrance; Escape/idle still restores scenery.
- Server-owned working content is gated with `inert` until entrance completion. Remove the
  initial activation button permanently after handoff. Transfer initial focus to a meaningful
  heading without stealing focus from a control. Sticky client state survives LiveView patches.
- Keep GSAP ownership confined to the decorative `phx-update="ignore"` brand subtree;
  business controls/content stay outside it. Tear down listeners, media-query handlers and
  GSAP context when hooks are destroyed; patches must not duplicate/restart choreography.
- Top navigation has no corner monogram or wordmark. Keep the original double-cursive-`l`
  monogram only in the centered entrance animation. Home remains a visible text link.
- Give top-navigation links modest `0.08em` letter spacing; keep body and mail typography unchanged.
- Lock sits top-right. Lock and the bottom-right Escape legend live outside the working-content
  scroller and stay stationary while content and main navigation scroll. At widths without a spare
  side gutter, shallow top/bottom bands keep these controls from covering mail or management actions.
  Both share the sticky entrance gate; scenery mode hides Lock and dims the legend. Lock appears
  only in an entered, focused live workspace. Center navigation and Lock lose keyboard access
  in landscape mode.
- Static unlock/first-run setup pages share the stage, using only a fixed public bundled
  fallback while locked; protected generated imagery and the persisted bundled choice become
  available only after unlock. Unlock stays focused without an entrance or idle timer.
- Before the first eligible setup/onboarding visit in a tab's browser session, automatically
  play the centered LOVELACE entrance/exit before exposing the pairing form, then focus the
  step heading without a decorative focus outline on the static setup heading; keyboard
  focus rings on inputs and buttons remain visible. A session-storage noncredential marker
  prevents replay on subsequent steps, reloads, errors or returns; an old persistent marker
  cannot suppress a fresh session.
  Reloading before any eligible entrance still plays it. Unavailable session storage skips
  the introduction rather than blocking setup. Escape or reduced motion completes immediately,
  including a preference change mid-animation. Without JavaScript, branding stays hidden and
  forms remain usable. Static pages never acquire an idle timer or LiveView dependency.
- `/setup` is available only for new/interrupted storage and requires a private, single-use,
  expiring terminal pairing code before accepting an owner password. Explain permanent
  password loss before entry and require acknowledgement. Passwords/client credentials
  use ordinary CSRF-protected forms consumed before instrumentation, never LiveView state.
- `/onboarding` is an owner-protected, resumable workspace/Google project/authentication/
  audience/Desktop-client/Gmail/optional-Calendar guide. The owner names the first workspace;
  returning to that step edits the same workspace without creating duplicates. Setup and
  Home never create a predetermined starter. External console links explicitly open a safe
  new tab. Continuing records local progress, not verification of Google's settings.
  Saving client credentials makes no provider request. Connectivity and first-read claims
  derive from saved account observations; skipping never implies Gmail or Calendar access.
- Calendar authorization returns to an inline calendar picker in the guide. Its first read
  uses the browser's local day and the existing account-scoped queue. Initial page assembly
  checks the displayed workspace/account/generation against Calendar metadata and fails
  closed on a mismatch. Every returned picker and loading status must also match the
  initiating identity before use; mismatches never install another account's controls
  beneath the unchanged account heading. Navigation aborts pending work and late responses
  are ignored; owner redirects navigate the whole page. Each browser request has a 10-second
  deadline through response-body completion, then restores explicit recovery without
  automatic retry. Preserve unsaved selections and keyboard focus across same-identity updates.
  Poll at most 20 times, then expose an accessible pending/checks-stopped state rather than
  implying ongoing automatic checks. **Refresh calendar status** is a single metadata-only
  GET with no provider authorization, autoload or automatic polling restart, including its
  direct reload URL. **Refresh calendars** explicitly queues a bounded read before the normal
  interval too, preserving cooldowns and job uniqueness. No automatic endless retries.
  Selection supports shared calendars and an explicit empty selection; submissions remain
  fenced by the guide's workspace, account, and connection generation. Show persisted partial
  result and Google-selected selection-limit warnings independently. Optional consent denial
  leaves Gmail intact.
  **Save calendar selection** and **Refresh calendars** share one action row, including
  at narrow widths; labels may wrap inside their controls. Keep their separate submission
  operations and disable selection saving during Calendar loading or reconnection.
- Setup and onboarding use one horizontally centered, left-aligned reading column capped
  at 60rem (960px at the default font size), including headings, step navigation, forms,
  notices and footer copy. Step links use the 1rem body size and wrap as needed.
  Every onboarding step starts at the same 48px top inset, independent of content height
  or viewport width; shorter steps must not vertically center.
  Narrow screens retain side padding and independently scrolling instructions without horizontal overflow.
  Continue and Skip share one action row at desktop and narrow widths: Continue on the
  left, Skip on the far right. Labels may wrap within controls; do not move Skip onto a
  separate row. Use **Skip Google**, **Skip Gmail**, and **Skip Calendar** consistently.
  Use **Continue** for every intermediate primary action, **Use saved client** for the
  saved-credential alternative, and **Finish setup** only on the final review page.
  Omit bottom Back links; the step navigation remains available for revisiting earlier steps.
  Keep step navigation concise: Client, Gmail and Calendar; explain Desktop OAuth and optional Calendar in the step content.
  The pairing screen uses a narrower 45rem (720px) maximum, retaining responsive side padding.

## Home, workspace and integration navigation

- `/` is Home, the default after ordinary unlock for completed/existing installations.
  Explicitly started unfinished onboarding resumes its saved step by default. Reload and
  copied protected deep links restore their destination; a protected deep link resumes
  after unlock when its local return URL is safe
  and bounded. Escape/idle wake preserves the current view, scroll and forms; it never navigates
  Home. Successful Gmail consent started in onboarding returns to optional Calendar setup;
  setup Calendar consent returns to that same step for calendar selection. Explicit
  **Continue** on Calendar advances to the guide's review page before the owner finishes setup.
  Validated setup failures return to the corresponding guide step for retry or skip.
  Other Gmail consent returns to the receiving workspace; other Calendar consent returns
  to its global provider page for calendar selection.
- A centered navigation bar contains **Home**, **Workspaces**, **Connections**, **Scenes**, and
  **Settings**, in that order, wrapping at narrow widths without clipping links. These are native
  links using LiveView patches, with usable `href` destinations
  for copying/opening in a new tab; current destinations are identified with `aria-current`.
  Home is a visible text control. Lock stays separate. Top-nav Connections always opens the global
  `/connections` overview, including from workspaces and provider pages. No workspace query
  or workspace-return control is attached; browser Back retraces the actual origin.
  Gmail inboxes likewise have no redundant Home button.
- Home opens with a restrained greeting and date in the browser's local time, updated
  across midnight/resume. Home, Workspaces, Connections, Scenes and Settings use the same content width and
  alignment from the shared directory container; Home has no narrower inner cap. Reserve
  symmetric scrollbar gutters so scrolling pages do not shift the content plane. Keep copy
  functional and minimal: no “Your day” eyebrow, slogans or explanatory footer. Numeric
  account totals are labeled simply **unread**. No clock, message previews, total across
  accounts or speculative widgets. The separately approved read-only Calendar agenda
  below complements Gmail's daily orientation.
- Home pairs Gmail and today's Calendar agenda in two columns on desktop, aligned at
  their section headings. Both use quiet per-account cards matching GitHub's inset surface,
  fine border, 6px corners and 12px gaps. Stack Gmail above Calendar when either column
  would become cramped; retain the shared directory width, not a narrower dashboard shell.
  Gmail, Calendar and GitHub share `.home-section-heading` and `.home-eyebrow`.
  `--home-section-heading-height` (44px) and `--home-section-heading-gap` (12px) on
  `.home-readouts` own the common row size and inline gap; do not add provider-specific
  heading padding or margins. Right-align timezone/context in `.home-section-meta`
  on the same row; long labels may wrap without creating a separate metadata row.
  Keep the greeting/date on one restrained line where space permits. Home omits routine checked
  statuses (including “not checked yet”) and Calendar Refresh controls. Keep loading, error and
  locally aging stale warnings visible; workspace/Connections timestamps and refresh remain unchanged.
  Unknown unread totals use a dash with an accessible unavailable label, never a fabricated zero.
  Calendar setup is a compact empty state linking directly to Connections → Calendar.
- Gmail cards appear once per non-disconnected connection, including connections with no
  workspace membership. Each shows identity, workspace names and paired unread inbox
  conversation counts as **total / last 24h**, with explicit labels for both values.
  The recent value uses Gmail received-time search over a fixed rolling 24-hour window,
  not a local calendar day or partial cached page. Both observations are committed together;
  incomplete paging/failures retain the previous pair as stale. See [GMAIL.md](GMAIL.md) for bounds.
  Home shows stale warnings rather than routine successful-check timestamps; the underlying
  observation still ages locally. Clicking a card opens only that account's read-only inbox
  without attaching it anywhere.
- Unknown counts are not zero. Failed updates retain known counts as stale; elapsed time
  marks observations stale after three minutes, independent of unrelated mail-page success.
  Home rendering reads persisted metadata, never provider calls or cached message content.
  Empty/loading/error/reconnect states remain explicit, with recovery through Connections.
- Missing-content states share a small decorative service icon, a regular-weight heading,
  one short explanation and a relevant next action. Home readouts and their service empty
  states use quiet inset cards on the glass; workspace readouts keep fine separators.
  Provider/Scenes setup uses inset cards too, not large illustrations or a centered welcome
  dashboard. Keep actions at least 44px high, text wrapping
  and system-color fallbacks. Do not repeat the same connection action in both section heading
  and empty content, or show empty content while its setup panel is open.
- A genuinely empty Workspaces directory offers **New workspace** in its empty state.
  Gmail setup with no workspace links to Workspaces before offering the receiving-workspace
  consent form. With a workspace but no account, show a single text-only **Add Gmail account**
  action. Keep Add disabled while shared Google Desktop client settings are being checked,
  absent, invalid, locked or unavailable; explain the prerequisite and link to
  **Connections → Google**. Enable only when settings are locally available, without implying
  verified Google access. Reject attempts to open the Add dialog while that prerequisite is unmet.
  Apply the same prerequisite to Calendar setup, authorization, refresh and selection controls;
  retain cached account information, but reject Calendar connector refresh/selection events
  while settings are unavailable. Once client settings are available, Calendar without an
  account links directly to Gmail setup. Hide account-management/disconnect disclosures when
  there are no accounts to manage. Missing GitHub App configuration shows setup instructions,
  not a service-failure warning or an operational sign-in control.
  Gemini puts **Add API key** before secondary Keychain diagnostics; cost and startup behavior
  remain visible, and expanded credential forms keep their ordinary protected POST boundary.
  Successful empty agendas distinguish no selection from no events; loading, access failures
  and partial results never become a fabricated “nothing here” success.

- Calendar shows account-separated browser-local today's agendas on Home and workspace
  detail, without a unified timeline. Event titles, calendar names and Google Calendar links align
  to the left edge of each item; time/all-day/ongoing labels sit at the top-right, including on narrow
  screens. Never display descriptions, attendees or remote content.
  Connections → Calendar owns optional consent and local calendar selection (Google-selected
  defaults, shared calendars included). Unknown/loading/failure are not an empty agenda;
  partial results are labeled. Observations age locally, stale/error states retain their
  real timestamps, and refresh respects rate-limit cooldowns. The browser rechecks the
  day across midnight/DST/resume; another timezone's cached context must not be rendered
  as this view's today. Calendar content is not retained in LiveView socket assigns.
  Workspace removal is not global disconnect; both services share the Google credential.
  See [CALENDAR.md](CALENDAR.md) for bounds and lifecycle.

- GitHub adds a full-width **GitHub activity** section beneath Gmail/Calendar, grouped by
  personal/organization installation owner, never merged with mail or another owner.
  Home uses compact per-owner cards, three per row on desktop, two on medium screens
  and one on narrow screens. Show open PR/issue totals and recent-run snapshot counts.
  PRs and runs pair the main count with snapshot attention count as `total / attention`,
  theme accent versus `--color-attention`, with accessible labels and an attention tooltip.
  Count each PR needing review or failing checks once. Unknown/unavailable or expired
  counts use a dash, never a fabricated zero. Home omits per-owner status, partial-result
  messages and last-checked timestamps; workspace details retain health, freshness and
  partial-result context. Home has no Refresh buttons or activity disclosures. **View activity** links directly
  to the owner's expanded activity in its workspace; shared owners expose each attached
  workspace by name, and unattached owners offer **Add to workspace** through Connections.
  Workspace activity and its Refresh controls remain expanded and available.
  Detailed bounded pull requests, issues and runs retain repository, escaped title,
  author, explicit review/check/run state, safe new-tab links and UTC update times.
  No remote images, repository contents, workflow logs or artifacts. Preserve partial,
  stale/error/expired observations; incomplete results never imply an empty success.
  Connections → GitHub owns the inline registration/permissions/callback guide, native
  client ID/secret/slug POST form, session-bound OAuth browser sign-in and account disconnect.
  Saving settings is local-only, never provider verification. Secrets are never prefilled
  or returned. Hide sign-in while settings are missing, checking, locked or unavailable;
  locked/unavailable reads show an actionable keychain warning, never missing-settings setup.
  Failed sign-in remains a usable recovery page. OAuth uses single-use state and PKCE.
  Do not mount setup/editor disclosures until the local settings check settles: missing
  settings start open; stored settings start collapsed, preserving later user toggles.
  Saved app settings without an authorized account explicitly show that sign-in is still
  required. Ready account cards show Connected from persisted account state across reloads,
  never from the settings-save flash or an expired browser authorization attempt.
  Separate **Choose repositories on GitHub** (installation access) from **Connect GitHub
  account** (LOVELACE authorization). Rejected returns show a specific, safe inline
  recovery state across reloads, not stale waiting or a claim that GitHub denied access.
  **Start connection again** replaces the pending request explicitly; state/session
  validation and single-use exchange remain mandatory. Exchanging requests cannot restart.
  Workspace setup distinguishes no authorized account from an authorized account with
  no accessible repository owners; available owners can be added natively without
  reconnecting the account.
  Workspaces attach whole owners or independent immutable repository selections, with
  matching PR/issue/Actions readouts. Filtered owner snapshots are labeled as subsets,
  not selected-repository totals. Removing membership is not global disconnect.
  Credential POSTs/callbacks are consumed before instrumentation; account token bundles
  and app settings stay in the dedicated keychain. Failed deletion and retained legacy
  PATs remain reachable for explicit cleanup. See [GitHub setup](DEVELOPMENT.md#github).

- Workspaces represent areas of life. **Quiet sea-glass cards supersede the earlier
  typographic/no-card directory**. Use generous native link surfaces and separate native
  management disclosures for rename; opening and management are siblings, never nested controls.
  Create/rename use native modal dialogs with trapped focus, labelled headings and inline
  validation. Cancel/Escape closes only the dialog, restoring focus without entering scenery
  mode. Unrelated patches preserve the draft; invalid submissions keep the dialog open.
  The visual idle timer pauses while a modal is open and resumes on dismissal;
  this is not an authentication or privacy change.
- `/connections` is a quiet provider overview with Google, Gmail, Calendar, Gemini and GitHub links and
  short purpose labels, not a default Gmail page or combined health dashboard. It mounts
  no provider form and makes no Keychain/provider probe. Opening a provider focuses the
  heading; each provider offers **All connections** back to the overview.
- Provider pages have a **Google / Gemini / Gmail / Calendar / GitHub** subnav on the same row as the title
  on desktop (wrapping below on narrow screens), with only the selected provider mounted.
  Native links identify the provider with `aria-current`; switching preserves focus on the
  chosen subnav control. Provider paths are `/connections/google`, `/connections/gmail`,
  `/connections/calendar`, `/connections/gemini` and `/connections/github`. Each supports direct GET, reload and new tabs;
  credential POSTs return to their provider without exposing secrets to normal request instrumentation.
  Escape/idle preserves selection. Re-selecting the active provider does not discard forms;
  provider changes enter history and remove the previous provider's unsaved form content.
- **Google** manages the shared Desktop OAuth client, not account consent or Gemini keys.
  Its add/replace disclosure follows the same primary-save/secondary-open-editor action hierarchy
  as other credentials. Ordinary CSRF-protected POSTs are consumed before instrumentation;
  no client values reach LiveView or return in the page. Status means local settings presence,
  not verified Google access. Setup help sits below the card. Saving makes no provider request.
  Gmail and Calendar remain separate explicit account grants.
- First-run requires a named workspace, not integrations. **Skip Google** skips the
  Google guide and its dependent account steps to review; **Skip Gmail** and **Skip Calendar**
  advance without granting access or changing existing connections. Only the explicit finish
  action ends onboarding. Connections remains the destination for configuring integrations later.
- Workspace detail prioritizes separate integration/account tiles, never an aggregate inbox.
  **Add integration** is a focused panel for reusable Google accounts and GitHub installation owners;
  Gmail and opt-in read-only Google Calendar reuse account identities, not a speculative
  provider catalog. Google Gemini
  is an **app-wide Gemini connection** in global Connections, currently used by scenery and
  backed by a reusable text/image client (not a chat UI), separate from Gmail accounts;
  it is never attached to a workspace or included in Gmail health/counts. Its API-key forms
  are ordinary authenticated, CSRF-protected POSTs, not LiveView credential events. Display
  only Keychain availability/key presence, never a returned key or unverified Google health.
  Saving/removing does not generate, probe Google or change the startup opt-in/cooldown.
  Explain possible charges, optional startup generation, explicit Scenes requests and
  preserved imagery on key removal. Scenes captures per-request model/aspect/size in a single-use
  cost confirmation; these controls never alter startup defaults. A quiet global link signals active
  rendering or unacknowledged failure/unknown outcomes. Scenes retains paginated attempt history,
  safe actionable failure details, last-check timestamps and separate remote-cleanup warnings.
  Never fabricate percentage progress or call a retrieval failure a rendering failure. Unknown
  submissions require an explicit charge/overlap warning before abandonment; another generation
  always needs its own cost confirmation. Background Google storage and deletion-after-local-save
  are disclosed at confirmation. Keep prior scenery visible during work and failures.
- **Remove from workspace** detaches locally; global **Connections** owns health, reconnect
  and confirmed **Disconnect everywhere**. Global Gmail accounts use compact rows with
  identity/status beside actions on desktop and a wrapping layout on narrow screens.
  **Add Gmail account** opens a native modal; the new-connection form is absent until opened.
  Cancel/Escape dismisses only the dialog and restores the Add button. Unrelated metadata
  patches preserve its receiving-workspace choice. Global connect/reconnect forms explicitly
  select the receiving workspace, preserving identity and membership context.
- Gmail Connections offers an explicit per-account **Check Keychain**, separate from
  Google reconnect/disconnect. Run it asynchronously, one at a time, with announced
  safe error categories and an observation timestamp; never expose the token. Explain
  that an unlocked keychain can still deny item access and a readable token does not
  verify Google. Checks do not change permissions, contact Google, refresh mail or
  clear persisted health/freshness. Fence delayed results across connection generations
  and leaving/reentering Connections. Keep recovery guidance in a native disclosure;
  no automatic permission prompts or helper rebuilds.
- Card health is last-known metadata, not a fresh provider check. Entering/rendering cards
  or management does not fetch mail or provider health. Account updates cannot refresh a
  different selected inbox. Never infer unread totals from a bounded cached page: Home
  counts come from Gmail's INBOX label `threadsUnread`, scoped to each account.
- Inbox headers split account identification and search into two desktop columns, stacked
  on narrow screens. Search input and submit button touch, with matching height and font
  size. Keep an accessible search name without a visible account-scope explanation or
  generic reassurance copy. Retain actionable health/freshness/error states and workspace
  **All accounts** navigation in the mail toolbar.
- Inbox rows balance sender/date, a prominent subject and one muted preview line. Unread
  uses a visible marker plus stronger text, with an accessible unread label; not color alone.
  Parseable message dates use browser-local compact labels, with full dates available;
  unparseable dates remain escaped provider text rather than invented timestamps.
- Opening a conversation replaces the results with a dedicated reader on the normal
  shared glass, with no separate opaque fill. Inherit the stage's text treatment; retain
  the accessible Canvas background in forced colors. Do not add a new dashboard shell.
  Use comfortable Space Grotesk body type (currently 18px desktop / 17px narrow), relaxed
  line spacing and a bounded reading measure (currently 68ch). Long tokens wrap; narrow
  screens reduce padding rather than shrinking body type below that starting point.
- Show one conversation heading. Earlier messages use native expandable sender/date
  summaries; the latest message starts expanded and the reader begins at that reply.
  Differing subjects remain visible within their messages. Full sender/recipient/raw-date
  metadata has its own disclosure. Preserve quoted history/signatures as escaped text;
  no automatic trimming, HTML rendering, remote content or mailbox writes. Attachment
  details stay within the message reader: show safe raster previews, metadata and explicit
  downloads; never render active document types. Fetch bytes only on demand with the 5 MiB
  bound and no persistent attachment cache (see [GMAIL.md](GMAIL.md)). Disclosure choices
  survive ordinary refreshes. Escape/idle preserves reader state.
- Back to results retains search/page and restores the opened row's focus and scroll
  position after the async list returns. Client navigation memory is ephemeral, bounded
  to one result context and reset on account/connection-generation/search/page changes;
  never persist bodies or queries in browser storage. Routine fetch freshness is compact
  and ages locally, with an exact timestamp disclosure. Loading/errors/stale-copy warnings
  stay explicit and announced; cached content must not imply a new successful fetch.
- Background activity and last-known integration health share a custom inline SVG signal
  family, not an icon pack: an orbiting ring for confirmed activity, checked ring for known
  healthy/local presence, dashed ring for unknown, pause ring for waiting, slashed ring for
  disconnected and triangle for attention. Never animate unknown/unconfirmed outcomes or imply
  a live provider check. Routine labels (including Gmail last-success timestamps) move into
  keyboard-focus/hover details with accessible names; embedded signals reuse their native link's
  focus instead of adding nested tab stops. Details fit the content/viewport, remain hoverable,
  and Escape dismisses them without entering scenery. Errors, stale warnings, absent credentials
  and recovery instructions retain visible text. Home still omits routine healthy observations;
  Calendar/mail freshness and exact timestamps retain their existing behavior. Key presence or
  readability never verifies Google access. Action feedback and global navigation Topbar remain separate.
- Mail loading uses this indeterminate SVG on a transparent, reserved status line on the shared
  glass, never a filled warning box or invented percentage. Loading completion alone must not
  shift retained content. Reduced motion (including changes mid-load) and forced colors stop the
  orbit, preserving its static shape. Keep polite accessible status names and separate unfilled
  warning edges for actionable errors/stale states.
- Scenes shows only the setup information card until the initial local credential check
  confirms a stored Gemini key. Missing, initial/unknown, locked, invalid and unavailable
  states never show the direction editor, generation controls, gallery, attempt history
  or dialogs. Keep each status honest: an unsuccessful check is not proof that the key is absent.
  The card links to `/connections/gemini` and retains earlier-request/possible-charge and
  local-read failure warnings. Do not delete saved scenes or attempts.
  Refresh from a previously confirmed stored-key state keeps the editor, disclosure,
  draft and focused Refresh trigger mounted during local revalidation. Announce checking,
  suppress repeat refreshes, clear cost confirmation and disable provider/recovery actions;
  the earlier stored-key observation is not authorization while checking. A failed/missing
  result returns to setup-only. Only a fresh stored-key result restores operational controls;
  it never claims verified Google access. Opening/refreshing Scenes checks only local key
  availability and local scene state; bundled scenery remains usable without Gemini.
- Scenes opens with guided **Scene direction** choices for subject, setting, light and
  palette. Save persists the app-wide default for future manual and already opted-in startup
  generations; it never generates, probes credentials or changes startup opt-in. An expandable
  exact prompt updates with edits and preserves its open state across patches. Unsaved edits
  remain distinct from the active default and must be saved or discarded before generating.
  Refresh/status/background patches and Escape/idle wake preserve the draft. Show save/load
  failures inline; never silently generate with a different fallback. The initial configured
  prompt stays active until the first explicit save. Confirmation exposes and pins the exact
  reviewed prompt, refusing a changed default without reserving or requesting generation.
- Scenes keeps all published local images, with no total count cap; the gallery shows
  20 per page with native Newer/Older controls. Dates when known, the actual active background
  and latest-attempt states stay honest. Refresh status only reads local state.
  Confirmed manual requests have no daily cooldown, including after a failed/successful
  attempt; the persisted 24-hour cooldown applies to automatic startup only. An unconfirmed
  reservation blocks manual requests to avoid overlap, with an explicit explanation rather
  than an invented completion time. Disabled controls use a normal cursor, not a waiting cursor.
  Use scene changes the app-wide background and persists across reloads; a new successful
  generation becomes active. Missing/corrupt previews cannot be selected. Generate opens a
  native confirmation dialog warning that each request can incur charges, even with failed
  or unknown outcomes, and that there are no automatic retries. Cancel/Escape restores trigger focus and
  does not request generation. Confirmed work survives navigation; startup opt-in remains
  independent. Preserve modal idle/focus behavior and gallery selection during scenery wake.
- Meaningful views have URLs: `/workspaces`, `/workspaces/:workspace_id`, its `/integrations`
  setup panel, `/accounts/:account_id/mail`, and workspace-scoped
  `/workspaces/:workspace_id/accounts/:account_id/mail`. Readers append `/threads/:thread_id`.
  Submitted searches use `q` and Gmail pagination uses `page_token`; both remain in reader URLs
  for returning to results. Search text is consequently visible in browser history/copied links,
  but is filtered from Phoenix parameter logs. Connections URLs have no workspace context.
  Obsolete/irrelevant query parameters are removed with history replacement; old root-query
  navigation bookmarks still resolve to canonical paths. Consent/credential feedback queries
  carry only safe status categories and are consumed on entry. Scenes uses `/scenes?page=N`
  (page one omits the query).
- Navigation adds browser history; Back/Forward reapply the URL without remounting the shared
  stage. Reload/new tabs resolve the same view, subject to current account/workspace access.
  Invalid/unavailable destinations recover visibly to Workspaces rather than retaining another
  account's content. Dialogs, unsaved drafts, disclosures, scenery focus and idle state are not
  URL state. There is no cross-tab directory synchronization.
- Loading, empty, stale, offline, expired-credential, rate-limited and failed states must
  remain truthful and distinguishable. Account context stays explicit in mail views;
  disconnected integrations must not appear operational. Detailed Gmail boundaries live
  in [GMAIL.md](GMAIL.md).

## Images, accessibility and preferences

- Authenticated `/settings` offers exactly **Charcoal**, **Earth**, **Sea Glass**, and **Mist**
  as native radio choices. Use compact cards in one four-option row on desktop (1024px and
  wider), two columns on tablet and one column at 640px and below. Each card contains only
  its swatch, name and native radio; retain visible selection and keyboard focus. Changes apply
  immediately to the entire UI, including mail,
  dialogs, status signals and static unlock; they never select, recolor or generate scene imagery.
  Selection stays in this browser's `localStorage` under `lovelace:theme`, not an account or database.
  A synchronous self-hosted bootstrap restores the allowlisted choice before CSS paints; missing or
  invalid values use Sea Glass. Without JavaScript the default remains usable. If browser storage
  is denied, apply the choice only to the current document and announce that it could not be saved.
  Patch navigation, reload and browser history preserve the selected palette; separate already-open
  tabs do not synchronize live. Forced colors uses system colors instead of the palette.
- Reveal a generated image only after it successfully loads. Failed loads leave the
  installation's local bundled JPEG default, not a broken-image replacement. Three
  owner-approved images ship locally; choose one once per installation, preserving it
  across reload, navigation and scenery wake while unlocked. Locked owner pages use
  the first bundled image instead, without reading encrypted preferences; the transition
  across unlock/Lock may change imagery. Keep generated imagery restricted to validated
  same-origin PNG/JPEG digest routes and bundled imagery to the exact asset allowlist;
  no provider-hosted/arbitrary URL substitution. Defaults are not generated gallery
  entries. Rendering only reads local preferences; it never initializes or generates.
  Generation and default-choice persistence rules belong in `STAGE_DESIGNER.md`.
- Preserve native keyboard operation, meaningful headings, labels, validation associations,
  announced errors/status and visible focus. Decorative branding is hidden from assistive
  technology; a persistent screen-reader heading supplies the page name separately.
- Reduced motion skips entrance/exit choreography, including preference changes mid-animation,
  while still completing the gate/focus handoff once. Forced colors removes scenery/blur/
  dimming but preserves the entered/focused visibility rules for Lock.
- Keep layouts usable at desktop and narrow widths; long messages remain readable. Source
  assertions and fake-DOM tests do not establish rendered contrast, focus or accessibility.

## Verification map

Use native Node and synchronous LiveView/ConnTest suites plus the explicit
`LOVELACE_STAGE_ENABLED=false bin/lovelace mix test.ui` Chrome/Chromium regression
gate. No real mailbox, real credential or billable provider calls are needed. Native
keychain creation/cancellation/resume verification is a separate, explicitly attended
disposable-keychain check, never an unattended CI prompt. See [DEVELOPMENT.md](DEVELOPMENT.md)
for commands. Report actual executed results and unrun checks in the task response;
historical results do not certify a new change.

- `test/js/brand_reveal_test.mjs`: choreography, interruption/replay, reduced motion and teardown.
- `test/js/first_run_entrance_test.mjs`: once-per-tab-session presentation state, unavailable
  storage, first-eligible-visit/reload behavior, static input gating/focus, reduced motion,
  Escape and pagehide cleanup.
- `test/js/workspace_entrance_test.mjs`: gate completion, immediate return handoff,
  focus safety, patch continuity and teardown. Brand tests cover both return-hook mount orders.
- `test/js/theme_picker_test.mjs`: persisted selections, corrupt/prototype-named values, unavailable
  storage, failed writes/recovery, patch/remount continuity and listener teardown.
- `test/js/ui_browser_runner_test.mjs`: early normal/signal Chrome exit must fail promptly,
  not hang on an already-fired event or report success; no real browser/app is launched.
- `test/js/workspace_idle_test.mjs`: elapsed-time/activity/wake rules, patches/hidden tabs,
  modal idle suspension/resume, timer cleanup and shared static/live image-load observer.
- `test/js/native_modal_test.mjs`: opening/focus, sticky open state, Escape isolation,
  server-owned dismissal, listener cleanup and focus restoration (including disabled triggers).
- `test/lovelace_web/components/status_components_test.exs` and `test/js/status_signal_test.mjs`:
  custom SVG states, accessible names, visible warning text, link focus reuse, detail dismissal,
  boundary placement, patch transitions and listener teardown.
- `test/js/calendar_agenda_test.mjs`: browser-local midnight/DST boundaries,
  midnight/resume/reconnect notifications, event local-time/ongoing labels and teardown.
- `test/js/onboarding_calendar_test.mjs`: actual controller-page initializer with fake
  DOM/fetch/clock, browser-local POST fields, identity races, selection/focus continuity,
  duplicate/late requests, teardown, owner redirects and bounded status-only recovery.
- `test/lovelace/calendar_test.exs` and `test/lovelace_web/live/calendar_live_test.exs`:
  account/context/generation fencing, selection, bounded/truncated results, cooldown,
  freshness/retention, escaped render-local events and exclusive Connections navigation.
- `test/lovelace/integrations/google_calendar_test.exs` and
  `test/lovelace_web/controllers/google_calendar_oauth_test.exs`: read-only requests,
  strict provider parsing, explicit optional scopes, identity/generation-bound consent
  and refusal of late callbacks across disconnect/reconnect.
- `test/lovelace/github_test.exs`, `test/lovelace/github_auth_test.exs`,
  `test/lovelace/integrations/github_test.exs` and `test/lovelace_web/live/github_live_test.exs`:
  account/owner/repository isolation across PR/issues/Actions, immutable identity including
  empty results, editable independent workspace selections, single-use PKCE authorization,
  cancellation/revocation/disconnect/client-generation fencing, one-shot refresh reservations,
  legacy credential cleanup, cooldown/expiry, honest optional-permission/partial/error readouts,
  failed-auth recovery, credential-deletion retry and provider/workspace navigation.
  `test/lovelace_web/controllers/github_credentials_test.exs` covers early client-settings/intent
  POSTs and callbacks, CSRF/revoked sessions and secret scrubbing; transport tests enforce
  fixed destinations and bounded read-only payloads. Synthetic keychain tests cover service isolation.
- `test/js/home_readouts_test.mjs`: local greeting/date, timestamp aging, patched failure
  metadata, resume updates and timer/listener teardown.
- `test/js/mail_reader_test.mjs`: async reader focus/latest-reply handoff, exact return
  scroll/focus, context fencing and teardown; local date formatting and independently
  aging fetch freshness, patched attributes and timer/resume-listener cleanup.
- `test/lovelace_web/live/navigation_live_test.exs`: native deep links, global provider
  overview, obsolete-query/bookmark normalization, workspace history, direct account/thread/search/page entry, reload-equivalent mounts, URL
  transitions, invalid/unavailable recovery and account fencing. Owner controller/auth tests
  cover safe requested destinations through unlock and reject unsafe/form-injected returns.
- `test/lovelace_web/workspace_return_test.exs`: exact one-use redirect destinations,
  expiry/session binding, early callback/credential returns, connected mounts, ordinary
  reloads and locked/revoked denial. Return markers never bypass owner guards.
- `test/lovelace_web/live/home_overview_live_test.exs`: distinct connection summaries,
  shared/unattached membership, paired total/recent unread metrics, unknown/zero/stale counts,
  Home navigation and account isolation.
- `test/lovelace/stage_designer/bundled_scenes_test.exs`: fresh-database default reads,
  immutable initialization across connections/restarts and concurrent boots, authorization,
  pinned JPEG hashes/validation and independence from generated scenes/reservations.
- `test/lovelace_web/live/scenes_live_test.exs`: exclusive Scenes navigation, truthful
  empty/missing/unconfirmed states, immediate manual eligibility after success/failure,
  confirmed-only requests with safe fake-vault failure, paginated access to all saved images,
  persistent selection and app-wide stage updates; guided prompt preview/save/discard,
  reload persistence, draft-safe refresh and stale-confirmation refusal. Backend scene/coordination tests cover
  reservation policy, selection during generation, duplicate output and publication/notification exclusion.
- `test/lovelace_web/live/home_live_test.exs`: shell, client commands, accessible/decorative
  branding, Lock POST/token structure, image URL allowlist and stage updates.
- `test/lovelace_web/live/workspaces_live_test.exs`: persistence, validation and unsaved-form
  preservation in dialogs; navigation emits heading-focus events while modal dismissal
  leaves trigger focus restoration to its hook; rejected saves keep the modal open.
- `test/lovelace_web/live/gemini_connection_live_test.exs` and
  `test/lovelace_web/controllers/gemini_credentials_test.exs`: safe presence/failure states,
  ordinary POST forms, auth/revocation/CSRF, bounded input and secret-free Phoenix telemetry.
  Backend credential tests cover owner-only actions, validation, exception containment,
  separate Keychain framing and refusal by an outdated helper; tests use fake vaults only.
- `test/lovelace_web/live/mail_live_test.exs` and `connections_live_test.exs`: workspace/account
  navigation, management effects, explicit OAuth context and stale async/PubSub isolation;
  single-title reader/native disclosures, escaped bodies/metadata, result-context resets
  and retention of search/page on return without provider payloads in socket assigns.
  Credential-check tests cover local-only safe results, account/generation fences,
  denied actors, native error sanitization and unchanged persisted sync metadata.
- `test/lovelace_web/controllers/owner_controller_test.exs`: static unlock/setup, session
  revocation and real CSRF enforcement on Lock (missing/invalid denial, valid token acceptance).
  Asset tests pin local vendor/font files and retained licenses.
- `test/browser/ui_contract.mjs`, launched by `test/support/ui_browser.exs`: actual browser
  entrance/directional exit/gate and focus; already-unlocked OAuth/credential returns
  without activation, one-use reload behavior and Escape/wake; Home/Lock computed visibility/focusability; static
  stage with/without JS; static/live image success/failure; wheel-scrolled stationary Lock/Escape
  rail with independently scrolling navigation at desktop/laptop/narrow widths and forced colors,
  including reserved-band non-overlap and entrance gating; native menus; workspace/account/
  Connections navigation; workspace modal focus/inertness, Escape-only cancellation,
  idle draft preservation, save/cancel focus restoration, first-click activation and scroll preservation;
  keyboard local credential checks, timestamped unverified-Google results and Keychain
  help without credential disclosure or horizontal overflow; five compact Gmail rows
  and the new-connection modal's required workspace choice,
  Cancel/Escape focus and desktop/narrow/forced-color layout; title-row provider subnav,
  keyboard switching with focus retained, mutually exclusive provider interfaces, compact primary-view
  spacing and cards, keyboard-accessible provider help disclosures with visible health, scenery
  wake preserving selection and credential POSTs returning to Gemini;
  Gemini's ordinary credential POST to a fake vault, empty return form and truthful key state;
  compact side-by-side Home readouts at desktop/laptop widths, stacked tablet/narrow readouts,
  no routine checked statuses or Home Calendar Refresh, retained stale warnings and workspace controls,
  unknown unread labels, compact empty Home and direct Calendar setup;
  optional Calendar Home/workspace agendas with safe explicit links, Google-selected and
  shared-calendar selection, exclusive Calendar Connections and ordinary consent POSTs,
  desktop/narrow/forced-color Calendar layouts and fixture screenshots;
  an empty-installation pass with the actual bundled defaults, no generated images,
  no-JS/static/live parity, decoded JPEGs and unchanged default across reload/navigation/wake;
  scheduled idle expiration with a shortened disposable DOM timer; mid-reveal reduced motion;
  forced colors; desktop/narrow inbox/reader layouts; long-token wrapping and body type;
  native message/metadata disclosures and refresh preservation; reader Escape/wake;
  async browser-Back row-focus/scroll restoration; real URL Back/Forward, global Connections overview/provider
  navigation, obsolete-query cleanup and direct Gemini reload, workspace reload and copied conversation/search/page links; real delayed loading transparency, stable status
  height and ordinary/reduced-motion/forced-color SVG activity behavior, including mid-load preference
  changes; compact health detail focus/hover, Escape-only dismissal, static health shapes and
  desktop/narrow/forced-color tooltip screenshots; Scenes guided direction preview/save/discard,
  draft preservation through refresh and scenery wake, exact confirmation prompt and saved
  direction reload, desktop/narrow editor screenshots; Scenes keyboard navigation, gallery dates/previews, confirmation Cancel/Escape
  and focus restoration, read-only refresh, cross-tab selection, reload persistence, narrow
  and forced-color gallery/dialog layouts; all four keyboard-selected Settings themes on Home,
  Workspaces and mail, reload/history persistence, unchanged imagery, narrow/forced-color picker
  layouts and the protected Settings deep link; real GitHub attention counts across all
  four palettes, AA contrast on base surfaces, semantic hue separation, narrow/forced-color
  labels and screenshots; off-origin requests, page errors and CSP events.

The browser gate is separate from `mix check`/hosted CI and requires an installed browser;
it fails rather than silently skipping when unavailable. See development guidance for its
isolation and deadlines. Native Node tests cover the actual three-minute timer, hidden/sleep
elapsed time, patches and animation interruption/replay deterministically. The browser suite
is not exhaustive: real tab suspension/sleep, Escape during every animation phase, full
keyboard tab-order traversal, contrast measurements and aesthetic evaluation of long-message
reading still merit manual review. Browser/aesthetic approval, assistive-technology testing, cross-browser checks
and hosted CI are distinct evidence, not claims inferred from these suites.
