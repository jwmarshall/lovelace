defmodule Lovelace.Mail.Account do
  @moduledoc "A Google identity, never a LOVELACE owner. Credentials live in Keychain."
  use Ash.Resource,
    domain: Lovelace.Mail,
    primary_read_warning?: false,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    repo Lovelace.Repo
    table "gmail_accounts"
    migration_defaults youtube_enabled: "false"
  end

  actions do
    read :read do
      primary? true
      prepare build(sort: [email: :asc])
    end

    read :scoped do
      argument :account_id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:account_id))
    end

    create :connect do
      accept [:id, :subject, :email, :generation, :calendar_enabled, :youtube_enabled]
      upsert? true
      upsert_identity :google_subject

      upsert_fields [
        :email,
        :generation,
        :calendar_enabled,
        :youtube_enabled,
        :status,
        :last_error,
        :next_poll_at,
        :inbox_unread_count,
        :inbox_unread_recent_count,
        :inbox_unread_at,
        :inbox_unread_error
      ]

      change set_attribute(:status, :ready)
      change set_attribute(:last_error, nil)
      change set_attribute(:inbox_unread_count, nil)
      change set_attribute(:inbox_unread_recent_count, nil)
      change set_attribute(:inbox_unread_at, nil)
      change set_attribute(:inbox_unread_error, nil)
      change set_attribute(:next_poll_at, &DateTime.utc_now/0)
    end

    update :status do
      argument :expected_generation, :uuid, allow_nil?: false

      accept [
        :status,
        :last_error,
        :last_success_at,
        :next_poll_at,
        :generation,
        :calendar_enabled,
        :youtube_enabled,
        :inbox_unread_count,
        :inbox_unread_recent_count,
        :inbox_unread_at,
        :inbox_unread_error
      ]

      change filter(expr(generation == ^arg(:expected_generation)))
    end
  end

  policies do
    # A subject-based upsert may target a different row than the supplied UUID.
    # Only the owner connection boundary may create/upsert identities; account-
    # scoped services are limited to reads and generation-filtered status updates.
    policy action(:connect) do
      access_type :strict
      authorize_if Lovelace.Workspaces.LocalOwner
    end

    policy action([:read, :scoped, :status]) do
      access_type :strict
      authorize_if Lovelace.Mail.Scope
    end
  end

  attributes do
    uuid_primary_key :id, writable?: true
    attribute :subject, :string, allow_nil?: false, sensitive?: true
    attribute :email, :string, allow_nil?: false, sensitive?: true
    attribute :generation, :uuid, allow_nil?: false
    attribute :calendar_enabled, :boolean, allow_nil?: false, default: false
    attribute :youtube_enabled, :boolean, allow_nil?: false, default: false

    attribute :status, :atom do
      allow_nil? false
      constraints one_of: [:ready, :reconnect, :disconnected]
      default :ready
    end

    attribute :last_error, :atom do
      constraints one_of: [:unavailable, :rate_limited, :reconnect, :keychain, :provider]
    end

    attribute :inbox_unread_count, :integer, constraints: [min: 0]
    attribute :inbox_unread_recent_count, :integer, constraints: [min: 0]
    attribute :inbox_unread_at, :utc_datetime_usec

    attribute :inbox_unread_error, :atom do
      constraints one_of: [:unavailable, :rate_limited, :reconnect, :keychain, :provider]
    end

    attribute :last_success_at, :utc_datetime_usec
    attribute :next_poll_at, :utc_datetime_usec, default: &DateTime.utc_now/0
    create_timestamp :created_at
    update_timestamp :updated_at
  end

  identities do
    identity :google_subject, [:subject]
  end
end
