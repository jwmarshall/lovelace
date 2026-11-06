# LOVELACE

A quiet place to orient your day.

LOVELACE is a personal homepage that runs locally on your Mac. Read Gmail,
optionally see today's Google Calendar agendas, follow GitHub activity, and watch selected
YouTube subscriptions in a bounded chronological feed.
Workspaces group separate accounts and GitHub personal/organization installations by area of life.

- Read-only: no sending mail, changing mailbox state, editing events, modifying repositories,
  or changing YouTube subscriptions/playlists. The click-loaded official player can show
  YouTube-controlled ads and related content.
- One local owner; its password unlocks a dedicated macOS keychain and SQLCipher-encrypted SQLite database.
- Local-only: keep it on loopback, not a public server or tunnel.
- Startup is locked. Explicit Lock stops protected background work; visual idle/Escape does not.
- No password recovery. Existing plaintext data requires an explicit, stopped migration.

A glass interface keeps your work in front of the scenery.
[Optional generated scenery](docs/STAGE_DESIGNER.md) is opt-in and may incur API costs.

## Try it locally

After installing the [local prerequisites](docs/DEVELOPMENT.md#local-setup), run:

```sh
bin/lovelace setup
bin/lovelace server
```

Open <http://localhost:4321>, pair the browser using the code printed in the terminal,
and create your owner password and encrypted keychain. The app then guides your own
[Google project and OAuth setup](docs/GMAIL.md#2-google-cloud-setup), audience/test users,
Desktop client credentials, and Gmail connection. You can skip Gmail and resume later;
Calendar requires separate consent. No password recovery is available.
For a review without touching existing data, use the
[isolated fresh-onboarding instructions](docs/DEVELOPMENT.md#fresh-onboarding-without-resetting-existing-data).
GitHub uses App sign-in and selected personal/organization installations; see
[GitHub setup](docs/DEVELOPMENT.md#github).
Optional [YouTube setup](docs/DEVELOPMENT.md#youtube) reuses a Google connection with
separate consent. Enable YouTube Data API v3, authorize in **Connections → YouTube**, then
choose subscribed channels. No remote thumbnails; the player loads only after an explicit playback click.

## Development

Built with Elixir, Phoenix LiveView, Ash, and SQLite.

```sh
bin/lovelace check           # format, compile, lint/security, tests, and assets
bin/lovelace audit           # online dependency audit
bin/lovelace mix test.ui     # browser checks; requires Chrome/Chromium
```

[Development guide](docs/DEVELOPMENT.md) · [Gmail](docs/GMAIL.md) ·
[Calendar](docs/CALENDAR.md) · [YouTube](docs/DEVELOPMENT.md#youtube) · [UI and accessibility](docs/UI_CONTRACT.md)
