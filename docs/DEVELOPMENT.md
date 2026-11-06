# LOVELACE development and testing

LOVELACE is the project name, always uppercase in prose and UI. The OTP app is
`:lovelace`, modules use `Lovelace`/`LovelaceWeb`, and the Tailwind/esbuild profile is `lovelace`.
Sources live in `lib/lovelace/` and `lib/lovelace_web/`; local databases use `lovelace_*.db`.
The default UI theme is `sea-glass`. See the [visual and interaction contract](UI_CONTRACT.md).

## Local setup

Use the runtime versions in `.tool-versions`. Managed local storage requires macOS,
Apple's Command Line Tools, `pkg-config`, and SQLCipher **4.20.0** (not ordinary SQLite).
The native helper is `priv/native/lovelace-vault`; rebuild it after native-helper changes.

For a **new installation with no existing local data**, run:

```sh
asdf install                 # if these runtimes are not already installed
brew install sqlcipher pkg-config
bin/lovelace setup
bin/lovelace server
```

`bin/lovelace setup` fetches dependencies, rebuilds Exqlite against SQLCipher, verifies the
actual in-memory SQLCipher version, builds a missing native helper, and installs/builds
the Mix-managed Tailwind and esbuild binaries. It does **not** initialize application
storage, an owner, a keychain, or provider credentials. An existing current helper is
preserved; a stale/non-executable helper requires an explicit rebuild because replacing
it can change its Keychain ACL identity. `bin/lovelace` handles the SQLCipher environment
internally. Use `bin/lovelace help` for actions, or `bin/lovelace mix TASK` for other Mix tasks.
Initial setup needs network access and native build tools. No npm install, Docker,
separate database service, or Google credentials are required. Node is needed for
the JavaScript hook tests in `mix check`, not asset building.

Open <http://localhost:4321>. New storage redirects to **first-run setup**:

1. Copy the one-time pairing code printed in the server terminal into the browser.
   The code is private, expires after 15 minutes, and can pair only one browser.
   Restart the server to issue another code if it expires or you lose the paired session.
   This is not public signup; the listener must remain on loopback.
2. Choose and confirm your owner password (12–1024 characters, at most 1024 UTF-8 bytes)
   and acknowledge that there is **no password reset or recovery**. Forgetting it
   permanently loses access to the encrypted data. Never put passwords in shell arguments.
3. LOVELACE creates the dedicated password-unlocked macOS file keychain, independently
   generated database key, SQLCipher schema, and owner.
   Native creation may request macOS authorization for that dedicated keychain; use
   the same owner password. Explicit setup/migration alone can enable attended UI;
   ordinary unlock and background access remain noninteractive.
4. Name your first workspace. Google setup, Gmail and Calendar are optional: **Skip Google**
   goes straight to final review, bypassing Gmail and Calendar without saving credentials or authorizing anything.
   You can also follow the project, authentication/scopes, audience and Desktop OAuth client
   guide, then skip Gmail or Calendar individually. Returning to the workspace step edits
   the same workspace; setup and Home never create a predetermined Personal workspace.
   Client credentials go directly into the dedicated keychain without a Google request or
   restart. Google changes and consent remain explicit actions. Calendar consent returns
   to the same setup step to choose calendars, including shared calendars or none.
   Only **Finish setup** ends the guide and opens Home.

Later, **Connections → Google** manages the shared Desktop OAuth client independently of
onboarding progress. It reports local settings availability, never verified provider health.
Save there, then connect accounts in **Connections → Gmail** and explicitly authorize Calendar
in **Connections → Calendar**. Gemini remains a separate API-key integration.

Connections keychain checks for Google, Gemini and GitHub are admitted by the
`Lovelace.ConnectionDiagnostics` Ash domain and executed on the protected
single-concurrency `:diagnostics` Oban queue. They inspect local credential storage,
never provider health. Three fixed SQL slots retain only an opaque request/job
reference, finite status, timestamps and GitHub's public app slug; credentials and
native errors never enter SQL or jobs. Requests coalesce while pending, expire
after two minutes and are spaced at least five seconds apart. Credential mutations
invalidate the slot under the same provider exclusion used by diagnostics; stale
jobs cannot publish over a newer request. Browser timers only observe local Ash
status, including after missed updates; closing a browser does not cancel work.
Scene direction/gallery reads and confirmation/request admission are synchronous
bounded Ash calls; paid generation remains on its existing `:gemini` jobs.

Interrupted setup retains private markers and resumes at `/setup` with a new terminal
pairing code and the **original password**, without replacing an owner or initialized
database key. Never delete markers to force a reset. Creation publishes the final keychain
only after verifying its random database key. Unused encrypted `.keychain-creating-*`
staging files may remain after interruption; they are not recovery keys.
The Google guide saves progress in encrypted storage when you continue. After restart,
ordinary unlock resumes unfinished onboarding unless a safe requested destination takes
precedence. Existing installations without guide state still land on Home. `/onboarding`
reopens the saved step; **Continue setup** remains available while it is unfinished.

The attended terminal tasks `lovelace.owner.setup` and `lovelace.google.configure` remain
available for explicit maintenance, not required developer setup. They and vault migration
load `config/runtime.exs` without starting LOVELACE or queues. Production maintenance must
use the same `MIX_ENV=prod`, `DATABASE_PATH`, and `SECRET_KEY_BASE` as ordinary startup.

Every server startup is locked. Open <http://localhost:4321> and unlock with the owner
password to start the protected Repo, Oban queues and provider work. Explicit **Lock**
globally stops that work, closes the Repo and locks the keychain; Escape/visual idle
only changes scenery and continues work. Normal shutdown locks the keychain. After
an abrupt crash the macOS daemon may retain an unlocked keychain until startup relocks
it; do not assume an instantaneous crash lock.
Detected native keychain authorization/access failures automatically trigger the same
global Lock: admission closes, active protected work is drained, owner sessions are
revoked, and Repo/queues stop before the dedicated keychain is locked. This includes
denied/locked access, missing storage, helper unavailability, timeouts and malformed
helper responses during credential reads/writes or status checks. A missing individual
credential (`not_found`) or rejected local input does not trigger Lock. Detection occurs
on access, not through a continuous OS authorization monitor. Resolve native access
problems and unlock with the owner password; do not reset keys or reconnect accounts
merely because storage was temporarily unreadable.
Stop the server with Ctrl-C (twice if prompted), or use
`bin/lovelace console` for an interactive Elixir shell running the server.

To connect an account, follow the [Gmail setup guide](GMAIL.md); optionally add
[Google Calendar](CALENDAR.md). Neither is connected by local setup alone.
Scenery generation is optional; see [stage-designer setup](STAGE_DESIGNER.md)
before enabling potentially billable requests.

The server binds to `127.0.0.1:4321`; `PORT=4322 bin/lovelace server` changes the port.
Keep it local: owner unlock does not make network exposure safe. Development-only
[Tidewave](#tidewave-safety) can execute code and SQL; never expose it through a tunnel.

### Fresh onboarding without resetting existing data

Use a new private directory under your home directory, not a copied database or `.vault`.
Keep this path to resume the same installation; a new path means a separate installation.
The database parent must not contain symlinks (on macOS, `/tmp` and `/var` are aliases).

```sh
fresh=$(mktemp -d "$HOME/lovelace-onboarding.XXXXXX")
DATABASE_PATH="$fresh/lovelace.db" \
LOVELACE_STAGE_STORAGE_DIR="$fresh/scenery" \
LOVELACE_STAGE_ENABLED=false PORT=4322 \
bin/lovelace server
```

Open <http://localhost:4322> and use the pairing code from this server's terminal.
This isolates the database, dedicated keychain, and scenery from your existing installation.
Do not load a copied `.env` or delete existing files/markers. Keep scenery generation off
for onboarding review; Google credentials and consent are entered in the browser.


### Existing plaintext data: stopped terminal migration

Stop **every** LOVELACE instance before upgrading/cutover; this procedure cannot
secure an already-running old instance. Install prerequisites, run `mix setup` through
the SQLCipher wrapper, and explicitly rebuild a stale helper if requested. Do **not**
start browser owner creation against existing plaintext data.
With all servers stopped, run in a separate local terminal:

```sh
bin/lovelace mix lovelace.vault.migrate
```

The task requires `STOPPED`, verifies the existing owner password through hidden input,
exports to a separate encrypted database, verifies schema/data and correct/no/wrong-key
behavior, and copies known legacy credentials into the dedicated keychain. It requires
the exact `CUT OVER` confirmation before replacing the active database. Plaintext
originals, including SQLite sidecars/WAL, and legacy credentials are retained by default;
`DELETE PLAINTEXT` and `DELETE LEGACY SECRETS` are separate optional confirmations.
Retained plaintext backups are still exposed and need private handling.

An interrupted migration keeps a private journal and fail-closed startup marker:
rerun the same task to resume; never remove the marker or rename sidecars manually.
Only start the updated server after successful completion; startup still requires
owner unlock. File deletion is not secure erasure on APFS/SSDs and does not remove
snapshots, Time Machine copies, old backups or exported environment files. There is no
recovery path for a forgotten vault password. Never use `ecto.setup`, `ecto.reset`,
unkeyed Repo startup or manual file replacement to initialize or recover managed data.

If credential copying stops, keep every server stopped and preserve the migration
marker, journal, keychain and originals. The older `Credential copy conflict/unavailable`
message does not distinguish access denial from an actual differing value. The current
helper reports locked login storage, required/denied authorization, unavailable legacy
storage, timeout and genuine value conflicts separately. A conflict never authorizes
overwriting or deleting either credential.

After explicitly rebuilding the helper with `bin/lovelace mix lovelace.keychain.build`,
rerun migration with the same configuration and owner password to resume. Rebuilding
can change the helper's Keychain identity. Only explicit migration may request
macOS approval for legacy reads and the **existing** Database-key item; it never
replaces that key. Verify the helper path before approving it. Choose **Always Allow**
only for the verified helper when persistent item access is required: migration checks
ordinary UI-disabled access before proceeding. A `login` keychain dialog uses that
keychain's password (normally the macOS account password), not the LOVELACE owner
password. A dedicated LOVELACE keychain dialog uses the owner password.

The database's `.vault` directory contains the dedicated keychain and an empty
plaintext infrastructure-lock SQLite file, not plaintext business tables. Keep the
database, keychain and any retained migration originals private.
Native keychain lifecycle verification is attended and separately opt-in; default checks
never post an authorization dialog. On macOS, run:

```sh
bin/lovelace test test/lovelace/integrations/keychain_helper_io_test.exs --include attended_keychain
```

This builds a disposable helper with login-keychain migration code compiled out and
uses only disposable keychains. The test password is `synthetic diagnostic password`;
use it only for the named disposable keychain. The check exercises interrupted creation,
resumption, independent database-key persistence, and ten lock/unlock cycles.

Actual item-authorization recovery is a separate attended opt-in:

```sh
LOVELACE_KEYCHAIN_AUTHORIZATION_SMOKE=1 bin/lovelace test test/lovelace/integrations/keychain_helper_io_test.exs --only authorization_smoke
```

It uses only disposable keychains and the same `synthetic diagnostic password`.
Approve only the named disposable helper; Database-item recovery requires persistent
**Always Allow** approval and then verifies the unchanged key through an ordinary
noninteractive read. Default checks never run these dialogs or access login credentials.

## Namespace and local data

Use `:lovelace` for configuration/environment lookups and `Lovelace`/`LovelaceWeb`
for application/web modules. The session cookie is `_lovelace_key`; existing browser
sessions start fresh after the rename. No signing secrets were rotated for the rename.

The local development and test databases were carried forward using SQLite's backup
API, including any WAL state, and verified with `PRAGMA quick_check`. Private rollback
copies of the original files are under the ignored `tmp/name-change-backups.DTpCBR/`
directory (`dev.db` and `test.db`, with sidecars if present). Keep them private; do not
use `mix ecto.reset` as a rename or recovery procedure. Production still uses the
explicit `DATABASE_PATH`; no production data was migrated.

Obsolete application/colocated build output was removed and assets rebuilt, rather
than renaming compiled BEAM files. Stop the server and restart after namespace changes;
hot reload is not an application-identity migration. Git hosting metadata and the
checkout folder name are separate from application identifiers and were not changed.

## Application boundaries and background ownership

Ash domains/actions are inbound application APIs. Domain-owned provider contracts describe
mail reads, Calendar pages, YouTube subscription/uploads pages, GitHub `installation_snapshot/2`,
Google authorization and paid render submit/track/delete; concrete HTTP/native adapters implement those contracts. Keep
authorization, safe outcomes and workflow decisions in the application, not in adapters or
LiveView callbacks. Do not add parallel Ecto contexts or generic workflow/task platforms.
`Google.Access` owns shared Google credentials, serialization and grant/reset coordination;
Calendar owns its catalog/day/selection health; YouTube owns its channel selection and feed.
GitHub `Coordination` owns exclusion across
`Credentials`, discovery/membership `Operations` and snapshot `Polling`; callers must not
borrow private lock identities or persistence.

`Home.summary` and owning-domain metadata projections compose bounded workspace health and
membership without provider calls or private payloads. The parsed destination is authoritative;
page flags are derived render projections, not independently mutable navigation state.
Meaningful URLs, reload/history/unlock returns and request-token fencing remain required.

Application background work executes in protected Oban queues, each with concurrency one:
`:gmail` reads/polls/disconnection, independent `:calendar` and `:youtube` poll/sweep,
`:github` snapshots, `:gemini` authorized generation/recovery, `:oauth` one-use exchanges and `:diagnostics` local
keychain checks. Authorized Ash admission atomically commits intent/job where durable.
Arguments carry only opaque IDs and safe generations/revisions. Observe safe application
outcomes correlated to job IDs; Oban completion alone is not provider success. Retain bounded
sensitive inputs only in protected scoped resources, secrets only in the dedicated keychain
or approved expiring memory, and bodies only behind view-owned opaque render references.
Paid/code/rotating-token submissions require durable claims; unknown outcomes never authorize
replay. See GMAIL, CALENDAR and STAGE_DESIGNER for operation-specific retention/recovery.

Narrow runtime exceptions (not namespace-wide exemptions):

- Bounded synchronous local Ash reads/calculations/admission, including Scenes gallery,
  confirmation preparation and startup reservation; no provider calls in those paths.
- Vault/lease guard, owner pairing/throttle and bounded ephemeral OAuth/result/ownership
  holders are OTP lifetime/security coordination, not business schedulers.
- `Integrations.Google.run_bounded/2`, `Integrations.Gemini.Interactions.execute_leased/4`
  and `Security.Keychain.run/4` use linked bounded timeout/isolation helpers within their
  operation/lease, sanitize failures and cancel before returning. Native setup/unlock/migration
  must work before the protected Repo/Oban exists; that does not exempt background diagnostics.
- Vault/session expiry timers enforce security. HomeGitHub local-age/auth status,
  HomeConnectionDiagnostic, HomeMail and HomeYouTube operation timers only observe local
  state; they never initiate provider polling. HomeYouTube observes at most twenty
  three-second intervals. Expired observation is not cancelled durable cleanup.
- `Mail.ViewData` expiry timers carry opaque references only and erase idle private results
  after ten minutes. Eviction/view death cancels their timers; protected teardown clears the
  store on Lock. This bounded privacy lifetime is not a provider scheduler.
- Composition permits exactly Application→Endpoint/Web.Telemetry and Bootstrap→Endpoint
  configuration. GitHub callback URLs are supplied in runtime configuration; adapters
  validate supplied loopback paths without calling Auth. `StageDesigner.Confirmation`
  is implemented by composed `LovelaceWeb.SceneConfirmation`; core never discovers signing.

`bin/lovelace check` runs `lovelace.architecture.check`: parsed Elixir syntax resolves
aliases/imports, local/transitive static calls, captures, delegates and static MFA/apply.
It rejects core→web, adapter→orchestration, static UI→provider, unsupported cross-domain
persistence/capabilities and borrowed lock ownership. Exact composition exceptions have
fixtures. Runtime-selected providers, generated Ash/macro dispatch, message callbacks and
variable-carried resource/lock identities still require scoped source/runtime review;
passing the checker is not complete architectural proof. Load the development skills and
invoke reviewers as routed in [REVIEWERS.md](REVIEWERS.md), including its native activation
and read-only portable fallback limits.

## Installed baseline

| Dependency | Role | Scope |
| --- | --- | --- |
| `ash`, `ash_sqlite`, `ash_phoenix` | Resources/domains/actions/policies, SQLite persistence, Phoenix forms | Runtime |
| `ash_sql` | Shared Ash SQL query planning | Runtime; locked to 0.8.7; releases before 0.8.6 are retired for an Ecto query-cache defect |
| `simple_sat` | Pure-Elixir SAT solver required by the first production Ash policies | Runtime |
| `ash_authentication`, `ash_authentication_phoenix` | Single local owner unlock | AshAuthentication password strategy; terminal-paired initial browser setup |
| `req` | HTTP request/response contracts; built-in `Req.Test` stubs/expectations | Runtime; test utilities used in tests |
| `mint` | Private unpooled Gemini and Google transport, avoiding credential-bearing Finch telemetry | Runtime; pinned direct dependency |
| `oban` | Application background admission/execution and recovery with bundled SQLite Lite engine | Runtime; 2.24.2, per-queue concurrency 1, cron/Lifeline/pruning |
| `exqlite` | SQLCipher binding for encrypted storage and private cross-BEAM filesystem exclusion handles | Runtime; explicit direct dependency linked to SQLCipher 4.20.0 |
| `vix` | Strict JPEG pixel decoding through libvips; original provider bytes retained | Runtime; native dependency |
| `credo`, `ash_credo` | General and Ash-aware static analysis | Dev/test, not started at runtime |
| `sobelow` | Phoenix security scanning | Dev/test, not started at runtime |
| `mix_audit` | Advisory database checks via `mix deps.audit` | Dev/test, not started at runtime |
| `igniter` | Reviewable code generation and project patching | Dev/test, not started at runtime |
| `usage_rules` | Dependency documentation/agent guidance | Dev, not started at runtime |
| `tidewave` | Agent runtime inspection/MCP; code and SQL execution | Dev only |

ExUnit, ConnTest, LiveViewTest, SQL Sandbox, `Ash.Test`, and `Ash.Generator` provide
the initial test toolkit. StreamData is already transitive through Ash; no additional
factory library is installed. See `mix.lock` for exact versions.

## Vendored animation assets

Topbar **3.0.0** supplies the existing LiveView navigation/form progress indicator
through `assets/js/app.js`'s local `assets/vendor/topbar.js` import. The source was
verified byte-for-byte against the SHA-512-verified npm archive and its immutable
upstream Git commit before pinning. Topbar is **MIT**; its complete permission,
copyright and warranty/liability notice is retained in `topbar.LICENSE.txt` and
an appended esbuild-preserved legal comment. That comment is the only local source
change. Keep the full notice in distributed bundles (and ship any legal sidecars
if the build policy changes), not merely the short upstream `@license MIT` header.
See [Topbar provenance and updates](../assets/vendor/topbar.README.md) for exact
artifact/commit URLs, upstream/local checksums, license-text provenance and the
intentional verification/update procedure. ExUnit pins source, license and package
metadata, and verifies the upstream bytes and complete embedded notice. No runtime
retrieval or npm installation is introduced. Review Topbar advisories separately;
`mix audit` is Hex-scoped. Existing GSAP and font checks must remain intact.

Self-hosting and vendoring UI assets are project requirements. GSAP **3.15.0** core
(including CSSPlugin) is bundled from `assets/vendor/gsap/gsap.js` through the existing
esbuild pipeline. No npm installation, JavaScript package manager, CDN import, or
runtime download is needed. Its custom Standard "No Charge" License is **not MIT**;
preserve the upstream notices and review licensing before changing product scope.
See the [vendor README](../assets/vendor/gsap/README.md) for provenance, registry
SHA-512 verification, local SHA-256 pins, license snapshot, and update procedure.
`mix audit` covers Hex packages, not vendored JavaScript; review GSAP advisories
separately when updating. ExUnit checks the pinned files and retained license notices.

Visual/interaction requirements, decorative DOM ownership, entrance lifecycle and the
browser verification checklist live in [UI_CONTRACT.md](UI_CONTRACT.md). Implementation
entry points are `assets/js/hooks/brand_reveal.js`, `workspace_entrance.js`,
`workspace_idle.js` and `stage_background.js`; registration is in `assets/js/app.js`.
No DrawSVG/SplitText plugin, `unsafe-eval` or remote script allowance is needed.

## Local settings and credentials

See [stage-designer setup](STAGE_DESIGNER.md) for optional non-secret settings.
`.env.example` is a readable, secret-free template; plain Mix does not load it.
Do not use plaintext environment variables or dotenv files to supply provider secrets.
Google OAuth client configuration is entered through the protected `/onboarding/client`
form and stored in the dedicated keychain, without a provider probe or environment fallback.
The stopped-terminal `lovelace.google.configure` task remains an explicit maintenance option.
Gemini keys use Connections and the same
dedicated vault; `GEMINI_API_KEY` is ignored. Saving/removing a key never generates,
verifies provider access or changes startup opt-in. Tests/CI must use fake credentials.

Stage settings control an opt-in asynchronous startup generator after the first successful
ordinary unlock once per application startup (not page loads or subsequent relock/unlock),
a persisted 24-hour attempt cooldown, and an uncapped published-scene catalog. `Lovelace.StageDesigner` is the first production
Ash domain; provider work never runs in LiveView callbacks. `LOVELACE_WORKSPACE_IDLE_MINUTES`
controls the client-only screensaver (default three minutes). Scenes exposes the saved
catalog through bounded 20-image pages, persistent background selection, and confirmed potentially billable manual
requests without a manual daily cooldown. Automatic startup alone uses the persisted
24-hour cooldown; manual work refuses another unresolved reservation. A dedicated Gemini Oban queue handles one-shot
paid submissions, resumable retrieval by provider ID and deletion after successful local publication.
Ash retains all attempt metadata independently of job pruning, with bounded history pages. Scenes
has per-manual-request model/aspect/size controls (startup defaults are unchanged), explicit unknown
outcome acknowledgement and safe failure/cleanup details. See STAGE_DESIGNER.md for recovery and
Google storage policy. Scenes also saves
app-wide guided scene direction (subject, setting, light, palette), with an exact prompt
preview. Saving is local-only and never generates or changes startup opt-in. The saved
direction overrides the configured prompt for future manual/startup attempts; apply the
additive scene-direction migration first. Unsaved edits block manual generation until
saved/discarded, and confirmation refuses a concurrently changed saved prompt.
Do not inject real Google credentials into tests or CI. Test runtime forces real startup
generation off; focused provider tests inject fake keys/`Req.Test`. For maintenance,
set `LOVELACE_STAGE_ENABLED=false` to block new automatic generations; it does not cancel
already-authorized jobs while unlocked. Full vault Lock stops queues and provider work.
The workspace UI still runs without provider credentials when generation is disabled.
Three owner-approved bundled JPEGs replace the default SVG; an independent Ash singleton
chooses one once at application startup and preserves it across restarts. Apply the
additive `add_bundled_scene_default` migration before restarting an existing installation.
Static/live rendering only reads that preference; it does not reserve or generate scenes.
See `priv/static/images/scenes/README.md` for artwork provenance and checksum pins.

## Calendar

Optional read-only Google Calendar shares existing Google identities and Keychain credentials,
with explicit additional consent and independent account-scoped day/selection/cache state.
See [CALENDAR.md](CALENDAR.md) before changing its scopes, polling or retention. It adds no
runtime dependency or external service infrastructure. Calendar's Ash domain owns day
preparation, selection, reads and jobs; the browser supplies local midnight boundaries and
renders minimal cached event text without retaining events in socket assigns. Its independent
`:calendar` minute sweep discovers due Calendar work without waiting for Gmail.
Tests must inject fake Calendar providers, never real Google responses or private calendar data.

## YouTube

Optional read-only YouTube uses the existing Google identity and dedicated keychain credential,
not another owner login. Enable **YouTube Data API v3** in the same Google Cloud project and
add `https://www.googleapis.com/auth/youtube.readonly` to its consent configuration.
In **Connections → YouTube**, choose the account and receiving workspace and explicitly
authorize YouTube. Gmail-only connection does not request this scope; onboarding is unchanged.
Previously enabled Calendar/YouTube capabilities require complete returned scope evidence
when enabling the other. Denial or partial optional grants leave the existing grant untouched.
A normal Gmail reconnect disables both optional capabilities; enable them explicitly again.
Replacing Google client settings fences active account generations and clears optional
state; unchanged settings preserve them. Global Google disconnect clears all three services.
Workspace removal remains association-only. Grant replacement resets dependent caches and
selections rather than carrying private state into a new generation.

Choose up to ten subscriptions from a bounded catalog of the first one hundred, with honest
truncation. Nothing is selected automatically. The account feed reads at most ten recent
uploads per selected channel, deduplicated and ordered newest first, with a one-hundred-video
aggregate cap. No recommendations, comments, search, writes, downloads or infinite scroll.
`/accounts/:account_id/youtube` and `/accounts/:account_id/youtube/videos/:video_id`
preserve destination through reload/unlock/history. Playback admission requires a video in
the current selected, unexpired cached feed; account/generation/selection changes invalidate it.

SQLCipher stores bounded channel/feed metadata with independent 24-hour expiry. Unlocked
polling is every fifteen minutes; a five-minute provider rate-limit cooldown also applies
to manual Refresh. There is no asleep/off execution guarantee. Protected `:youtube` Oban
work uses ID-only account/generation/revision arguments and atomic intent/job admission.
Queue waiting does not consume the execution lease. An atomic claim starts a 120-second
lease, backed by a 120-second whole-worker timeout, including serializer waits. Publication
rechecks the claim and identity. The minute sweep has its own 30-second whole-worker bound
and recovers interrupted/expired claims. Ready/enabled/current-generation eligibility is
filtered before its 100-row admission cap; ineligible rows cannot monopolize that page.
Failures stay visible rather than reporting successful freshness. Shared account health
publishes an independent `google:ACCOUNT_ID` invalidation. Polling and grant changes retain
the existing Mail event; committed interactive-read failures notify dependent health only,
without recursively refreshing Gmail. YouTube owns its independent subscription lifetime,
so credential failure in either Gmail path removes an open player's admission.

No remote thumbnails, scripts or imagery load in the parent page. A fresh **Load YouTube
player** click creates only `https://www.youtube-nocookie.com/embed/VIDEO_ID`, with autoplay
off. Navigation, reload, reconnect and unload never silently recreate it. This is an explicit
exception to self-hosted browser content, not a tracking-free or ad-free promise. YouTube
controls ads and related content; `rel=0` restricts related videos, not their existence.
See [YouTube's parameter contract](https://developers.google.com/youtube/player_parameters#rel).
Cross-origin player input cannot reach LOVELACE: Tab/Shift+Tab back to the adjacent Unload
control. Visible focused playback suspends scenery idle; hidden-tab elapsed time still
expires/unloads it. Escape controls LOVELACE scenery only outside the player.
See [UI_CONTRACT.md](UI_CONTRACT.md).

Tests and browser verification inject synthetic providers and intercept the embed locally.
They must not fetch real subscription data or perform live consent/playback. Native keychain,
Google consent and actual YouTube playback require attended verification with the owner's
configured client; fixture success does not certify those external services.

## GitHub

Read-only GitHub.com installations provide separate pull request, open issue and recent
Actions readouts per personal/organization owner on Home. Workspaces can reuse a whole
owner or select particular repositories independently. This uses a **GitHub App with
OAuth browser sign-in**, not a classic OAuth App: installation permissions stay
read-only without the broad private-repository `repo` scope.

Both the signed-in user and installed app must have access to each repository.
No GitHub Enterprise, webhooks, writes, checkout, contents, comments, diffs, workflow
logs/artifacts, avatars or remote images are fetched.

### Register and connect the GitHub App

The same guide is available directly in **Connections → GitHub**.

1. Open [Register a new GitHub App](https://github.com/settings/apps/new)
   ([GitHub registration reference](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app)).
   Choose a unique app name and use your local LOVELACE origin as Homepage URL.
   Register a **GitHub App**, not an OAuth App.
2. Copy the exact **Callback URL** shown in Connections. For the default server it is
   `http://localhost:4321/auth/github/callback`; a custom port must match the configured
   Endpoint origin and app registration. Use canonical `localhost`, not a different
   hostname or IP address. Leave **Expire user authorization tokens** enabled.
   Device flow is not used. Leave **Request user authorization (OAuth) during installation**
   disabled: LOVELACE starts its own state-bound authorization.
3. Disable **Webhook → Active**. Set repository permissions to **Pull requests: Read-only**,
   **Issues: Read-only**, **Actions: Read-only**, and **Checks: Read-only**.
   Metadata is automatic; leave other permissions at No access. No contents, write or
   account permissions are needed. Set **Any account** for installation if you want
   organizations or other personal accounts. Create the app.
4. Copy its **Client ID** (not App ID), generate a **client secret**, and copy the
   app URL (`https://github.com/apps/your-app-slug`) or just its lowercase slug.
   Enter all three in **Connections → GitHub → Add app client settings**.
   A full HTTPS GitHub App URL, with an optional trailing slash, is normalized to
   the slug before saving; unrelated hosts, paths, queries and fragments are rejected.
   Settings are saved directly into the dedicated LOVELACE keychain.
   Saving does not contact GitHub, verify permissions,
   grant account access or require a restart. Never put secrets in `.env`.
5. Choose **Choose repositories on GitHub**. Install on the desired personal accounts
   or organizations, selecting at most **100 repositories per installation**.
   Organization administrators may need to approve installation and later permission changes.
6. Choose **Connect GitHub account**, review authorization on GitHub and return to LOVELACE.
   Authorization uses [GitHub's web application flow](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app)
   with PKCE S256 and a session-bound, single-use state expiring after ten minutes.
   `offline_access` requests an expiring access/refresh pair; it is not a repository
   permission scope. Access/refresh tokens and the client secret never enter browser responses.
7. Add a **whole owner** to a workspace, or open **Choose repositories** and select at
   least one repository. Saving a selection replaces only that owner's membership in
   the chosen workspace. **Use whole owner instead** restores all accessible repositories.
   Other workspaces and GitHub permissions are unchanged. Refresh the owner first if
   repository choices are unavailable or expired.

After changing installation access, choose **Refresh account access**, then refresh
the owner to reload repositories/activity. Missing an organization? Check your user's
access, installation approval and selected repositories. For SAML SSO, start an active
organization SSO session before signing in again. After permission changes, approve them
on each installation. A callback mismatch requires the exact scheme, hostname, port and path.
To omit optional PR check queries, set `config :lovelace, :github, checks: false`.

Installing the app and authorizing an account are separate steps. GitHub's optional
installation-time OAuth return has no LOVELACE-issued state and cannot connect this
browser. Keep that registration option disabled and start **Connect GitHub account**
from LOVELACE. Rejected callbacks distinguish missing state, unmatched/expired requests,
explicit denial and other failures without displaying provider response details.
A safe failure category survives reload so a rejected return does not misleadingly
continue showing “waiting.” **Start connection again** starts a fresh, session-bound
request; it never retries the rejected authorization code. Older returns cannot consume
the newer pending request.

GitHub's OAuth callback may include the RFC 9207 `iss` parameter. When present,
LOVELACE requires exactly `https://github.com/login/oauth`, the
[documented GitHub.com issuer](https://docs.github.com/en/apps/github-authentication-discovery-endpoints).
Duplicate or mismatched issuers are rejected before consuming the authorization
request or exchanging its code. Responses without `iss` still require the same
session-bound, single-use state and PKCE; no runtime issuer discovery is needed.

Workspace integration setup offers saved repository owners once account authorization
has succeeded. With no authorized account, it explains why Connections is required;
with an account but no accessible owners, it directs the owner to repository access
and refresh instead. Saved app credentials alone are never attachable integrations.

### Credentials, disconnecting and migration

The dedicated **LOVELACE GitHub** keychain service stores the client ID/secret/slug
configuration at a reserved UUID and one expiring access/refresh bundle per connection
UUID. No private key, PAT or environment-credential fallback is used.
App settings and token bundles carry a credential generation. Replacing changed settings
fences pending authorization and old work, clears activity caches, and requires sign-in
again while preserving immutable owner identities and workspace memberships.
The application-owned `GitHub.Provider.installation_snapshot/2` contract names its complete
PR/issue/Actions/repository result. Client lifecycle, discovery/membership and polling share
one `GitHub.Coordination` exclusion owner rather than borrowing `Operations` lock internals.
The runtime-composed callback is validated as the canonical localhost callback by adapters;
it is not discovered by an adapter calling back into Auth.

**Refresh account access** admits durable discovery rather than doing GitHub work in the
browser POST. Admission atomically records one bounded discovery slot on the connection
and its `:github` Oban job; job arguments contain only the connection/request UUIDs.
Repeated requests share the active slot. The protected worker owns credential acquisition,
any durably reserved one-shot rotation, identity/installation reads and fenced publication.
Client, connection and installation-owner revisions are checked before work and again
before publication; only the worker's own successful token rotation may advance its fence.

Connections shows the persisted `pending`, `running`, `succeeded`, `failed` or `superseded`
discovery state with opaque operation/job correlation. Browser exit does not cancel accepted
work, and reload/local observation recovers outcomes after missed PubSub events. A failed
or interrupted job is not successful discovery and does not erase a good snapshot merely
because its observation failed. Duplicate delivery cannot repeat a claimed discovery or
credential rotation. After an interrupted claim, request another refresh explicitly;
uncertain token rotation still requires sign-in, never replay of the old refresh pair.
Executing discovery older than three minutes is observed as unavailable, not left running
forever or automatically replayed. Its owner fence hashes every retained local owner
UUID/generation in ordered pages of 128 rows, including disconnected history: the provider's
500-current-installation limit is not a lifetime identity cap, and historical removal still
supersedes obsolete discovery.
Apply the additive GitHub discovery-slot migration through the normal protected lifecycle.

[Refresh](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens)
includes the stored client secret and is one-shot after a durable reservation. Unknown
exchange/refresh outcomes, interrupted rotations and failed rotated-token saves require
fresh sign-in, never replay of a previous code or refresh token.
A keychain read failure before any refresh reservation preserves the connection,
workspace links and still-fresh snapshots, but native storage-access failures trigger
global Lock. After native access is restored and the owner unlocks, normal polling
can resume without another GitHub sign-in; a read failure alone is not revoked access.
Confirmed missing or malformed token bundles still require sign-in.
Global Lock stops ephemeral authorization, protected queues and provider work.

**Remove from workspace** detaches only that membership. **Remove owner everywhere**
fences its work and clears local memberships/cache, leaving the shared App sign-in.
**Disconnect account** fences all its owners, clears memberships/cache and deletes the
account token bundle, not the shared app settings. Failed deletion remains visible with
a retry action. Neither action revokes authorization or uninstalls the App in GitHub;
do that separately there.

Restart and unlock normally to apply the additive `add_github_repository_readouts`
migration through the managed vault lifecycle. It expires older PR snapshots without
immutable repository IDs and preserves owners, connections and workspace memberships.
Previous device-flow bundles require fresh sign-in to bind them to the saved app settings.
Old environment-only Client ID/slug configuration is no longer used.
**This change does not require rebuilding the native helper.** Older installations
without the existing GitHub keychain service must follow
[attended helper preparation](GMAIL.md#1-local-preparation); never reset keys or broaden access.

Old PATs are not used. Retained owner-UUID credentials remain explicitly removable using
**Remove owner everywhere** or **Remove retained credential**, including after adoption
by an App connection or account disconnect. Reauthorization never silently deletes originals.
Early credential POSTs and callbacks scrub secrets before Phoenix instrumentation.
Redirects contain only allowlisted result categories, never provider text, codes or tokens.
App-settings failures distinguish invalid Client ID, client secret and app URL or slug,
missing fields, a locked vault, and keychain failures without reflecting submitted values.
Copy the Client ID (not the numeric App ID), generated client secret (not a private key),
and full `https://github.com/apps/` URL or lowercase slug, without surrounding whitespace.
Saving checks local format and storage only; it does not validate credentials with GitHub.
Keychain failure does not mean GitHub rejected access; do not rebuild/reset storage indiscriminately.

### Read bounds and freshness

`Lovelace.GitHub` owns Ash connections, installation owners, workspace memberships and
owner-scoped jobs. Discovery is bounded to 500 accessible installations. Snapshots use
immutable repository IDs from the matching installation and recheck installation and
repository access before publication. More than 100 selected repositories fails honestly
rather than silently omitting repositories; select a smaller set in GitHub.

Fixed-host private Mint transport has no redirects, automatic retries or payload
instrumentation: 20-second individual requests, a 60-second snapshot deadline and
2 MiB response limits. GraphQL queries run in batches of 20 repositories, fetching up
to 50 open PRs and 50 open issues per repository, retaining the newest 50 of each per owner.
Actions reads at most ten recent runs from each of ten repositories, retaining at most
50 runs per owner. Larger repository sets, remaining runs, permissions, rate limits and
optional-read deadlines are labeled as partial, not an all-repository health verdict.

Counts describe accessible repositories, never an entire organization. Workspace selections
filter the bounded owner snapshot by immutable repository ID; shown rows are a subset,
not selected-repository totals. Unknown counts are not zero. Home and workspaces show
escaped text, explicit review/check/run states, UTC update times and constructed GitHub links.
Missing optional permissions cannot become a successful empty readout.

Polling runs approximately every five minutes while unlocked/running (minute sweep).
Core rate-limit failures persist a 15-minute cooldown that Refresh cannot bypass.
Failures retain the observation timestamp; cached activity/counts expire after 24 hours.
Sleep/offline cannot deliver live updates. Tests and browser smoke use synthetic
providers/keychains; the production connector is disabled in test builds.

## Saved workspaces

`Lovelace.Workspaces` owns a SQLite `Workspace` resource with explicit read/create/rename
actions. All require the server-supplied `%{role: :local_owner}` capability, checked strictly
(including missing IDs). This is **not authentication** and
must not be reused as a multi-user access design. The protected UI now mints it only after
owner-session verification. Workspace/account membership reuses Gmail connections without
mixing inboxes; credentials remain in Keychain and mail queries require account scoping.
See [GMAIL.md](GMAIL.md) for activation, native helper, retention and security decisions.

Managed schema migrations run through the password-unlocked vault lifecycle before
protected work starts; do not start an unkeyed Repo or run standalone `ecto.migrate`
against managed real data. Existing plaintext installations must first use the stopped
migration procedure above.

Onboarding creates the owner's named first workspace and persists its association with
the guide in one Ash transaction. Repeated submissions and returning to rename edit that
same workspace. Existing guides retain their legacy starter association when it exists;
new installations, Home mounts, reloads, and directory refreshes never manufacture one.
Later creation and rename use focused native-dialog modals with `AshPhoenix.Form`; names
are trimmed, nonblank, and bounded to 64 characters server-side. There are deliberately
no delete/archive actions or projects. Account connection and read-only mail are
implemented separately in `Lovelace.Mail`.

`StatusComponents.status_signal/1`, `assets/css/status.css` and the `StatusSignal` hook
share custom SVG activity/last-known-health states across Home, workspaces, mail, Calendar,
Gemini, Scenes and transport recovery. Routine labels use accessible focus/hover details;
attention/recovery copy stays visible. The hook only positions/dismisses details, including
hover-only Escape and embedded-link focus; CSS owns preference-aware motion. Provider work,
freshness hooks and action feedback remain separate.

`WorkspaceComponents.card/1` and `MailComponents` render directory and integration surfaces;
`HomeLive`/`HomeNavigation` own URL-driven patch navigation; `HomeMail` owns account-topic lifecycle. See
[UI_CONTRACT.md](UI_CONTRACT.md#home-workspace-and-integration-navigation) for control semantics,
management context and navigation behavior.

Workspace card health reads only Ash account/membership metadata, not message caches or
provider APIs. Known problems are grouped by workspace/account, and subscriptions follow
the current directory, workspace or global Connections context. A metadata update from
another account never requests the selected inbox. Home reads persisted per-account unread inbox conversation counts, independently timestamped
from cached pages. Polling obtains Gmail INBOX label `threadsUnread`; conversation flags on
a bounded page never establish an account-wide unread total. Apply the new additive count
migration before restarting the updated app; do not reset the database.

`MailComponents` renders balanced inbox rows and the dedicated plain-text reader. The
`MailReader` hook owns only ephemeral focus/scroll navigation memory, fenced by the opaque
result-list context and connection generation; it never persists bodies or queries. Native
message/metadata disclosures retain their `open` attributes across patches via LiveView JS.
`MailDate` and `MailFreshness` in `assets/js/hooks/mail_time.js` own small ignored text nodes,
format browser-local dates and age fetched-at observations without changing provider state.
Their timers/resume listeners are cleaned up on destruction. `test/js/mail_reader_test.mjs`
covers those lifecycle contracts; LiveView tests cover server search/page/context state.

`HomeComponents` supplies the local daily heading, account readout and freshness components.
`DailyOrientation` and `ObservationTime` hooks own only their ignored readout subtrees and
clean up timers/resume listeners. Default navigation is Home; the center navigation contains
Home, Workspaces, Connections, Scenes and Settings. The corner monogram is decorative only, and Escape/idle
preserve the current destination. Browser history/reload/deep links restore meaningful views,
including submitted mail searches/pages, Conversations and Connections providers. Only navigation
URLs, not drafts/dialogs/scenery focus, enter history. Direct
Home inbox reads use explicit owner-only account actions, not relaxed workspace membership
checks.

The live shell keeps `#workspace-content` as the working scroller (including navigation),
with a sibling `#workspace-controls` rail for stationary Lock and Escape guidance.
`WorkspaceEntrance` opens both inert gates through sticky LiveView JS; narrow/laptop
layouts reserve chrome bands so the rail cannot cover scrolling controls.

`Layouts.stage/1` is shared by `Layouts.app/1` and static owner unlock/setup screens.
Shared shell/focal-plane tokens live in `assets/css/app.css`; workspace card rules live
in `assets/css/workspaces.css`. The [UI contract](UI_CONTRACT.md) is authoritative for
visual behavior, gate/focus ownership and static/live differences. `mix test.js` discovers
all `test/js/*_test.mjs`; its fake-DOM coverage does not certify rendered browser behavior.

## Image validation dependency

`vix` 0.42.0 is pinned in `mix.lock` for JPEG validation, not image generation or UI code.
Its JPEG-specific loader uses `fail-on: :VIPS_FAIL_ON_WARNING`, sequential access, and
revalidation; extracting raw pixels forces lazy decoding. Before any native load, bounded
segment parsing limits the encoded file to 10 MiB and dimensions to 8192 per side / 16M
pixels. Decoded dimensions, band count, and pixel bytes are checked as well. The original
encoded bytes are stored without re-encoding, retaining metadata/provenance. Do not replace
this with header-only sniffing or a decoder that silently recovers damaged entropy data.

Vix's Elixir wrapper is MIT; libvips is LGPL-2.1-or-later and its bundled libraries have
additional upstream terms. Follow [Vix installation/provenance](https://github.com/akash-akya/vix/tree/v0.42.0)
and [libvips licensing](https://www.libvips.org/). Prebuilt macOS/Linux artifacts are provided
by Vix; building from source needs the upstream native toolchain/libvips. No GUI framework,
ImageMagick process, separate service, or runtime asset download was introduced. Native
compilation and packaged-release loading were verified with the existing local OTP29 /
Elixir1.20 runtime; hosted Linux CI remains unverified. Native decoding is not process
isolation; keep this dependency updated and retain the preflight limits.

See [STAGE_DESIGNER.md](STAGE_DESIGNER.md#documentation-review-output-formats-and-validation)
for Developer API MIME-schema findings and the PNG final-IDAT padding correction.

## Daily commands

```sh
bin/lovelace setup
bin/lovelace server
bin/lovelace console
bin/lovelace test test/lovelace/security/developer_setup_test.exs
bin/lovelace test test/lovelace/security/launcher_test.exs
bin/lovelace mix format
bin/lovelace check
bin/lovelace audit
bin/lovelace help
```

The launcher runs commands from the project root, preserves argument boundaries
(including spaces and shell metacharacters), and propagates their exit status.
Use `bin/lovelace mix TASK [arguments]` for the underlying Mix commands below.
`bin/lovelace check` selects `MIX_ENV=test` and executes:

1. `mix format --check-formatted`
2. `mix lint` (compile with warnings as errors, then `mix credo --strict`)
3. `mix security` (`mix sobelow --private --exit low`)
4. `mix ash.codegen --check` (migration/snapshot drift)
5. `mix test --cover` (90% minimum line coverage)
6. `mix test.js` (native Node test runner, no npm dependencies)
7. `mix assets.build`

`mix precommit` delegates to `mix check`. Neither fixes formatting nor updates the
lockfile. Run `mix format` explicitly before committing. Credo includes selected
AshCredo checks for authorization bypasses, missing policies/domain, raw repo calls,
sensitive attributes/accept lists, unknown actions, and wildcard mass assignment.
AshCredo is **unofficial and experimental**: examine findings, and don't weaken
policies or disable whole categories just to make a check green.

`mix lint` and direct `mix credo` select the test environment so compiled-introspection
checks can load `test/support` resources. If you override `MIX_ENV`, remember that
those modules are not compiled in dev. Compilation must precede standalone Credo runs.

Sobelow's `--private` disables update-check network requests; `--exit low` fails on
all reported confidence levels. `--skip` honors narrowly reviewed function annotations
in scenery storage/coordination, vault filesystem/migration helpers and architecture
tooling. `Traversal.FileModule` cannot distinguish trusted local configuration plus exact
content-hash/UUID or vault-journal filenames from user-controlled paths. Storage annotations
cover bounded reads, private/exclusive file creation, validated cutover and explicitly
confirmed cleanup. Scenery tamper/retention tests and synthetic vault migration fault
checks exercise those boundaries. Architecture tooling reads the fixed local `lib/**/*.ex`
glob under a developer-controlled root; it is not a symlink-confinement boundary.
Its `DOS.ModuleConcat`/`DOS.StringToAtom` annotations cover module identities derived from
trusted repository or synthetic AST only. Parsing and alias expansion allocate atoms;
the parser must never accept repeatedly submitted untrusted source or runtime inputs.
No whole-check, module, confidence-level, or fingerprint exclusion is configured.
Review annotations if these functions or their callers change; never extend them to
arbitrary uploads, user-selected runtime paths or provider content.
The browser pipeline retains its explicit CSP; the image endpoint has a restrictive CSP
and `nosniff`. These are not an email sanitizer or a complete auth/security review.

`mix audit` runs `mix deps.audit` and `mix hex.audit` for known security advisories
and retired packages. Use Hex 2.6 or newer (`bin/lovelace mix local.hex --force`);
older Hex releases can report only retirements, not the current Hex advisory feed.
Audits are intentionally separate from the local quality gate because they access
external registries/advisory repositories. CI installs current Hex and runs both
gates. A clean audit is a point-in-time result, not a guarantee about transitive code.

Hosted CI runs the full `bin/lovelace check` gate on pull requests and pushes to
`main`; use the workflow's manual dispatch for a development branch without a PR.
Branch pushes with an open PR do not create a second identical run. New commits
cancel superseded runs for the same ref, and each job has a 25-minute deadline.
The runner is pinned to Ubuntu 24.04; actions use immutable revisions of supported
Node 24-based releases. Native build caches include the runner image and architecture.
The dependency audit still runs after a quality/test failure when dependency
installation succeeded. Generated synthetic HTML coverage reports are retained
as GitHub Actions artifacts for seven days, including failed coverage runs.
Scenery generation is disabled in CI; providers and credentials remain synthetic.
This is a verification workflow, not an automatic deployment or release pipeline.

The Linux runner verifies that production maintenance refuses unavailable native
keychain access without changing original storage or starting protected work.
The task's refusal is the contract, not an unsolicited supervisor `EXIT`: OTP may
flush failed-start link signals before returning. That is not proof of macOS native
keychain availability or authorization; attended native checks remain explicit,
and the browser UI gate below remains separate.

## Browser UI regressions

```sh
LOVELACE_STAGE_ENABLED=false mix test.ui
# If Chrome/Chromium is not in its usual location:
LOVELACE_BROWSER=/path/to/chrome LOVELACE_STAGE_ENABLED=false mix test.ui
```

This separate, explicit gate uses installed Chrome/Chromium and Node's built-in DevTools
WebSocket client: no npm packages, browser download or third-party test service. It fails
if a browser is unavailable; `mix check` and hosted CI do not automatically run it.
The alias rebuilds deployed assets (including compressed copies, avoiding stale gzip),
then `test/support/ui_browser.exs` starts a separate test-only app on an ephemeral loopback
port with a new disposable SQLite database, scenery directory and Chrome profile.
Migrations and synthetic owner/workspaces/account/image fixtures are local to that run.
Before publishing synthetic scenes, the runner also verifies the genuinely empty gallery
with the public bundled default artwork, including no-JS unlock, decoded image loading,
and the same default across static/live views, navigation, scenery wake and reload.
Gmail/vault responses are fake, Oban is manual, real transports/vault are refused by test
builds and generation is disabled. It does not reuse a user's server/profile/private data.

`test/browser/ui_contract.mjs` exercises the actual compiled assets and LiveView socket:
normal entrance/directional exit and gate; corner/Lock computed visibility and focusability;
static unlock with/without JavaScript; static/live image success/failure; native menus;
workspace/integration/Connections navigation; unsaved input, scroll and first-key/click wake;
reduced-motion changes; forced colors; desktop/narrow layouts; dedicated reader body size,
reading measure and long-token wrapping; native message/recipient disclosures and Refresh
preservation; reader Escape/wake and async browser-Back row-focus/scroll restoration;
real URL Back/Forward, copied conversation/search/page links and workspace reload; and page errors/off-origin
requests/CSP events across navigation. The real browser idle timer uses a shortened
**disposable DOM setting**; native Node tests retain the actual three-minute deadline.
Chrome is shut down and disposable data removed on completion. The runner has startup,
protocol, a 120-second overall deadline and shutdown deadlines; it is not a cross-browser
or screen-reader suite. Delayed synthetic reads exercise A→B→A navigation on one LiveSocket;
durable GitHub discovery retains operation/job correlation across a browser reload.
See [UI_CONTRACT.md](UI_CONTRACT.md#verification-map) for coverage boundaries.

### UI themes

Authenticated `/settings` selects Charcoal, Earth, Sea Glass or Mist without changing scenery.
`assets/css/themes.css` is the sole home for raw UI palette values. Its `--theme-*` primitives
feed DaisyUI's existing `--color-*` API and shared semantic border/surface/glass/shadow tokens.
Keep component CSS on those semantic tokens; picker swatches use the same palette primitives.
All four themes are dark, and forced colors retains system-color overrides.

`assets/js/theme_boot.js` is a small synchronous, self-hosted esbuild entry loaded before CSS.
It restores only an allowlisted `lovelace:theme` value from browser-local storage; Sea Glass is
the fallback. The native-radio `ThemePicker` hook applies/persists selection and announces
failed storage without pretending it saved. Preferences do not enter the database, account
state or provider calls, and already-open tabs do not synchronize live.

`mix check` includes storage/failure/lifecycle regressions. `mix test.ui` exercises all four
themes across Settings, Home, Workspaces and mail, reload/history persistence, native keyboard
selection, preserved imagery, protected deep links and narrow/forced-color layouts.

## Test conventions

- Use `Lovelace.DataCase, async: false` for database/resource tests and the existing
  SQL sandbox helpers. `LOVELACE_TEST_DATABASE` optionally selects a disposable test
  database (create its parent directory first); it has no effect outside test config. Ash async execution is disabled in `config/test.exs`.
  Normal `mix test` uses unmanaged, synthetic test-only SQLite storage and sandbox
  setup, not the managed encrypted database/keychain. Never point
  `LOVELACE_TEST_DATABASE` at a real development/production database or migration backup.
- Keep ConnCase/LiveView tests synchronous because they also acquire the sandbox.
  Pure functions and isolated `Req.Test` cases may be asynchronous.
- Launcher regression tests execute `bin/lovelace` from an unrelated directory with
  spaces using a temporary, fake-only `PATH`. Keep environment overrides child-local
  (`System.cmd/3`), clean up temporary files with `on_exit/1`, and assert captured
  argv/cwd/environment and exit statuses. These isolated cases may be asynchronous;
  they must never invoke real Mix, IEx, Homebrew, native helpers, or providers.
- Create records through Ash actions or `Ash.Generator` helpers. Use `Ash.Test` for
  validation/policy assertions; test denied operations as deliberately as allowed ones.
- Production domains go in `config :lovelace, :ash_domains`; don't register test-only
  resources as production domains just to appease a generator.
- Prefer Req's built-in test plug at the actual HTTP boundary. Explicitly pass the
  injected request/client options through integration code. Never let provider tests
  depend on Google, real OAuth tokens, or live mailboxes.
- Req.Test stubs are process-owned. Future job/process tests may need `Req.Test.allow/3`
  or explicit ownership setup; don't solve this by turning tests into network calls.
- Add Mox only when a behaviour boundary genuinely needs expectations independent
  of HTTP; do not mock Ash or SQLite instead of exercising them.
- Protect account separation with adversarial tests: reused provider IDs, cross-account
  links, late responses after switches, credentials, jobs, and PubSub subscriptions.

`test/support/ash_probe.ex` and `ash_domain.ex` are test-only infrastructure fixtures.
Their table is created transactionally within the sandbox and rolled back after each
test. They exercise Ash reads/creates, validation, and transaction rollback without
creating real application tables or migration snapshots.

`bin/lovelace test --cover` uses Mix's built-in line coverage with an explicit
90% threshold in `mix.exs`; `bin/lovelace check` and CI enforce the same gate.
HTML reports are generated locally in the ignored `cover/` directory. Plain
`bin/lovelace test` remains available for focused runs without the full-suite gate.
No coverage service or production-module exclusions are configured.

Managed-vault and terminal-maintenance scenarios run in separate BEAMs.
`test/support/subprocess_coverage.ex` collects their counters during coverage runs
and imports only byte-identical modules; production builds are never replaced
with test builds to merge coverage. Failed children still fail their regression
tests, and a successful child without a readable coverage export fails collection.
Child coverage compilation submits the byte-identical set to OTP's bounded worker
pool. Maintenance subprocess tests allow up to five minutes for cold production
compilation and instrumentation; hangs still fail, without automatic retries.
Temporary manifests/counters are removed after each child. Ordinary test runs
do not instrument children. Attended native-keychain tests remain opt-in and
excluded from the automated suite; line coverage does not certify browser visuals,
native authorization dialogs, or live-provider behavior.

## Ash development and migrations

`Lovelace.Repo` is an `AshSqlite.Repo` (still an Ecto repo). Writes use AshSqlite's
transaction support and a single SQLite connection. Keep transactions short and do
not hold them across network calls. There is no separate read replica/repo yet.

The declared minimum SQLite syntax version is 3.38.0, AshSqlite's baseline; managed
storage separately requires SQLCipher **4.20.0** linked through Exqlite. Raise the
declared syntax minimum intentionally before using newer features and verify CI compatibility.

When adding a domain resource:

1. Use an Ash resource/domain and explicit actions/accepted attributes/policies, not
   a parallel Ecto context implementation for the same behavior.
2. Register the domain in `config/config.exs`.
3. Generate migrations, review SQL, and commit **both migrations and resource snapshots**.
4. Test from an empty database as well as the current development database.

```sh
bin/lovelace mix ash.codegen meaningful_change_name
# Managed migrations apply through vault unlock, not standalone ash.migrate.
# Check generated schema drift in the synthetic test environment:
MIX_ENV=test bin/lovelace mix ash.codegen --check
```

Codegen drift is part of `mix check` now that `Lovelace.StageDesigner` owns a production
SQLite state resource. Its migration and snapshot must stay together. The singleton's
version-checked reservation commits before HTTP; SQLite does not support Ash's atomic
`expr_error`, so these three updates explicitly use the record path with a SQL version
filter (`require_atomic? false`, `atomic_upgrade? false`), not an unchecked read/write race.
Conventional `mix ecto.*` setup/reset workflows are not for managed real data. Do not generate
additional owner/auth resources without reviewing the existing single-owner password/session
implementation. Google identities use immutable `sub`, not case-insensitive email uniqueness.

The base Ash installer configured Spark formatting, current recommended compatibility
settings, dev/test policy diagnostics, signed pagination keysets, and dev protocol
recompilation support. Pagination keys are not authentication/token-encryption keys.
If compile-time Ash settings change after dependencies are compiled, rebuild affected
dependencies; do not disable compile-environment validation to hide a mismatch.

## Igniter and dependency guidance

Igniter is installed locally; no global generator installation is required for its
project tasks. Prefer a preview before applying a generator:

```sh
mix igniter.install package_name --dry-run
```

Review changes before accepting. In particular, installing `ash_authentication` with
its full installer may generate resources, strategies, routes, and migrations; those
were deliberately **not generated** in the historical foundation pass. The later owner-unlock
slice adds its own password strategy/resources without public signup. Protect `.tool-versions`,
loopback binds, design tokens, and existing project-specific guidance.

UsageRules configuration lives in `mix.exs`. It writes a linked index to
`DEPENDENCY_RULES.md`, leaving the hand-written root `AGENTS.md` compact. Dependency
sources remain in ignored `deps/`; run `mix deps.get` before following those links.

```sh
mix usage_rules.sync          # preview/confirm updates
mix usage_rules.sync --yes    # apply after review
mix usage_rules.search_docs "Ash.Test" -p ash
```

Refresh the guidance index when dependencies change. Not every dependency ships
usage rules (currently Req and AshSqlite don't); use their HexDocs directly:
[Req.Test](https://hexdocs.pm/req/Req.Test.html),
[AshSqlite](https://hexdocs.pm/ash_sqlite/getting-started-with-ash-sqlite.html).

## Tidewave safety

`Tidewave` is included **only in dev** and plugged under `if Mix.env() == :dev`.
Its MCP endpoint is <http://localhost:4321/tidewave/mcp> while the development server
runs. It can execute Elixir and SQL with the process's access to local data.

- Never set `allow_remote_access: true`, expose through a tunnel, or include it in
  production. Loopback binding remains mandatory.
- Clients require explicit MCP connection configuration; no agent/editor config or
  external service was silently installed by this bootstrap.
- Tidewave may inject a toolbar and relax CSP for development browser tooling
  (including `unsafe-eval`/frame restrictions). That is not a production CSP policy.
- Future real-mail development sessions must consider tools' access to message bodies,
  credentials, logs, and query results. Avoid sharing sensitive output with agents.

## CI and tooling scope

`.github/workflows/ci.yml` runs on pushes and pull requests with read-only repository
permissions. It reads Elixir/OTP from `.tool-versions`, caches dependencies/builds,
installs asset binaries, and runs `mix check` plus `mix audit` in the test environment.
It also installs Node LTS for the native hook tests; no npm install or external application
service is required. Local runs do not prove hosted runner/runtime availability;
verify the relevant GitHub run before claiming hosted CI passed.

Current tooling is defined by `mix.exs` and the CI workflow, not a wishlist of deferred
packages. Do not add infrastructure just because a package is conventional. New tooling
needs a concrete requirement from the current task, not an old plan.

## Private mail instrumentation

Repo ORM defaults set `log: false, telemetry_event: nil`: SQL telemetry contains both
bound parameters and returned rows. Do not use raw SQL or override those options for
mail. LiveView render payloads use bounded ephemeral `Mail.ViewData` references rather
than body-bearing socket assigns. Provider HTTP bypasses Req/Finch payload instrumentation.
Tests use fake providers/vaults; native Keychain operations and real Google connectors
are refused by test builds. Oban runs in manual mode in tests, without queues/plugins.

No external telemetry exporter is configured. The user explicitly accepted stock
Bandit's in-process HTTP conn metadata after verifying its official documentation;
request headers/query strings are not stripped before its initial event. Early password/
OAuth plugs avoid additional Phoenix instrumentation, not Bandit's prior emission.
Do not claim complete payload-free server telemetry, and do not attach payload loggers/
exporters without a new review. See `GMAIL.md` for the precise exception and trust boundary.
Escape/idle only changes scenery and continues work; use global Lock to revoke owner
sessions, stop protected work and close/lock storage. Development Tidewave remains a
separate trusted local code/SQL capability, not a sandboxed mail viewer.
