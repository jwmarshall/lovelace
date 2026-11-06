defmodule Lovelace.YouTube.Operation do
  @moduledoc "Owner-authorized local snapshots and durable bounded reads."
  use Ash.Resource, domain: Lovelace.YouTube, authorizers: [Ash.Policy.Authorizer]

  actions do
    action :snapshot, :map do
      argument :account_id, :uuid, allow_nil?: false
      run Lovelace.YouTube.Operations
    end

    action :prepare, :map do
      argument :account_id, :uuid, allow_nil?: false
      run Lovelace.YouTube.Operations
    end

    action :refresh, :map do
      argument :account_id, :uuid, allow_nil?: false
      run Lovelace.YouTube.Operations
    end

    action :select_channels, :map do
      argument :account_id, :uuid, allow_nil?: false

      argument :ids, {:array, :string},
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 10, items: [max_length: 24]]

      argument :generation, :uuid, allow_nil?: false
      argument :revision, :uuid, allow_nil?: false
      run Lovelace.YouTube.Operations
    end

    action :poll, :map do
      argument :account_id, :uuid, allow_nil?: false
      argument :generation, :uuid, allow_nil?: false
      argument :revision, :uuid, allow_nil?: false
      run Lovelace.YouTube.Operations
    end

    action :sweep, :map do
      run Lovelace.YouTube.Operations
    end
  end

  policies do
    policy action([:snapshot, :prepare, :refresh, :select_channels, :sweep]) do
      access_type :strict
      authorize_if Lovelace.Workspaces.LocalOwner
    end

    policy action(:poll) do
      access_type :strict
      authorize_if Lovelace.Workspaces.LocalOwner
      authorize_if actor_attribute_equals(:role, :mail_service)
    end
  end
end
