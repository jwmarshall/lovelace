# Working on LOVELACE

The project name is **LOVELACE**, always uppercase in prose and UI. Use `:lovelace`
for the OTP application, `Lovelace`/`LovelaceWeb` for modules, and `lovelace` in paths,
configuration keys, and database filenames.

Stack: Phoenix LiveView, Ash/AshSqlite over Ecto/SQLite, and Tailwind.

## Product direction

- A personal homepage for orienting the day and focused work, not a widget dashboard
  or full project-management suite. Deliver a Gmail-first workspace before expanding integrations.
- Home (`/`) is the daily landing after ordinary unlock: quiet per-account Gmail readouts,
  not a unified inbox. Meaningful views have URLs; reload/deep links and browser history
  preserve destination/context, including a safe requested destination through unlock.
  Workspaces lives behind navigation; Escape/idle wake preserves current work.
- Workspaces represent areas of life; onboarding asks the owner to name their first workspace,
  rather than creating a predetermined starter. One reusable Google connection can appear in
  several workspaces, and a workspace can contain several accounts. Keep account/integration
  tiles separate; workspace removal is not global disconnect.
- The current slice is read-only Gmail and opt-in Google Calendar: per-account browser-local
  today's agendas on Home and workspaces, selected/shared calendars, no calendar writes.
  Reuse Google connections with explicit Calendar consent; Calendar health is independent of Gmail.
  Organizing mail, drafting, sending and projects
  are outside current scope, not an implicit roadmap. Revisit only on a fresh user request;
  any future project must belong to one account with explicit/manual thread membership.
- Optional read-only YouTube reuses Google connections with explicit additional consent.
  Select subscriptions for a bounded chronological, per-account uploads feed, not a
  recommendation feed. No writes, comments, downloads or auto-next. Playback uses an
  explicitly click-loaded official player; YouTube controls ads and related content.
  See the YouTube section in docs/DEVELOPMENT.md.
- Read-only GitHub.com personal/organization installations and repository selections can
  belong to several workspaces. Home keeps bounded PR, issue and recent Actions readouts
  separate by installation owner; workspace selections filter those snapshots, never a
  cross-owner inbox. GitHub App OAuth client settings entered through Connections and
  connection-UUID access/refresh bundles live in the dedicated keychain. Immutable identities
  and client/connection generations fence caches/jobs. Refresh is one-shot after a durable
  reservation; unknown outcomes require sign-in again. No repository writes, contents,
  workflow logs or artifacts. See the GitHub section in docs/DEVELOPMENT.md before changing
  credentials or polling.
- Gmail owns mail state; LOVELACE owns workspace/project data. Use bounded on-demand caching
  and Gmail search, not a full offline mirror or local mail index. Poll while the app runs;
  do not promise instant updates or execution while the computer is asleep/off.
- Show honest health, freshness and failure states. Unread signals must be per-account inbox
  conversation totals; defer numbers rather than infer totals from a partial page or fake zeroes.
- Discuss scope expansion first: no unified inbox, native/mobile client, general tasks/notes,
  AI agents or automation platform.

## Boundaries

- Personal, local-only desktop web app. Keep listeners on loopback. Network exposure
  or multi-user access needs an explicit security design, not just a bind change.
- Scope queries, writes, provider IDs, caches, jobs, and PubSub events by account;
  fence delayed results across account switches.
- Email and integration responses are untrusted content. Never render raw email HTML
  or fetch remote message content without a deliberate safety policy.
- Never commit/log tokens, credentials, real email, or private database files. Do not
  send real messages or modify a mailbox during automated tests.
- Sending is an explicit user action. Unknown send outcomes must not be blindly retried.
- Require explicit authorization before destructive database operations, file deletions
  or potentially billable provider calls.
- Preserve the user's `.tool-versions`; ask before changing runtime targets.
- Self-host UI assets. Vendor/pin third-party scripts and fonts locally with licenses,
  provenance, and checksums; no runtime CDN, font-service, or remote-image dependencies.
  The sole browser-content exception is the fresh-click official YouTube nocookie iframe;
  no remote parent assets or thumbnails. See docs/UI_CONTRACT.md for its input/idle boundary.

## Implementation

- Model business behavior with Ash resources, domains, actions, and policies, not parallel
  hand-written Ecto contexts. Register domains and commit migrations plus snapshots.
- AshAuthentication protects a single local owner; connected Gmail identities are separate.
  Initial browser owner setup requires single-use terminal pairing; it is not public signup.
  Keep early credential POST boundaries, HTTP/LiveView session guards and revocation intact.
- Production/dev storage uses SQLCipher 4.20.0 and a dedicated password-unlocked macOS
  file keychain, not the login keychain. Use `bin/lovelace setup` / `server` for development
  and `bin/lovelace mix TASK` for other Mix tasks.
  Startup is locked; explicit global Lock stops protected Repo/queues/provider work.
  Detected native keychain authorization/access failures also trigger global Lock;
  a missing individual credential is not a keychain-access failure.
  Escape/visual idle keeps work running. No password recovery or production plaintext
  fallback. Setup/migration may require attended OS authorization; runtime access is
  noninteractive. Interrupted setup/migration resumes only with the original password;
  never delete its markers or replace initialized keys. Preserve originals until
  separate explicit deletion approval. See docs/DEVELOPMENT.md and docs/GMAIL.md.
- Tidewave is dev-only code/SQL execution. Never enable remote access or expose it via tunnels.
  No separate SPA, PostgreSQL, Redis, or unnecessary infrastructure.
- Ash domain actions are inbound use-case APIs; provider contracts belong to the application,
  adapters implement them, and web code consumes public capabilities/read models. Core use
  cases must not discover Endpoint/signing configuration or borrow another domain's private
  persistence/lock identity. See docs/DEVELOPMENT.md for exact composition exceptions.
- Oban owns application background/async work: authorized atomic admission, ID-only jobs,
  generation/request fences, bounded retention and honest observed outcomes. UI lifetime
  must not own accepted cleanup. Keep only named OTP/security/timeout/observation exceptions
  documented in docs/DEVELOPMENT.md. Credentials remain in the dedicated keychain.
  See docs/GMAIL.md and docs/CALENDAR.md before changing grants/cache/jobs.
- No external telemetry exporter. Stock Bandit's in-process conn metadata is an explicit
  user-accepted local exception; never add payload logging/export without privacy review.
- Scenery is app-wide, not account-owned. Gemini generation is opt-in and potentially billable;
  allow opted-in startup or explicitly confirmed Scenes requests. The persisted 24-hour
  cooldown applies to automatic startup only; manual requests need fresh cost confirmation
  and refuse overlapping/unconfirmed attempts. Paid submissions are one-shot, fenced by durable
  claims even under Oban rescue. Google background interactions explicitly allow provider storage;
  resume only retrieval of known IDs, and delete remote results after committed local publication.
  Unknown submissions require explicit charge/overlap acknowledgement before fresh confirmation;
  safe polling/cleanup retries never authorize another generation. Keep permanent attempt history.
  Gemini keys are managed in Connections and stored separately in the dedicated LOVELACE keychain;
  no environment-key fallback or provider probe/generation on credential saves.
  Force `LOVELACE_STAGE_ENABLED=false` for maintenance; it blocks new startup generations,
  not already authorized jobs. No-provider maintenance must also avoid starting Oban queues;
  see docs/STAGE_DESIGNER.md.
- Clearly label placeholders; do not imply disconnected integrations are operational.
- SQLite sandbox/database tests must be synchronous. Use fake provider responses,
  not live Google calls. Keep `mix.lock` with dependency changes.

## Experience

- Warm cinematic minimalism: quiet brutalist geometry, charcoal/sea-glass, Space Grotesk,
  restrained motion and an edge-to-edge transparent glass stage shared by owner/workspace/mail views.
  Use quiet workspace cards; preserve the scenery/working-content focal-plane model.
  Escape/idle is visual, **not Lock**.
- Keyboard access, readable mail, contrast, reduced motion and forced colors outrank atmosphere.
  See docs/UI_CONTRACT.md for visual/interaction requirements and their verification map.

## Verification

Load `lovelace-architecture-development` for boundary changes and `lovelace-oban-workflows`
for async/background changes; invoke the corresponding hexagonal-boundary/background-work
reviewer before completion. See docs/REVIEWERS.md for discovery, fallback and specialist routing.

Run `bin/lovelace check` (format/compile/Credo/AshCredo/architecture/Sobelow/tests/assets)
and `bin/lovelace audit` (online advisories/retired packages). For UI
changes also run `bin/lovelace mix test.ui` (installed Chrome/Chromium; see docs/DEVELOPMENT.md). `mix lint` compiles in test for AshCredo introspection.
Keep durable decisions here and operational contracts in the relevant docs. Do not maintain
handoff documents, completion histories or speculative backlogs. Choose future work from the
current user request; retired plans are not obligations. Verify implementation in code and
report check results in the task response, not a rolling status document. Refresh linked
dependency guidance with `mix usage_rules.sync` when dependencies change. Report unrun checks;
never claim planned work exists.
