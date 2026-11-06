# Read-only Gmail in LOVELACE

## Scope

Optional read-only Google Calendar agendas reuse these connections with separate,
explicit consent and independent Calendar freshness. See [CALENDAR.md](CALENDAR.md)
for scopes, selection, browser-local today, polling and shared disconnect semantics.
Optional read-only YouTube subscriptions also reuse these connections with explicit
consent and independent account feeds. See [DEVELOPMENT.md#youtube](DEVELOPMENT.md#youtube).

One local owner unlocks LOVELACE with a password. Google connections are **not**
owner identities. Connect Google once and attach that connection to one or more
workspaces. Each workspace can contain several accounts; each inbox, search,
conversation, cache, job and update remains account-scoped. There is no unified inbox.
Projects, sending, drafts and archive/read/label changes remain outside current scope.
Attachment lists appear in opened message details. Files are fetched only on demand, never
persisted in the mail cache, and limited to 5 MiB per file. Explicit downloads are available
for bounded attachment types; only JPEG, PNG, GIF and WebP receive inline previews. SVG,
HTML and other active document formats are never rendered inline. Downloads use an
owner-protected route, safe generic content type, forced attachment disposition and
`nosniff`; preview bytes use a separate raster-image allowlist. Attachment IDs must match
metadata from the cached, account-scoped thread, and connection generation is checked
again after provider fetch. Reading a conversation or fetching an attachment does **not**
mark it as read in Gmail.

This is a macOS-first integration. Automated tests use synthetic providers and vaults,
not real accounts or credential values. Follow the manual steps below to activate a new
installation yourself.

## 1. Local preparation

For a new installation, install the [local prerequisites](DEVELOPMENT.md#local-setup)
and run from a private checkout:

```sh
umask 077
bin/lovelace setup
bin/lovelace server
```

The launcher handles SQLCipher **4.20.0** internally. `bin/lovelace setup` prepares the native binding,
helper, and assets without initializing application storage. Open <http://localhost:4321>
and pair the browser with the private one-time code printed in the server terminal.
Choose and confirm an owner password, then acknowledge permanent password loss.
The browser creates the encrypted schema and dedicated password-unlocked file keychain;
do not use ordinary plaintext SQLite migration/reset commands. For a fresh review beside
existing data, use the [isolated installation instructions](DEVELOPMENT.md#fresh-onboarding-without-resetting-existing-data).
Keep data directories private (`0700`) and files owner-only (`0600`); `umask` affects new files only.

Passwords require 12–1024 characters and at most 1024 UTF-8 bytes. Never pass them as
command arguments. The independently generated database key is stored in the dedicated
keychain, not derived from the owner password. There is **no password recovery**.
Initial native creation may display a macOS authorization dialog for this dedicated
keychain; enter the same owner password there, never in shell arguments or chat.
If setup is interrupted, restart the server, pair again, and resume `/setup` with the
**original password**. Private setup/creation markers and unused encrypted staging files
are preserved; initialized keys and owner credentials are never replaced. Never delete
those markers to force setup. The stopped-terminal `lovelace.owner.setup` task remains
available for explicit attended maintenance, not required first-run setup.

For an existing plaintext installation, stop the application and run
`bin/lovelace mix lovelace.vault.migrate` in a terminal. It verifies the owner
password and copies legacy credentials into the dedicated keychain. Separate exact
confirmations govern `CUT OVER`, `DELETE PLAINTEXT` and `DELETE LEGACY SECRETS`.
Original database files (including WAL) and legacy secrets are retained by default;
they remain exposed under their old protections until explicitly deleted. Migration
is journaled and resumable. Deletion is not guaranteed secure erasure of APFS snapshots,
backups or previously copied data. Never reset the database to migrate it.

The Keychain build requires Apple's Command Line Tools (`xcrun swiftc`). The generated
`priv/native/lovelace-vault` binary is ignored, not a committed executable. Build on
the target Mac before packaging a release; it must be included in the release's `priv`.
The helper uses Security.framework and explicit references to the dedicated
`lovelace.keychain-db`, without changing the user's default keychain or search list.
Gmail refresh tokens use the fixed **LOVELACE Gmail** service and an account UUID,
not an email address; Google client credentials use **LOVELACE Google OAuth**.
Secrets travel over bounded private stdin/stdout, never argv, temporary files, SQL
or job arguments. Access tokens are transient in memory. There is no runtime login
keychain fallback, plaintext fallback or iCloud synchronization. Legacy login
keychain access is confined to explicit terminal migration.

Explicit paired-browser/terminal setup and terminal migration may enable macOS authorization UI (up to two
minutes per operation). Migration permits legacy item reads/deletions and approval of
the existing Database-key item after a helper rebuild; it never replaces that key.
Approval must allow the verified helper's later noninteractive reads. A `login`
keychain dialog uses that keychain's password, normally the macOS account password;
dedicated LOVELACE keychain dialogs use the owner password. Ordinary unlock,
background access and credential operations remain noninteractive and fail closed
on lock or access-control/signing mismatch.
Unlock the dedicated vault through LOVELACE's owner password flow.
Rebuilding/replacing an unsigned or ad-hoc-signed helper can change its Keychain
identity; do not grant all applications access to these items. The macOS file-keychain
APIs are deprecated; this is not a signed desktop installer or a validated cross-version
Keychain migration. Actual credential-store behavior needs attended validation on your Mac.

The helper uses deprecated custom-file `SecKeychain` APIs. Normal Lock and shutdown
lock that keychain, and every application startup relocks it before accepting an
unlock. After an abrupt crash, macOS's keychain daemon may still hold it unlocked
until the next startup; instant crash-time locking is not guaranteed.

## 2. Google Cloud setup

After owner creation, `/onboarding` walks through these steps and saves your progress
locally when you continue. Console links open a new tab; keep the same project selected.
The guide does not automate or independently verify console changes. After naming your
workspace, you can defer all Google setup, or skip Gmail and Calendar individually.
Configure the client later in **Connections → Google** and connect accounts separately
in **Connections → Gmail**. Use a dedicated project at <https://console.cloud.google.com/>:

1. Enable the **Gmail API**. Enable **Google Calendar API** only for optional
   [Calendar](CALENDAR.md), and **YouTube Data API v3** only for optional
   [YouTube](DEVELOPMENT.md#youtube).
2. Configure **Google Auth Platform** branding and audience. Use **External** for
   personal Gmail or accounts from different organizations. Internal is limited to
   the project's own Google Workspace organization.
3. Add these Gmail scopes to the consent configuration:
   - `openid`
   - `https://www.googleapis.com/auth/userinfo.email` (the console's canonical email scope)
   - `https://www.googleapis.com/auth/gmail.readonly`

   For optional Calendar agendas, also add:
   - `https://www.googleapis.com/auth/calendar.events.readonly`
   - `https://www.googleapis.com/auth/calendar.calendarlist.readonly`

   The onboarding authentication step lists both groups. Configuring these scopes does
   not grant access: Gmail connection still requests Gmail-only authorization. Enable
   Calendar explicitly in the following optional onboarding step, or later through
   **Connections → Calendar**; see [CALENDAR.md](CALENDAR.md).
   For optional YouTube, add `https://www.googleapis.com/auth/youtube.readonly`, then
   authorize it explicitly through **Connections → YouTube**. Existing enabled optional
   scopes are retained only with complete returned consent evidence.

   OAuth requests may spell the email scope as the OpenID alias `email`; LOVELACE accepts
   Google's returned `userinfo.email` form too. Do not add `userinfo.profile` just to
   obtain an email address.
4. Create an OAuth **Desktop app** client for this locally installed application.
   A Desktop client is public; its bundled client secret is not a security boundary.
   Do not use service-account/domain-wide delegation or the obsolete OOB flow.
5. Keep the client ID and client secret local. Paste them into the protected
   **Connections → Google** (`/connections/google`) form while LOVELACE is unlocked, or
   save them during `/onboarding/client`. Both use the same dedicated keychain namespace.
   The forms never display stored values and perform no provider probe.
   No server restart is required. Runtime `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`
   environment variables are not read. Never paste credentials into chat, source, logs,
   URLs, or shell history; do not commit downloaded client JSON.
   For explicit stopped-server maintenance, `bin/lovelace mix lovelace.google.configure`
   remains available with hidden terminal prompts; it does not start provider work.
   Google Connections reports only local credential presence/availability, not verified
   Google access. Saving settings grants none of Gmail, Calendar or YouTube. Saving unchanged
   settings preserves grants. Replacing the client cancels pending authorization, fences
   active account generations, clears dependent caches and disables Calendar/YouTube.
   Reconnect Gmail, then explicitly enable optional capabilities again.

LOVELACE uses `http://localhost:4321/oauth/google/callback` by default. A custom `PORT`
changes the callback port too. Desktop clients support loopback redirects without
registering each port. Google recommends literal loopback IPs and an available port;
LOVELACE deliberately uses its fixed **localhost** web origin so the initiating owner's
host-only session cookie and LiveView origin checks agree. Always open the application
as `http://localhost:PORT`; IP aliases redirect to the canonical homepage. The listener
remains `127.0.0.1`, never a LAN interface.

If you deliberately choose a **Web application** client instead, register the exact
localhost callback URL (scheme, host, port, path and trailing-slash behavior must match).
That client represents a separately configured confidential local server, not a
secret safely distributed inside a desktop application.

### Consent mode and refresh-token lifetime

`gmail.readonly` is a **restricted** scope. External applications in **Testing** with
Gmail grants generally receive refresh tokens that expire after **seven days**. Add
all intended Google identities as test users while testing. For durable personal use,
review Google's personal-use exemption, move the consent application to **In production**,
and reconnect; do not assume an old testing grant becomes permanent. Google documents
an exemption from mandatory verification for personal-use apps below its user threshold,
not an exemption from its data-use policy or Workspace administrator restrictions.
Unverified-app warnings and user caps can still apply. Managed accounts may require
administrator approval. Tokens can be revoked or expire for other reasons too.

## 3. Connect and read

The fresh browser guide first asks you to name a workspace, then offers **Connect Google
account**, with that workspace shown as the destination and read-only access explained
before Google consent starts.
The server is already running; Google credentials are not required to start it.
For later sessions:

```sh
bin/lovelace server
```

The application starts locked: Repo, Oban and provider work remain stopped until
successful owner unlock. Unfinished onboarding resumes at its saved step unless a safe
requested destination takes precedence. Eligible, opted-in scenery generation can run
after the first successful ordinary unlock per startup; leave it disabled during setup review.
Gmail never starts a browser or requests consent automatically.

1. In onboarding, press **Connect Google account**. Otherwise open `http://localhost:4321`,
   unlock, choose **Workspaces**, enter a workspace, choose **Add integration**, then
   **Connect Google account**. Alternatively use **Connections → Gmail → Add Gmail account**
   and explicitly choose the receiving workspace in the modal, then **Connect Google account**.
   Cancel/Escape dismisses the modal without starting OAuth.
2. Choose the intended Google account and grant read-only mail access.
   Consent started in onboarding returns to `/onboarding/calendar`, where you can enable
   Calendar for the same account or skip it. Calendar consent returns to that same step
   to select calendars, including shared calendars or none, without visiting Connections.
   Choose **Continue** to review setup, then explicitly finish setup. Consent started elsewhere returns
   to the receiving workspace. The guide's completion page distinguishes saved Google
   authorization, an unconfirmed first read, failures, and a timestamped saved read
   observation. Open that account's inbox to request its first read; finishing or skipping
   the guide never invents a connection or a successful read.
3. LOVELACE binds the verified UserInfo `sub` to the connection. Email is a display
   attribute, not its stable identity. Reconnect cannot silently select another account.
4. Open one account's inbox; search uses Gmail syntax across that account, including
   sent/archived mail. Spam/Trash follow Gmail's ordinary search behavior unless requested.
   Inbox rows show sender/date, subject and a short preview. Opening a conversation enters
   a dedicated plain-text reader: earlier messages collapse, the latest opens, and full
   sender/recipient/date details are expandable. Refresh preserves disclosure choices.
   **Back to results** restores the current search/page and opened row's scroll/focus within
   this live view. Account/thread paths and submitted search/page queries support browser
   Back/Forward, reload and copied links; queries consequently appear in browser history and
   copied URLs, but are filtered from Phoenix parameter logs. Parseable dates display
   in browser-local time; original headers remain in message details. Compact fetch freshness
   ages locally, with an expandable exact observation timestamp and explicit stale/error states.
5. In another workspace, use **Add integration → Add to workspace** to reuse the connection
   without reauthorizing. Each attached Gmail tile opens only that account's inbox.

Workspace card warnings reflect known connection problems, not a new live provider check.
Home shows each non-disconnected account once, with workspace labels and paired unread
inbox **conversation** counts: the total from Gmail's INBOX label `threadsUnread`,
and the recent count from Gmail thread search with INBOX and UNREAD labels and
`after:<cutoff> before:<end>` received-time bounds. Both bounds are fixed UTC Unix
seconds at the start of one observation, exactly 86,400 seconds apart; this is a
rolling 24-hour window at Gmail search's second resolution, not a local calendar day,
message `Date` header, cached-page count, or unread-message count. Gmail decides which
conversations match its received-time search; each returned thread ID counts once,
even when several messages match. This is not a claim that every message in that
conversation is recent or unread. Gmail can change while the label and pages are
read; the API does not provide a transactional mailbox snapshot.

Recent search pages request IDs only, at most 500 IDs per page and ten pages
(5,000 returned IDs), under the same whole-operation deadline as the label read
(15 seconds by default, at most 30 seconds). A completed empty search means zero;
`resultSizeEstimate` is never used. A remaining page after the tenth, malformed page,
repeated page token, HTTP failure or timeout makes the **paired observation**
unavailable instead of publishing a partial count or refreshing only one number.
Both counts and their shared observation time are committed together, per account
and connection generation. Unknown recent counts, including on upgraded installations,
remain unavailable rather than becoming zero. Failures retain both last-known counts
and their original timestamp, with an explicit stale/error state. Unrelated page reads
cannot make them fresh. Reconnect and disconnect clear both numbers. Home cards show
**total / last 24h** and open that account directly, even if unattached to a workspace,
without adding membership.
Home never merges inboxes or shows message previews and never performs provider work on render.
Global **Connections** (`/connections`) is a provider overview, with no workspace query or
workspace-return control. **Connections → Gmail** (`/connections/gmail`) lists reusable
accounts in compact rows with last known health,
reconnect and confirmed disconnect-everywhere controls. New Gmail connections start from
an **Add Gmail account** button/modal rather than a permanently expanded form. Reconnecting globally explicitly selects a
workspace and also adds the account there; workspace-local reconnect retains its workspace.

Authorization uses system-browser code flow, S256 PKCE, offline access, single-use
10-minute state bound to the unlocked owner session, and a fresh identity lookup.
Restarting during consent cancels the in-memory attempt safely; start again.
A denied or expired grant produces a reconnect state, not endless credential retries.
Successful Gmail and Calendar consent started in onboarding saves and returns to
`/onboarding/calendar`; only explicitly continuing advances to the review step. Other Gmail
consent returns directly to `/workspaces/:id` for the explicitly selected receiving workspace.
The origin is saved with the single-use OAuth attempt, not taken from callback parameters
or an arbitrary return URL. Validated setup failures return to the corresponding guide
step with a generic retry/skip notice. Invalid or expired state and failures outside
setup retain safe diagnostics at `/connections/gmail`. These are real paths, not root-query navigation.
Receiving-workspace fields in OAuth forms/state remain membership intent, separate
from the post-consent destination and global Connections navigation.

Google and GitHub code exchanges execute on the protected single-concurrency `:oauth`
Oban queue. Authorized admission commits a safe correlation and ID-only job atomically;
codes, verifiers and session-bound material stay in bounded ten-minute in-memory holders.
A durable claim precedes secret consumption/provider exchange. Duplicate/rescued jobs never
reuse a claimed code; holder loss, restart or interrupted exchange requires fresh sign-in.
Google client replacement invalidates pending attempts before the native write. Safe exchange
correlations expire after 24 hours with a 1,000-row admission bound; no credentials enter SQL.

Interactive mail reads and account Keychain checks use authorized `Mail.request_read`
admission and ID-only jobs on `:gmail`, not LiveView tasks. Scoped sensitive input in
SQLCipher expires after ten minutes and is scrubbed at completion; at most 128 rows remain.
One current operation per live view supersedes obsolete queued reads. Opaque status/result
references are observable without PubSub. Private results belong to the authorized view,
not the short-lived worker; account generation/membership is rechecked when resolving them.
View exit, expiry and global Lock discard ephemeral results. These operations do not promise
recovery of a rendered body after restart: request another read instead.

## Connection troubleshooting

For existing accounts, **Connections → Gmail → Check Keychain** performs an explicit,
local-only read for that account, including accounts with no workspace membership.
The global request needs no workspace; its connection generation still fences delayed results.
The result contains only an allowlisted category and observation time, never the credential.
It does not contact Google, change permissions, refresh mail or clear persisted sync
errors/freshness. A readable token is **not** proof that Google still accepts it.
Checks are asynchronous, one at a time
per view, and discarded across connection-generation changes or leaving Connections.

- `locked`: the dedicated vault is locked, or the native helper reports authentication
  failure or interaction denied. An unlocked vault can still have an item-access failure.
- `timeout`: the helper did not complete within its existing bounded deadline.
- `not_found`: no credential was found for that account; reconnect Google.
- `unavailable`: helper/credential access could not be established; this does not
  prove that the item is absent or that Google is offline.
- `invalid_account` / `invalid_value`: the adapter rejected the identifier/value.

While LOVELACE is open, native authorization/access failures automatically trigger
global Lock, including denied/locked reads, helper unavailability or timeout, and
missing keychain storage. Active protected requests and jobs stop, browser sessions
are revoked, and the encrypted Repo closes. A missing individual credential
(`not_found`) or invalid local input does not lock the application. Detection happens
when a native operation runs; LOVELACE does not continuously monitor macOS ACL changes.
Restore native access, then unlock with the owner password. This does not by itself
mean Google authorization was revoked or require replacing stored credentials.

Review **About Keychain access** in Connections before changing anything. Rebuilding
the `lovelace-vault` helper can change its signing identity. Do not delete credentials,
grant all applications access, broaden partition ACLs, or repeatedly rebuild as an
attempted access repair. Diagnostics do not repair signing/ACLs or expose raw macOS
OSStatus values; exact native denial recovery remains a manual investigation.

The login/default keychain is **legacy-only**, accessed solely by explicit terminal
migration. Old helper access entries or prior login-keychain repair procedures are not
instructions for the current vault. If a legacy credential cannot be read during migration,
investigate only that legacy item and verified helper identity; do not broaden its ACLs
or move current credentials back to the login keychain.

`userinfo.email` is the canonical console scope for the OAuth alias `email`; both
forms are already supported. If consent completes but LOVELACE rejects the connection,
the flash and terminal now report an allowlisted stage/category (session/state,
token exchange, identity, account binding, offline token, Keychain or persistence).
Share only that safe category if needed, never a callback URL, code, state, token,
client secret or raw Google response.

A corrected native-helper stdin bug previously caused short JSON requests to wait
for 4096 bytes/EOF until the watchdog expired. The helper now uses bounded POSIX reads
and processes newline frames with stdin still open. After updating this source, run
`bin/lovelace mix lovelace.keychain.build` and restart LOVELACE, then start a **fresh**
connection attempt. Old binaries do not inherit Swift source changes. Restarting clears
pending OAuth state, so do not reuse an earlier callback URL. A macOS-only regression
compiles/runs the real helper with invalid inputs that cannot reach a credential operation.
Unreadable prior credentials now fail closed before any overwrite; a read error is not
interpreted as an absent credential during rollback.

## Retention, freshness and removal

- Fetch only requested pages and opened threads. Pages contain at most 20 conversation
  summaries. No full mailbox download, local search index, history cursor or push service.
- Persist fetched data for at most seven days, bounded to **120 entries / 25 MiB per
  account**; individual cached results are capped at 5 MiB. Oldest fetched entries are
  evicted first. Expiry is enforced on reads and the minute sweep while the app runs;
  no cleanup occurs while the app is stopped. This is logical record deletion, **not
  forensic erasure** of SQLite pages, WAL files, backups or browser-rendered copies.
- The business-data cache is encrypted in SQLCipher SQLite using the independently
  generated key held in the dedicated vault. The `.vault` directory also contains the
  keychain and an empty plaintext infrastructure-lock SQLite file, not business data.
  Encryption does not protect an unlocked process, browser-rendered copies or code
  running as your OS user. Protect permissions, FileVault and backups; retained legacy
  plaintext databases and sidecars remain exposed until explicitly removed.
- Plain-text MIME is preferred; HTML-only mail is conservatively converted to text.
  All output is HEEx-escaped. No HTML rendering, scripts, automatic URL requests, remote
  external images or automatic attachment fetches. Opening a conversation lists bounded
  attachment metadata; **Preview image** explicitly opens allowlisted raster formats in
  a new authenticated tab, and **Download** is a separate explicit action. Neither
  attachment route is requested merely by opening or scrolling a conversation.
  Attachment bytes are not retained in SQLite. Oversized files/threads fail
  safely instead of rendering partial content. Current MIME text expects UTF-8.
- Oban **2.24.2**, Apache-2.0, uses its bundled SQLite Lite engine. A minute cron sweep
  queues overdue per-account polls, targeting a three-minute interval, queue concurrency 1.
  It refreshes the first inbox page and independently reads the INBOX label's unread
  conversation count; open account-scoped views refresh through PubSub.
  Other cached searches/pages/threads refetch on demand. This is polling, not a complete
  history-based mailbox reconciliation. Sleep, rate limits, queue backlog and network
  failures can increase delay. The app does not execute while stopped/asleep.
- A known 429 holds provider admission for five minutes across polling, queued retries,
  automatic view refreshes, searches/threads and manual Refresh. Cached results retain
  the rate-limit/error and stale status; opening another view does not erase a known
  failure or extend the cooldown. Work already in flight cannot clear a newer cooldown.
- Poll jobs contain only account ID and connection generation; interactive read/cleanup
  jobs contain only an opaque operation ID. Pending authorized cleanup survives restart.
  Lifeline rescues abandoned jobs after five minutes; sweeps discover overdue accounts.
  Poll/cleanup jobs have at most three attempts; read jobs have two. Only safe read effects
  retry; a durable remote-revocation claim prohibits replay of an unknown revoke.
- Count observations are generation-fenced and cleared on reconnect/disconnect. Their
  separate errors preserve known values and observation times; a failed count read does
  not masquerade as a successful count update. Home's freshness label ages locally and
  marks counts stale after three minutes, including across hidden tabs/system sleep.
- Cache and errors show timestamps and stale status. **Refresh** explicitly requests
  another read. Explicit global **Lock** revokes sessions and stops Repo, Oban and
  provider work; no polling or cache cleanup runs while locked. Visual idle/Escape
  scenery mode is not a lock and lets already authorized background work continue.
- **Remove from workspace** in an integration tile's management menu removes one workspace association. It does not clear the shared cache,
  delete credentials, revoke Google access or stop polling that reusable connection.
- A remaining recovery limitation: a first connection can leave an unindexed Keychain
  item if the process dies after its credential write but before the identity commits,
  or if persistence and compensating deletion both fail. The token remains in Keychain,
  never SQLite, but normal disconnect cannot discover that orphan. No automatic orphan
  reconciliation is implemented; review the **LOVELACE Gmail** service in Keychain Access
  and Google application access after an interrupted/failed connection. Do not share item
  values. Successful-return failure paths attempt restoration/deletion and report failures.
- **Disconnect everywhere** atomically fences the connection generation, removes all
  memberships/cache and commits a durable disconnection operation plus ID-only job.
  Browser closure or navigation cannot cancel accepted cleanup. The worker retains the
  credential only until its one-shot revocation attempt settles, then deletes it; interruption
  after the durable claim becomes **uncertain**, never a repeated remote call. Missing
  credentials mean **unavailable**, not verified revocation. Local removal, credential
  deletion and remote outcome remain separate observable states. Failed deletion offers
  retry without another revoke; reconnect supersedes obsolete cleanup before credential
  mutation. Global Lock pauses work; unlock resumes under the same claim/generation fences.
  Pending, failed or uncertain cleanup remains visible in Connections, with recovery at
  <https://myaccount.google.com/connections>. Revocation may affect shared Google grants;
  it is not a mailbox mutation. Minimal identity/operation metadata retains safe outcomes
  and permits reuse of the stable connection ID on reconnection.

## Security and instrumentation decision

There is **no external telemetry exporter configured**. The user explicitly chose to
retain stock Bandit after reviewing this distinction:

- [Bandit 1.14.1 documents a `Plug.Conn` in HTTP request telemetry](https://hexdocs.pm/bandit/1.14.1/Bandit.Telemetry.html).
  It does **not** promise to strip request headers/query strings, and emits the initial
  event before endpoint middleware. OAuth codes/state, session headers and potentially
  buffered password bytes can therefore be visible to trusted code in the same BEAM.
  No external transmission or persistent logging was established. This is an accepted
  **local-only instrumentation exception**, not a claim that stock Bandit is payload-free.
  Do not install payload loggers, tracing/export agents or dump raw conn/socket metadata
  without a new privacy review. A stronger no-in-process-payload requirement needs a
  server-level upstream fix or separately approved dependency vendoring.
- Early password and OAuth callback plugs avoid *additional* Phoenix router/endpoint
  exposure. Normalized aliases cannot bypass them. Passwords/codes are not accepted in
  normal credential-bearing query-based forms, and logs filter sensitive parameter names.
  Calendar provider IDs can be email addresses: Phoenix filters `calendar_id` (including
  `calendar_ids` and nested selection values) before HTTP route and LiveView event
  parameter logging, including rejected, stale, and unauthorized form submissions.
  This does not sanitize raw request telemetry; never add raw payload logging.
- Provider HTTP uses private passive Mint, no Req/Finch payload telemetry, redirects,
  proxies or automatic retries. Fixed Google hosts/paths, TLS verification, byte/deadline
  caps and allowlisted errors apply. Test builds reject ordinary real-provider connections
  and native credential operations.
- Repo ORM defaults suppress raw SQL logging and Ecto query telemetry because those
  events contain mail parameters **and returned rows**. Do not bypass defaults with raw
  SQL or per-query overrides for mail. UI bodies live in bounded ephemeral render storage,
  not socket assigns. Standard browser/server instrumentation is not certified free of
  all private content; the explicit Bandit exception above remains.
- Owner sessions are digest-only server records with 12-hour absolute expiry, rate-limited
  unlock, CSRF protection, regenerated login sessions, and revocation/disconnection on Lock.
  Browser session cookies are encrypted and signed, including private requested-destination
  context through unlock; URLs/history can still expose submitted search context as described
  above. Earlier signed-only cookies require fresh unlock after this cutover.
  Escape/inactivity is scenery mode, **not** a security lock. Use **Lock** explicitly.
- Development Tidewave retains its pre-existing local code/SQL capability. Owner unlock
  does not sandbox development tooling. Never expose the application or Tidewave remotely.
- Use one running application instance for Gmail. Credential coordination and LiveView
  payload storage are local to that BEAM; scenery's separate multi-BEAM filesystem
  protocol does not make Gmail a distributed integration.

## Verification limits

Synthetic tests do not certify real-provider unread conversation totals/recovery, native
Keychain permissions, helper signing or cross-version credential migration. Validate these
manually when relevant; a previous successful connection is not standing permission for
provider operations or credential changes. Connected A→B→A delayed-result and rotating-token
reconnect/disconnect interleavings are not exhaustively tested. Keep account/generation
fences and use synthetic regression cases when changing those paths.

## References

- [Google installed-app OAuth](https://developers.google.com/identity/protocols/oauth2/native-app)
- [OAuth token expiration](https://developers.google.com/identity/protocols/oauth2#expiration)
- [Personal-use verification exceptions](https://support.google.com/cloud/answer/13464323)
- [OpenID Connect / UserInfo](https://developers.google.com/identity/openid-connect/openid-connect)
- [Gmail scopes](https://developers.google.com/workspace/gmail/api/auth/scopes)
- [Gmail thread list](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.threads/list)
- [Oban Lite engine](https://hexdocs.pm/oban/2.24.2/Oban.Engines.Lite.html)
- [Apple Security item API](https://developer.apple.com/documentation/security/secitemadd(_:_:))
