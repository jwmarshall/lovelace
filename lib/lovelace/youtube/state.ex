defmodule Lovelace.YouTube.State do
  @moduledoc "One bounded protected subscription catalog and uploads snapshot per Google account."
  use Ash.Resource,
    domain: Lovelace.YouTube,
    primary_read_warning?: false,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    repo Lovelace.Repo
    table "youtube_states"

    references do
      reference :account, on_delete: :delete
    end
  end

  actions do
    read :read do
      primary? true
      argument :account_id, :uuid, allow_nil?: false
      filter expr(account_id == ^arg(:account_id))
    end

    read :due do
      filter expr(
               (next_poll_at <= now() or loading == true) and account.status == :ready and
                 account.youtube_enabled == true and account.generation == generation
             )

      prepare build(sort: [next_poll_at: :asc], limit: 100)
    end

    read :expired do
      filter expr(fetched_at <= ago(24, :hour) or catalog_at <= ago(24, :hour))
      prepare build(limit: 100)
    end

    create :store do
      accept [
        :account_id,
        :generation,
        :revision,
        :channels,
        :selected_ids,
        :videos,
        :catalog_at,
        :fetched_at,
        :error,
        :next_poll_at,
        :cooldown_until,
        :loading,
        :truncated,
        :catalog_truncated,
        :job_id,
        :requested_at,
        :started_at
      ]

      upsert? true
      upsert_identity :account_state

      upsert_fields [
        :generation,
        :revision,
        :channels,
        :selected_ids,
        :videos,
        :catalog_at,
        :fetched_at,
        :error,
        :next_poll_at,
        :cooldown_until,
        :loading,
        :truncated,
        :catalog_truncated,
        :job_id,
        :requested_at,
        :started_at
      ]
    end

    destroy :clear
  end

  policies do
    policy always() do
      access_type :strict
      authorize_if Lovelace.Workspaces.LocalOwner
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :generation, :uuid, allow_nil?: false
    attribute :revision, :uuid, allow_nil?: false
    attribute :channels, {:array, :map}, default: [], sensitive?: true
    attribute :selected_ids, {:array, :string}, default: [], sensitive?: true
    attribute :videos, {:array, :map}, default: [], sensitive?: true
    attribute :catalog_at, :utc_datetime_usec
    attribute :fetched_at, :utc_datetime_usec

    attribute :error, :atom,
      constraints: [one_of: [:unavailable, :provider, :rate_limited, :reconnect, :keychain]]

    attribute :next_poll_at, :utc_datetime_usec, allow_nil?: false
    attribute :cooldown_until, :utc_datetime_usec
    attribute :loading, :boolean, default: false, allow_nil?: false
    attribute :truncated, :boolean, default: false, allow_nil?: false
    attribute :catalog_truncated, :boolean, default: false, allow_nil?: false
    attribute :job_id, :integer
    attribute :requested_at, :utc_datetime_usec
    attribute :started_at, :utc_datetime_usec
  end

  relationships do
    belongs_to :account, Lovelace.Mail.Account, allow_nil?: false
  end

  identities do
    identity :account_state, [:account_id]
  end
end
