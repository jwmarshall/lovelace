# MONOLITH

A quiet place to orient your day.

MONOLITH is a personal homepage that runs locally on your Mac. Read Gmail,
optionally see today's Google Calendar agendas, and follow open GitHub pull requests.
Workspaces group separate accounts and GitHub personal/organization installations by area of life.

- Read-only: no sending mail, changing mailbox state, editing calendar events, or modifying GitHub repositories.
- One local owner; its password unlocks a dedicated macOS keychain and SQLCipher-encrypted SQLite database.
- Local-only: keep it on loopback, not a public server or tunnel.
- Startup is locked. Explicit Lock stops protected background work; visual idle/Escape does not.
- No password recovery. Existing plaintext data requires an explicit, stopped migration.

The application and production interface use MONOLITH throughout. The
[design system](docs/MONOLITH_DESIGN_SYSTEM.md) governs presentation;
[UI contracts](docs/UI_CONTRACT.md) preserve operational and security behavior.
The identity cutover does not move, reset or migrate private data.

A glass interface keeps your work in front of the scenery.
[Optional generated scenery](docs/STAGE_DESIGNER.md) is opt-in and may incur API costs.
Automatic startup also requires a saved opt-in (absent means off) and enabling terminal
configuration. Saving the choice never generates; manual requests require fresh cost confirmation.

## Try it locally

After installing the [local prerequisites](docs/DEVELOPMENT.md#local-setup), run:

```sh
bin/monolith setup
bin/monolith server
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

## Development

Built with Elixir, Phoenix LiveView, Ash, and SQLite.

```sh
bin/monolith check           # format, compile, lint/security, tests, and assets
bin/monolith audit           # online dependency audit
bin/monolith mix test.ui     # browser checks; requires Chrome/Chromium
```

[Development guide](docs/DEVELOPMENT.md) · [Gmail](docs/GMAIL.md) ·
[Calendar](docs/CALENDAR.md) · [UI and accessibility](docs/UI_CONTRACT.md)
