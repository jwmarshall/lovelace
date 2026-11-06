defmodule Lovelace.YouTube.SweepWorker do
  @moduledoc "Minute sweep of at most 100 expired and 100 eligible due snapshots, bounded to 30 seconds."
  use Oban.Worker,
    queue: :youtube,
    max_attempts: 1,
    unique: [period: 60, states: [:available, :scheduled, :executing, :retryable]]

  @impl true
  def timeout(_job), do: 30_000

  @impl true
  def perform(%Oban.Job{}) do
    case Lovelace.YouTube.sweep(actor: %{role: :local_owner}) do
      {:ok, _} -> :ok
      _ -> {:error, :youtube_unavailable}
    end
  end
end
