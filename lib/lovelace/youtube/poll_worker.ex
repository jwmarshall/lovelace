defmodule Lovelace.YouTube.PollWorker do
  @moduledoc "Durable ID-only, account/generation/selection-fenced YouTube reads."
  use Oban.Worker,
    queue: :youtube,
    max_attempts: 1,
    unique: [
      period: 900,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl true
  def timeout(_job), do: 120_000

  @impl true
  def perform(%Oban.Job{
        args: %{"account_id" => id, "generation" => generation, "revision" => revision}
      }) do
    case Lovelace.YouTube.poll(id, generation, revision,
           actor: %{role: :mail_service, account_id: id}
         ) do
      {:ok, _} -> :ok
      _ -> {:error, :youtube_unavailable}
    end
  end
end
