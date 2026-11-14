# MONOLITH — operational UI and interaction contract

[MONOLITH_DESIGN_SYSTEM.md](MONOLITH_DESIGN_SYSTEM.md) is the single production
presentation authority across all routes. This document retains product, operational,
security, account, route and lifecycle boundaries; it does not define an alternate
palette, identity or component system. Keep durable product/safety rules in
[AGENTS.md](../AGENTS.md). Verify consuming code and report actual checks separately:
the coverage map is not evidence that checks passed.

## Direction and shared stage

- Use the canonical MONOLITH identity and single working plane defined by the design
  system: transparent content, white hover frosting and light controls. Preserve readable
  account-separated content over scenery, including empty, loading and error states.
- All application routes share the same presentation authority, including static
  setup/unlock, directories, provider pages, mail, Calendar, GitHub and Scenes.
  Account-letter register codes are deliberately omitted; retain numbered sections
  and adjacent full account/address or installation identity.
- Keep health and actionable warnings visible; Home omits freshness labels.
  Occasional setup, billing-policy and disconnect guidance can use native disclosures,
  but billing confirmation remains explicit before generation. Semantic warnings/errors stay distinct.
- Scripts/fonts/imagery are local, with applicable licenses, provenance and checksums for
  vendored assets. No runtime CDN, font service, remote browser imagery, animated scenery
  or parallax. Server-side opted-in Gemini output is validated and served locally;
  generation/cost/storage rules belong in [STAGE_DESIGNER.md](STAGE_DESIGNER.md).

## Action hierarchy

Choose emphasis by intent, not by provider, page, or whether the element is a link or button.
Use the same hierarchy on static setup/unlock pages and authenticated views.

| Intent | Treatment | Shared class | Examples |
| --- | --- | --- | --- |
| Main next step | Filled primary treatment | `workspace-action workspace-action-primary` | New workspace, Connect Google, Save selection, dialog confirmation |
| Supporting operation | Neutral outline and quiet fill | `workspace-action` | Refresh, Check Keychain, Search, Download, Cancel |
| Contextual navigation | Underlined accent text, no box | `workspace-action workspace-action-link` | All connections, Back to results, Manage connections, URL pagination, external setup documentation |
| Destructive operation | Error-colored outline and explicit wording, never an accent fill | `workspace-action workspace-action-danger` | Remove from workspace, Disconnect everywhere, Remove API key |
| Contextual management operation | Neutral unboxed row | `workspace-action workspace-action-quiet` | Visible workspace Rename, integration menu commands |

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
  Provider-wide help and billing/disconnect disclosures sit in the provider's right context
  column, stacked after the main plane on narrow screens, not inside an individual setup card.
  Gmail's About Keychain access and Removal & disconnecting disclosures share that
  context column; account actions and their diagnostic results stay in the main plane.
  Keep current credential health, actionable warnings and brief cost/startup notices visible
  with their controls; moving policy details must not hide consent or billing confirmation.
- Back/manage/reconnect navigation is a text link; actually submitting authorization is an
  operation. New connection forms use primary submit; repeated existing-account reconnect
  operations stay secondary. Optional onboarding continuation/skip is secondary when a setup
  action is offered; refresh/load is secondary, never another accent-filled CTA.
- Keep sidebar/provider navigation and large workspace/account/provider destinations
  as native links with current-state indicators, not command buttons.
  Links embedded in prose stay underlined and inherit readable body sizing.
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
  Standalone action links use the shared 14px action size across views, including
  header returns and GitHub activity links; inline prose/content links retain their own typography.
  Inline prose links are not padded into buttons. Secondary hover stays neutral; accent is
  reserved for primary actions and navigation. Disabled actions do not gain hover emphasis.
  Use semantic tokens and system colors for operations/navigation in forced colors;
  do not rely on color alone to explain a destructive action.
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
- This is **visual scenery mode, not authentication, Lock or a privacy guarantee**.
  Explicit **Lock** revokes all owner sessions, stops protected background work, closes
  the encrypted Repo and locks the dedicated credential keychain. Visual focus changes
  do not. Startup requires password unlock before protected persistence/jobs start;
  there is no password recovery or public/unpaired signup.
  Detected native keychain authorization/access failures trigger the same global Lock,
  including session disconnection and protected-work shutdown; missing individual
  credentials and locally invalid input do not. This is access-time detection, not
  continuous monitoring of macOS authorization.

## Entrance, gate and persistent identity

- Entrance uses the authored MONOLITH mark and eight-letter wordmark choreography
  defined by M03/M11 of the design system. Decorative motion must not own business
  controls or change authentication. Working content becomes interactive after handoff.
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
  Newer control focus, including assistive-technology focus without pointer/key input,
  cancels a pending destination-heading handoff.
- Keep native Web Animations ownership confined to the decorative `phx-update="ignore"`
  brand subtree; business controls/content stay outside it. Cancel animations and remove
  listeners/media-query handlers on teardown; patches must not restart choreography.
- The in-flow collapsible sidebar and its focus/keyboard behavior follow M06.
  Lock is a real CSRF-protected POST at the top right of each working page header,
  including inbox, conversation and GitHub activity headers, never scenery mode.
  Preserve entrance gating and prevent hidden/collapsed controls from receiving focus.
  Escape prioritizes an open modal, then expanded navigation, before visual scenery.
- Static unlock/first-run setup pages share the stage, using only a fixed public bundled
  fallback while locked; protected generated imagery and the persisted bundled choice become
  available only after unlock. Unlock stays focused without an entrance or idle timer.
  Unlock submission fills the password field's width. Rejected passwords retain the styled
  unlock page, an alert linked to the invalid field, and no echoed password. Omit the redundant
  visible Locked label while retaining an accessible unlock heading.
- Successful unlock automatically plays the entrance on the requested protected destination,
  without a second activation click. Its destination-matched session intent is consumed by
  the first protected GET; it grants no authorization and does not skip the inert gate.
- Before the first eligible setup/onboarding visit in a tab's browser session, automatically
  play the centered MONOLITH entrance/exit before exposing the pairing form, then focus the
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
- Setup and onboarding use a horizontally centered, left-aligned column capped at
  620px. Keep the orientation heading outside the compact form plane. The five
  navigation groups are Workspace, Google, Gmail, Calendar and Review; preserve all
  eight real steps and the detailed Desktop OAuth guide within that structure.
  Every onboarding step starts at the same 48px top inset, independent of content height
  or viewport width; shorter steps must not vertically center.
  Narrow screens retain side padding and independently scrolling instructions without horizontal overflow.
  Continue and Skip share one action row at desktop and narrow widths: Continue on the
  left, Skip on the far right. Labels may wrap within controls; do not move Skip onto a
  separate row. Use **Skip Google**, **Skip Gmail**, and **Skip Calendar** consistently.
  Use **Continue** for every intermediate primary action, **Use saved client** for the
  saved-credential alternative, and **Finish setup** only on the final review page.
  Omit bottom Back links; the step navigation remains available for revisiting earlier steps.
- Step navigation remains available without repeating a second page heading inside
  the form plane. Pairing uses the same compact reading measure and responsive padding.

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
- The sidebar contains Home, Workspaces, Connections, Scenes and Settings in numbered
  order. Lock lives in the page header, outside the sidebar. Destinations are native links using LiveView patches and
  usable `href`s for copying/new tabs; current destinations use `aria-current`.
  Connections always opens global `/connections`, without workspace query or return
  context. Browser Back retraces the origin. Gmail inboxes have no redundant Home button.
- Home opens with **A day in focus.** and a browser-local date updated across
  midnight/resume. Primary views share the directory alignment and width.
  Keep copy functional, without repeated greetings, clocks, message previews,
  aggregate account totals or speculative widgets. Unread totals are labeled **unread**.
- Home pairs account-separated Gmail and browser-local Calendar readouts, with
  GitHub below; responsive composition, numbered headings, joined glass and semantic
  rhythm follow the design system. Keep timezone/context beside the corresponding
  heading and full account identity beside observations, wrapping without clipping.
  Home omits routine successful-check statuses, freshness/stale labels and Calendar Refresh
  controls. Keep loading, Calendar error and partial-result warnings; detailed inbox/Connections
  timestamps and Calendar workspace refresh remain unchanged.
  Unknown unread totals use a dash with an accessible unavailable label, never a fabricated zero.
  Calendar setup is a compact empty state linking directly to Connections → Calendar.
- Gmail cards appear once per non-disconnected connection, including connections with no
  workspace membership. Each shows identity, workspace names and paired unread inbox
  conversation counts labeled **UNREAD / LAST 24H**, with explicit accessible context for both values.
  Labels sit above values with an 8px gap and share the GitHub metric-label default:
  Space Grotesk 400, 13px/1.55, uppercase with normal tracking.
  The recent value uses Gmail received-time search over a fixed rolling 24-hour window,
  not a local calendar day or partial cached page. Both observations are committed together;
  incomplete paging/failures retain the previous pair as stale. See [GMAIL.md](GMAIL.md) for bounds.
  Gmail account readouts on Home and workspaces omit age/stale indicators from the component;
  underlying observations retain their timestamps. Clicking a card opens only that account's
  read-only inbox without attaching it anywhere.
  Home and workspace account readouts omit the redundant “Open account inbox” prompt;
  the account identity remains the inbox navigation target for every account.
  Home also omits connection-warning copy below email counts; workspace warnings and
  Connections recovery links remain available.
- Unknown counts are not zero. Failed updates retain known counts as stale; elapsed time
  marks observations stale after three minutes, independent of unrelated mail-page success.
  Home rendering reads persisted metadata, never provider calls or cached message content.
  Empty/loading/error/reconnect states remain explicit, with recovery through Connections.
- Missing-content states retain a small decorative service icon, regular-weight heading,
  short explanation and relevant next action on the shared working plane.
  Keep actions at least 44px high, with wrapping labels
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
  remain visible, and credential modals keep their ordinary protected POST boundary.
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

- GitHub adds a full-width **GitHub** section beneath Gmail/Calendar, grouped by
  personal/organization installation owner, never merged with mail or another owner.
  Home uses condensed, full-width per-owner registers with full installation identity
  and aggregate snapshot metrics in the owner header. Counts and repository rows
  follow the union of that owner's saved workspace repository selections, deduplicated
  by immutable repository ID. Any whole-owner membership includes all accessible
  repositories; an unattached owner retains its accessible snapshot.
  Each owner title is an independent repository disclosure button, initially collapsed,
  with truthful expanded state and a controlled repository section. There is no separate
  Repositories row. Header metrics and plain-text workspace labels stay visible when collapsed.
  Repository names are indented beneath their owner, retain their full owner/name and wrap
  rather than truncate. The GitHub section header has no Repository snapshots subtitle.
  Each row shows only its immutable repository ID's PR, issue and run snapshot counts;
  an accessible repository with no matching rows shows zero only for a complete
  observation of that activity kind, otherwise a dash. A missing repository catalog
  retains header snapshot counts without inventing rows.
  Snapshot metric labels are **PRS / ATTENTION**, **ISSUES**, and **RUNS / FAILED**.
  PRs and runs pair the main count with the attention/failure count as `total / attention`,
  using distinct semantic ink and visible accessible labels, not tooltip-only explanations.
  Accessible metric descriptions retain snapshot scope.
  Count each PR needing review or failing checks once. Unknown/unavailable or expired
  counts use a dash, never a fabricated zero. Home omits per-owner status, partial-result
  messages and last-checked timestamps; workspace details retain health, freshness and
  partial-result context. Home has no Refresh buttons or detailed activity lists.
  Workspace names are noninteractive labels; activity remains available from Workspaces.
  Unattached owners offer **Add to workspace** through Connections.
  Workspace activity and its Refresh controls remain expanded and available.
  Detailed bounded pull requests, issues and runs retain repository, escaped title,
  author, explicit review/check/run state, safe new-tab links and UTC update times.
  No remote images, repository contents, workflow logs or artifacts. Preserve partial,
  stale/error/expired observations; incomplete results never imply an empty success.
  Connections → GitHub keeps the client settings modal trigger, session-bound OAuth
  browser sign-in and account disconnect in the main account plane. Its
  registration/permissions/callback guide belongs in the right context column.
  Saving settings is local-only, never provider verification. Secrets are never prefilled
  or returned. Hide sign-in while settings are missing, checking, locked or unavailable;
  locked/unavailable reads show an actionable keychain warning, never missing-settings setup.
  Failed sign-in remains a usable recovery page. OAuth uses single-use state and PKCE.
  Do not mount the setup guide or credential-modal trigger until the local settings check
  settles. The guide starts collapsed for both missing and stored settings. GitHub's context
  disclosures use native leading markers and plain, non-underlined summaries, matching
  Keychain checks and recovery; preserve later toggles. Credentials open only on explicit activation.
  Saved app settings without an authorized account explicitly show that sign-in is still
  required. Ready account cards show Connected from persisted account state across reloads,
  never from the settings-save flash or an expired browser authorization attempt.
  Separate **Choose repositories on GitHub** (installation access) from **Connect GitHub
  account** (MONOLITH authorization). Rejected returns show a specific, safe inline
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

- Workspaces represent areas of life. Destination links and always-visible Rename
  text buttons are siblings, never nested controls. Rename opens its dialog directly,
  not through a workspace menu. Integration management menus remain separately scoped.
  Create/rename use native modal dialogs with contained focus, labelled headings and inline
  validation. Cancel/Escape closes only the dialog, restoring focus without entering scenery
  mode. Unrelated patches preserve the draft; invalid submissions keep the dialog open.
  The visual idle timer pauses while a modal is open and resumes on dismissal;
  this is not an authentication or privacy change.
  Google/Gemini/GitHub credential dialogs reuse the native shell but open and dismiss
  locally. They retain browser-only unsaved drafts through dismissal and unrelated patches;
  native protected POSTs never return stored secrets. Inactivity pauses only while open,
  and removing a closed editor during navigation must not steal destination focus.
- Workspace cards pair their destination and Rename with truthful integration metadata.
  Workspace detail exposes **Add integration** and Rename as page actions. The focused
  integration page has one heading and a named return to its workspace, not a duplicate
  workspace editor. Account readouts remain independent and follow current observations.
- `/connections` is a quiet provider overview with Google, Gmail, Calendar, Gemini and GitHub links and
  short purpose labels, not a default Gmail page or combined health dashboard. It mounts
  no provider form and makes no Keychain/provider probe. Opening a provider focuses the
  heading; each provider offers **All connections** back to the overview.
- Provider pages have a **Google / Gmail / Calendar / Gemini / GitHub** subnav below
  the title, with only the selected provider mounted. Main content and contextual help
  stay transparent in a 1.6:1 split, stacked at narrow widths. GitHub's authorized
  accounts and joined installation-owner list retain separate ruled planes; primary
  empty/error state copy also stays transparent over the app-wide scenery treatment.
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
  not verified Google access. Setup help sits in the right context column. Saving makes no provider request.
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
  safe error categories and an observation timestamp; never expose the token.
  While a check or disconnect cleanup blocks account actions, show a shared explanation
  naming the account and operation; associate every affected disabled control with it.
  Remove that explanation and association once the operation settles.
  Explain that an unlocked keychain can still deny item access and a readable token does not
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
  **All accounts** navigation. The shared shell alone owns the top inset; fresh account
  navigation focuses its heading without scrolling the register or Lock out of view.
  Match the study's compact account/search header and full-width, uninset result rows.
- Inbox lists, toolbars and status regions remain transparent at rest. Only the hovered
  inbox row gains the study's inset surface; neighboring rows do not change.
  Rows keep the sender, prominent subject and muted preview in one column, with
  the date at the far right (below the copy at ≤440px). Unread uses a visible marker
  plus stronger text, with an accessible unread label; not color alone.
  Parseable message dates use browser-local compact labels, with full dates available;
  unparseable dates remain escaped provider text rather than invented timestamps.
- Opening a conversation replaces the results with a dedicated transparent reader,
  without a persistent card fill or outer card frame. Inherit the stage's text treatment;
  retain the accessible Canvas background in forced colors. Do not add a new dashboard shell.
  Use comfortable Space Grotesk body type (currently 18px desktop / 17px narrow), relaxed
  line spacing and a bounded reading measure (currently 68ch) within a centered 76ch
  reader. The subject uses the study's 32–52px hierarchy, not the larger directory
  display preset; narrow screens retain 17px body text without an extra padded card.
- Show one conversation heading. Earlier messages use native expandable sender/date
  summaries; the latest message starts expanded and receives focus. Mouse-opened mail
  must not paint that summary as selected; keyboard interaction retains visible focus.
  Preserve the subject when that summary already fits, otherwise scroll only enough to expose it
  below the account/return context. Refresh and observation share that normal-flow context
  rather than a second toolbar above the subject; it must not overlap scrolled mail.
  Search belongs to results, with its query preserved on return.
  Differing subjects remain visible within their messages. Full sender/recipient/raw-date
  metadata has its own disclosure. Preserve quoted history/signatures as escaped text;
  no automatic trimming, HTML rendering, remote content or mailbox writes. Attachment
  details stay within the message reader: show safe raster previews, metadata and explicit
  downloads; never render active document types. Fetch bytes only on demand with the 5 MiB
  bound and no persistent attachment cache (see [GMAIL.md](GMAIL.md)). Disclosure choices
  survive ordinary refreshes. Escape/idle preserves reader state.
- Back to results and browser Back retain search/page and restore the opened row's focus
  and scroll position after the async list returns, including after reader Escape/wake.
  New keyboard, pointer, input or control-focus intent cancels that pending handoff;
  a later navigation starts fresh rather than inheriting the cancellation. Preserve
  the result memory through repeated Back/Forward traversal. Client navigation memory is
  ephemeral, bounded to one result context and reset on account/connection-generation/
  search/page changes; never persist bodies or queries in browser storage. Routine fetch freshness is compact
  and ages locally, with an exact timestamp disclosure. Loading/errors/stale-copy warnings
  stay explicit and announced; cached content must not imply a new successful fetch.
- Background activity and last-known health use the six canonical decorative SVG
  signals with always-visible status labels, as specified in M07. No separate
  focusable signal or hover/focus-only status tooltip is required.
  Only loading implies an active read; unknown animation must not imply polling.
  Errors, absent credentials and recovery instructions remain visible. Shared Gmail
  account summaries omit age/stale indicators; detailed inbox and Calendar stale warnings,
  freshness and exact timestamps retain their operational behavior. Home may omit routine
  healthy observations. Key presence/readability never verifies Google.
- Mail loading uses an indeterminate signal on a transparent reserved status line,
  never a filled warning panel or invented percentage. Loading completion must not
  shift retained content. Reduced motion and forced colors retain complete static
  shapes; keep polite status announcements and separate actionable stale/error text.
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
- Confirmed-key Scenes uses balanced direction/generation and current-preview columns,
  with the gallery below. Setup-only states remain compact rather than reserving an
  empty preview column.
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
- Settings saves startup opt-in through Ash; an absent preference is off.
  Environment configuration must also allow new automatic work:
  `MONOLITH_STAGE_ENABLED=false` vetoes it without cancelling authorized jobs.
  Saving never generates, probes credentials or changes cooldowns. Manual generation
  remains independent and freshly confirmed.
- Meaningful views have URLs: `/workspaces`, `/workspaces/:workspace_id`, its `/integrations`
  setup panel, `/workspaces/:workspace_id/github/:organization_id`,
  `/accounts/:account_id/mail`, and workspace-scoped
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

- Settings offers a browser-local 1–60 minute visual inactivity preference under
  `monolith:idle-minutes`, with a three-minute default (or configured default).
  Storage failure must not claim persistence. This preference neither locks the app
  nor generates imagery. Startup opt-in is separately persisted through Ash.
  There is no theme picker, palette bootstrap or account-owned UI palette.
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
`MONOLITH_STAGE_ENABLED=false bin/monolith mix test.ui` Chrome/Chromium regression
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
- Preference regressions cover browser-local idle storage, invalid values, denied
  writes and lifecycle cleanup; startup tests cover owner-only persistence and environment veto.
- `test/js/ui_browser_runner_test.mjs`: early normal/signal Chrome exit must fail promptly,
  not hang on an already-fired event or report success; no real browser/app is launched.
- `test/js/workspace_idle_test.mjs`: elapsed-time/activity/wake rules, patches/hidden tabs,
  modal idle suspension/resume, timer cleanup and shared static/live image-load observer.
- `test/js/native_modal_test.mjs`: opening/focus, sticky open state, Escape isolation,
  server-owned dismissal, listener cleanup and focus restoration (including disabled triggers).
- `test/monolith_web/components/status_components_test.exs`: canonical decorative
  SVG states with visible accessible labels, rather than tooltip interaction.
- `test/js/calendar_agenda_test.mjs`: browser-local midnight/DST boundaries,
  midnight/resume/reconnect notifications, event local-time/ongoing labels and teardown.
- `test/js/onboarding_calendar_test.mjs`: actual controller-page initializer with fake
  DOM/fetch/clock, browser-local POST fields, identity races, selection/focus continuity,
  duplicate/late requests, teardown, owner redirects and bounded status-only recovery.
- `test/monolith/calendar_test.exs` and `test/monolith_web/live/calendar_live_test.exs`:
  account/context/generation fencing, selection, bounded/truncated results, cooldown,
  freshness/retention, escaped render-local events and exclusive Connections navigation.
- `test/monolith/integrations/google_calendar_test.exs` and
  `test/monolith_web/controllers/google_calendar_oauth_test.exs`: read-only requests,
  strict provider parsing, explicit optional scopes, identity/generation-bound consent
  and refusal of late callbacks across disconnect/reconnect.
- `test/monolith/github_test.exs`, `test/monolith/github_auth_test.exs`,
  `test/monolith/integrations/github_test.exs` and `test/monolith_web/live/github_live_test.exs`:
  account/owner/repository isolation across PR/issues/Actions, immutable identity including
  empty results, editable independent workspace selections, single-use PKCE authorization,
  cancellation/revocation/disconnect/client-generation fencing, one-shot refresh reservations,
  legacy credential cleanup, cooldown/expiry, honest optional-permission/partial/error readouts,
  failed-auth recovery, credential-deletion retry and provider/workspace navigation.
  `test/monolith_web/controllers/github_credentials_test.exs` covers early client-settings/intent
  POSTs and callbacks, CSRF/revoked sessions and secret scrubbing; transport tests enforce
  fixed destinations and bounded read-only payloads. Synthetic keychain tests cover service isolation.
- `test/js/home_readouts_test.mjs`: local date, timestamp aging, patched failure
  metadata, resume updates and timer/listener teardown.
- `test/js/mail_reader_test.mjs`: async reader focus/latest-reply handoff, exact return
  scroll/focus, context fencing and teardown; local date formatting and independently
  aging fetch freshness, patched attributes and timer/resume-listener cleanup.
- `test/monolith_web/live/navigation_live_test.exs`: native deep links, global provider
  overview, obsolete-query/bookmark normalization, workspace history, direct account/thread/search/page entry, reload-equivalent mounts, URL
  transitions, invalid/unavailable recovery and account fencing. Owner controller/auth tests
  cover safe requested destinations through unlock and reject unsafe/form-injected returns.
- `test/monolith_web/workspace_return_test.exs`: exact one-use redirect destinations,
  expiry/session binding, early callback/credential returns, connected mounts, ordinary
  reloads and locked/revoked denial. Return markers never bypass owner guards.
- `test/monolith_web/live/home_overview_live_test.exs`: distinct connection summaries,
  shared/unattached membership, paired total/recent unread metrics, unknown/zero/stale counts,
  Home navigation and account isolation.
- `test/monolith/stage_designer/bundled_scenes_test.exs`: fresh-database default reads,
  immutable initialization across connections/restarts and concurrent boots, authorization,
  pinned JPEG hashes/validation and independence from generated scenes/reservations.
- `test/monolith_web/live/scenes_live_test.exs`: exclusive Scenes navigation, truthful
  empty/missing/unconfirmed states, immediate manual eligibility after success/failure,
  confirmed-only requests with safe fake-vault failure, paginated access to all saved images,
  persistent selection and app-wide stage updates; guided prompt preview/save/discard,
  reload persistence, draft-safe refresh and stale-confirmation refusal. Backend scene/coordination tests cover
  reservation policy, selection during generation, duplicate output and publication/notification exclusion.
- `test/monolith_web/live/home_live_test.exs`: shell, client commands, accessible/decorative
  branding, Lock POST/token structure, image URL allowlist and stage updates.
- `test/monolith_web/live/workspaces_live_test.exs`: persistence, validation and unsaved-form
  preservation in dialogs; navigation emits heading-focus events while modal dismissal
  leaves trigger focus restoration to its hook; rejected saves keep the modal open.
- `test/monolith_web/live/gemini_connection_live_test.exs` and
  `test/monolith_web/controllers/gemini_credentials_test.exs`: safe presence/failure states,
  ordinary POST forms, auth/revocation/CSRF, bounded input and secret-free Phoenix telemetry.
  Backend credential tests cover owner-only actions, validation, exception containment,
  separate Keychain framing and refusal by an outdated helper; tests use fake vaults only.
- `test/monolith_web/live/mail_live_test.exs` and `connections_live_test.exs`: workspace/account
  navigation, management effects, explicit OAuth context and stale async/PubSub isolation;
  single-title reader/native disclosures, escaped bodies/metadata, result-context resets
  and retention of search/page on return without provider payloads in socket assigns.
  Credential-check tests cover local-only safe results, account/generation fences,
  denied actors, native error sanitization and unchanged persisted sync metadata.
- `test/monolith_web/controllers/owner_controller_test.exs`: static unlock/setup, session
  revocation and real CSRF enforcement on Lock (missing/invalid denial, valid token acceptance).
  Asset tests pin local vendor/font files and retained licenses.
- `test/browser/ui_contract.mjs`, launched by `test/support/ui_browser.exs`, is the
  synthetic real-browser gate for compiled assets and LiveView behavior. Required
  acceptance includes entrance/gating and return handoffs; sidebar collapse/expansion,
  keyboard focus and real Lock structure; native modals and draft restoration;
  first-input wake, idle and scroll preservation; deep links/reload/Back/Forward;
  account-separated Gmail/Calendar/GitHub routes and delayed identity races; provider
  setup and credential POST boundaries; safe local image loading; Scenes draft/save/
  confirmation/gallery lifecycle; idle/startup Settings behavior; canonical visible
  signals; narrow layouts, reduced motion, forced colors and print.
  Exercise long/bidi identities, 320px layout, real 200% text and 400% page zoom,
  keyboard traversal and scenery/glass contrast as required by M12; source assertions
  or viewport resizing do not substitute for those measurements. Capture actual
  exercised routes/states and off-origin/page-error/CSP results, not assumed coverage.

The browser gate is separate from `mix check`/hosted CI and requires an installed browser;
it fails rather than silently skipping when unavailable. See development guidance for its
isolation and deadlines. Native Node tests cover the actual three-minute timer, hidden/sleep
elapsed time, patches and animation interruption/replay deterministically. The browser suite
is not exhaustive: real tab suspension/sleep, Escape during every animation phase, full
keyboard tab-order traversal, contrast measurements and aesthetic evaluation of long-message
reading still merit manual review. Browser/aesthetic approval, assistive-technology testing, cross-browser checks
and hosted CI are distinct evidence, not claims inferred from these suites.
