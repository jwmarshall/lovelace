# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# These enable behaviors that will become the default in the next major
# version of Ash. Setting them now opts your application into the new
# behavior and ensures a seamless upgrade. See the backwards compatibility
# guide for an explanation of each setting:
# https://hexdocs.pm/ash/backwards-compatibility-config.html
config :ash,
  allow_forbidden_field_for_relationships_by_default: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true,
  default_string_length_count: :codepoints,
  infer_generic_action_reactors?: false,
  many_to_many_destroy_destination_on_match?: true

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [section_order: [:resources, :policies, :authorization, :domain, :execution]]
  ]

config :lovelace,
  ash_domains: [
    Lovelace.StageDesigner,
    Lovelace.Workspaces,
    Lovelace.Mail,
    Lovelace.Calendar,
    Lovelace.YouTube,
    Lovelace.GitHub,
    Lovelace.Google,
    Lovelace.Onboarding,
    Lovelace.Home,
    Lovelace.OAuth,
    Lovelace.ConnectionDiagnostics,
    Lovelace.Owner
  ],
  ecto_repos: [Lovelace.Repo],
  generators: [timestamp_type: :utc_datetime]

# Serialize SQLite writes. Never hold a transaction across a provider HTTP request.
config :lovelace, Lovelace.Repo,
  pool_size: 1,
  timeout: 15_000,
  busy_timeout: 16_000

# Configure the endpoint
config :lovelace, LovelaceWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: LovelaceWeb.ErrorHTML, json: LovelaceWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Lovelace.PubSub,
  live_view: [signing_salt: "U9kM1spw"]

config :lovelace, :scene_confirmation, {LovelaceWeb.SceneConfirmation, []}
config :lovelace, :paid_render_provider, Lovelace.Integrations.Gemini.Interactions

# Lite is Oban's bundled SQLite engine. Only identifiers enter durable job arguments.
config :lovelace, Oban,
  repo: Lovelace.Repo,
  engine: Oban.Engines.Lite,
  queues: [gmail: 1, calendar: 1, youtube: 1, gemini: 1, github: 1, oauth: 1, diagnostics: 1],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", Lovelace.Mail.SweepWorker},
       {"* * * * *", Lovelace.Calendar.SweepWorker},
       {"* * * * *", Lovelace.YouTube.SweepWorker},
       {"* * * * *", Lovelace.GitHub.SweepWorker},
       {"* * * * *", Lovelace.StageDesigner.RecoveryWorker}
     ]},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(5)},
    {Oban.Plugins.Pruner, max_age: 86_400}
  ]

config :phoenix, :filter_parameters, [
  "password",
  "token",
  "secret",
  "code",
  "state",
  "verifier",
  "query",
  "q",
  "page_token",
  "refresh_token",
  "access_token",
  "api_key",
  "calendar_id",
  "channel_id",
  "channel_ids"
]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  lovelace: [
    args:
      ~w(js/app.js js/theme_boot.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  lovelace: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

import_config "sqlcipher.exs"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
