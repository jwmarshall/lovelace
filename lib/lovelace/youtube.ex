defmodule Lovelace.YouTube do
  @moduledoc "Optional account-scoped, selected-subscription uploads; no recommendations or writes."
  use Ash.Domain

  resources do
    resource Lovelace.YouTube.State

    resource Lovelace.YouTube.Operation do
      define :snapshot, action: :snapshot, args: [:account_id]
      define :prepare, action: :prepare, args: [:account_id]
      define :refresh, action: :refresh, args: [:account_id]

      define :select_channels,
        action: :select_channels,
        args: [:account_id, :ids, :generation, :revision]

      define :poll, action: :poll, args: [:account_id, :generation, :revision]
      define :sweep, action: :sweep
    end
  end

  @doc "Internal lifecycle reset; caller must hold Google.Access.serial(account_id)."
  defdelegate clear(account_id), to: Lovelace.YouTube.Operations
end
