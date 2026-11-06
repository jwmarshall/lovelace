defmodule Lovelace.Repo.Migrations.AddYouTubeExecutionClaim do
  @moduledoc "Separates durable YouTube queue age from the bounded execution lease."
  use Ecto.Migration

  def change do
    alter table(:youtube_states) do
      add :started_at, :utc_datetime_usec
    end
  end
end
