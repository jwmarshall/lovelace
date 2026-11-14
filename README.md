<p align="center">
  <img src="docs/assets/monolith-solid.svg" alt="MONOLITH" width="240" height="189">
</p>

**A quiet place to orient your day.**

MONOLITH is a local-first personal homepage for macOS. Read Gmail, see today's
Google Calendar agendas, and follow GitHub pull requests, issues, and recent
Actions runs. Workspaces bring accounts together by area of life while keeping
each account's activity separate.

- **Read-only integrations.** No sending mail, changing mailbox state, editing
  events, or modifying repositories. Calendar requires separate, opt-in consent.
- **Local, encrypted storage.** One owner, a dedicated macOS keychain, and a
  SQLCipher-encrypted SQLite database. Keep the server on loopback.
- **A focused interface.** Your work sits in front of app-wide scenery.
  [AI-generated scenery](docs/STAGE_DESIGNER.md) is optional, opt-in, and potentially billable.

## Get started

Install the [local prerequisites](docs/DEVELOPMENT.md#local-setup), then run:

```sh
bin/monolith setup
bin/monolith server
```

Open <http://localhost:4321>, pair your browser with the code printed in the
terminal, and create your owner password. Onboarding guides you through naming
your first workspace and optional Google setup. GitHub has its own
[setup guide](docs/DEVELOPMENT.md#github).

**There is no password recovery.** Every startup is locked; explicit Lock stops
protected background work. Escape and visual idle change only the scenery.

## Development

Built with Elixir, Phoenix LiveView, Ash, and SQLite.

```sh
bin/monolith check        # format, compile, lint, security, tests, and assets
bin/monolith audit        # online dependency audit
bin/monolith mix test.ui  # browser checks; requires Chrome/Chromium
```

[Development](docs/DEVELOPMENT.md) · [Gmail](docs/GMAIL.md) ·
[Calendar](docs/CALENDAR.md) · [Design system](docs/MONOLITH_DESIGN_SYSTEM.md)
