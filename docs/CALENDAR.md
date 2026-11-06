# Read-only Google Calendar in LOVELACE

## Scope and setup

Calendar is optional on an existing Google/Gmail connection. Home and workspace agendas
remain **per account**, never a merged calendar. This slice shows browser-local **today**:
time, title, calendar name, all-day/ongoing labels and an explicit link back to Google
Calendar. It does not create/edit events, RSVP, join meetings, fetch attachments, render
descriptions/HTML or load remote imagery. Repeating events are expanded by Google.
Home presents each account's agenda in a quiet inset card matching Gmail and GitHub,
while workspace and Connections layouts retain their existing controls and health details.

1. Enable the **Google Calendar API** in the same Google Cloud project used for Gmail.
2. Add these read-only scopes to its consent configuration, retaining the existing
   OpenID/email/Gmail scopes:
   - `https://www.googleapis.com/auth/calendar.calendarlist.readonly`
   - `https://www.googleapis.com/auth/calendar.events.readonly`
3. Complete the encrypted owner setup or stopped-application migration described in
   [GMAIL.md](GMAIL.md); never reset a private database or apply plaintext SQLite tooling
   to the encrypted database.
4. Start LOVELACE with `bin/lovelace server` and unlock. During onboarding, connect Gmail,
   then use **Calendar (optional) → Enable read-only Calendar**, or skip Calendar and
   retain Gmail alone. The account's email is shown before consent; choose that same
   Google account. Later, **Connections → Calendar** offers the same opt-in authorization
   for an existing Google account with an explicitly selected receiving workspace.
   This reuses the same Google subject and Keychain item, not a second identity or owner
   login. Choosing another Google identity is rejected. Granting Calendar retains
   read-only Gmail and any previously enabled YouTube access, requiring complete scope evidence.
5. Consent started in onboarding returns to `/onboarding/calendar`, where the browser
   requests a queued first read for its local day and shows the calendar selection inline.
   Google's selected calendars seed the selection, including shared calendars. Save your
   selection (at most 20 calendars), then choose **Continue** to review setup before explicitly finishing.
   An empty selection is valid; it means no calendars selected, not no events in Google.
   A validated cancelled or failed attempt returns to the same step to retry or skip
   without removing Gmail. Consent started in Connections returns to `/connections/calendar`,
   where the same selection can be changed later.

The inline picker binds every load and status response to the workspace, account and
connection generation that started it. Initial page assembly also checks that the heading
and picker identities agree; a concurrent change leaves the picker unavailable rather
than exposing another account's controls. Reload the whole step to see the current
connection. Reconnect/detach fences still apply to every server mutation. Pending requests
are aborted on navigation, and late responses cannot update a departed page. Owner-session
redirects navigate the whole page rather than installing partial HTML.

Status checks run at 1.5-second intervals for at most 20 attempts. If work remains
pending, the picker explicitly says automatic checks have stopped; this does not cancel
the queued read or claim success. **Refresh calendar status** performs one metadata-only
GET, without starting another provider read or another automatic polling loop. Its
`?status=1` reload also suppresses first-read autoload. It preserves existing unsaved
choices and keyboard focus when the picker can become ready. **Refresh calendars** is
different: it explicitly queues the existing bounded read even before the normal interval,
while retaining job uniqueness and all rate-limit cooldowns. Every browser request has a
10-second deadline covering both fetch and response-body reading. Failure or timeout keeps
edits, exposes recovery, and does not automatically retry; it does not cancel queued work.

Calendar consent is never requested automatically. Denying or partially granting optional
consent leaves the existing shared connection intact. A normal Gmail reconnect disables
Calendar and YouTube locally; explicitly authorize them again afterward. Calendar failures
have independent health and freshness, rather than overwriting Gmail's unread count or
sync errors. A global Google credential failure can require reconnecting the shared connection.

The browser's `/onboarding/project` and `/onboarding/authentication` steps include the
Calendar API and both scopes above alongside Gmail setup. The optional stopped-terminal
`bin/lovelace mix lovelace.google.configure` maintenance workflow, testing-mode token
lifetime, local-only OAuth flow, owner session security and dedicated-keychain/signing
limitations in [GMAIL.md](GMAIL.md) also apply. Runtime Google client ID/secret environment
variables are ignored. Calendar shares the dedicated password-unlocked LOVELACE keychain
credential; no native helper rebuild or permission repair is needed to add Calendar.
There is no password recovery. Do not paste credentials, OAuth callback URLs or real
calendar contents into tests or reports.

## Day, freshness and bounds

The browser sends today's local midnight and the next local midnight as UTC instants,
with a local date and timezone label. DST days are not assumed to last exactly 24 hours.
Timed events overlap that interval; all-day events use inclusive start and exclusive
end dates. Ongoing and multi-day events are included. No local timezone database or
new dependency is required. The day is rechecked on a timer and visibility/resume events.

A connection retains one browser-day context at a time. Browsers in different timezones
may replace that context; a view never presents a different context's events as its own.
Polling targets three minutes via Calendar's independent minute Oban sweep while LOVELACE runs
unlocked. Both Calendar workers use the dedicated `:calendar` queue at concurrency one;
Calendar recovery does not wait for Gmail's sweep to complete. Each sweep examines at most
100 expired and 100 due contexts. It stops requesting an expired day until a browser supplies the next day.
Explicit global **Lock** stops Repo, Oban and provider work; startup stays locked until
owner unlock. Visual idle/Escape is not a lock and keeps authorized background work
running. Sleep, network failures and queue backlog delay updates; nothing runs with
the computer/app stopped.
Manual Refresh requests another bounded read, not instant or push delivery. Known rate
limits impose a five-minute Calendar cooldown, including manual Refresh.

Work is bounded to 100 listed calendars, 20 selected calendars, 100 expanded events per
calendar and 500 retained agenda events, within a 512 KiB payload bound. Provider pages
beyond these limits are not silently represented as complete: the UI labels partial
results, including the onboarding picker. The persisted bounded-result warning is separate
from the warning that Google-selected calendars exceeded the 20-calendar selection bound;
the latter requires a smaller explicit selection. No local full-calendar mirror, history
index or push service is introduced.
API time bounds are widened before exact local-day filtering to account for all-day
entries whose calendar timezone differs from the browser's.

The account-scoped cache contains minimal event text in **SQLCipher-encrypted SQLite**,
retained for at most 24 hours and never served after expiry. Its independently generated
database key lives in the dedicated LOVELACE keychain. Cleanup runs only while unlocked;
logical deletion is not forensic erasure from SQLite pages/WAL/backups or browser copies.
Retained legacy plaintext databases, sidecars and login-keychain secrets remain exposed
under their old protections until explicitly deleted during terminal migration; deletion
does not guarantee APFS snapshot or backup erasure. Protect OS permissions, FileVault and
backups. Encryption does not protect an unlocked process or code running as your OS user.
Refresh failures retain known observations with stale/error labeling and unchanged
observation timestamps. Unknown/loading/error are not an empty successful agenda.

Jobs contain only account ID, connection generation and context revision. Account and
revision fences discard late results after reconnect, disconnect, day or selection changes.
Titles/calendar names are untrusted escaped text. Links are allowlisted HTTPS Google
Calendar destinations and are followed only by an explicit click.

## Application boundaries

`Lovelace.Calendar.catalog/2` is the authorized, provider-free catalog capability used by
onboarding. It selects only catalog metadata from protected storage, never cached events
or an event-bearing agenda. Calendar owns the catalog's 24-hour freshness, loading/error
states, independent bounded-result/selection warnings, selection limit and cooldown deadline.
Onboarding adds its workspace/account/generation fence and uses Calendar actions for every
mutation; it does not query Calendar persistence or reconstruct Calendar policy.

`Lovelace.Google.Access` is the single shared Google identity/credential coordination owner.
Gmail, Calendar and YouTube use the same account and subject serialization, generation checks
and refresh-token rotation. Optional consent checks the expected current generation and all
captured optional scopes under that serializer. Unbound Gmail consent also rechecks its captured subject connection
(`:absent` or immutable account ID/generation) after acquiring the account lock, before any
credential access; a late callback cannot resurrect a disconnected or replaced generation.
Grant replacement commits the shared account/membership, clears Calendar and YouTube
synchronously, and only then admits the next Gmail sync and broadcasts invalidation.
Disconnect uses that same serializer/reset boundary. Calendar never reaches into private
Mail operations. The existing shared-credential admission gate still respects an active
Gmail rate limit; Calendar provider failures/cooldowns remain Calendar-owned and do not
overwrite Gmail health.

`Lovelace.Calendar.Provider` owns the typed bounded-page contract; the concrete
`Lovelace.Integrations.Google.Calendar` adapter and synthetic fakes implement it.
Calendar-list and expanded-event calls return at most 100 items with explicit truncation,
finite safe error atoms and a finite whole-operation deadline. Adapters do not follow
pagination or establish persisted freshness. Calendar retains responsibility for exact
day overlap, selected-calendar/aggregate limits, observation timestamps and publication
fences. Credential refresh is separate from the read-only page contract. Safe reads may
be requested again; a queue completion is not evidence of a successful fresh observation.

## Removal and verification

Removing an account from a workspace removes only that workspace association. It does
not disable the reusable Google connection or revoke Google access. **Connections
→ Gmail → Disconnect everywhere** fences Gmail, Calendar and YouTube, clears their local
caches and workspace associations, deletes the shared keychain credential and attempts
Google revocation. Revoking the shared grant can affect all three services; Calendar does
not expose an independent destructive revocation control.

Automated tests use synthetic provider/vault responses and disposable browser data.
They do not verify your Google consent configuration, shared-calendar permissions,
real event completeness or native Keychain access. Real authorization remains an explicit
manual setup step. See [DEVELOPMENT.md](DEVELOPMENT.md) for the check/browser commands.
