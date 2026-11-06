defmodule Lovelace.Repo.Migrations.AddYouTubeStates do
  @moduledoc "Adds bounded account-scoped read-only YouTube snapshots."
  use Ecto.Migration

  def up do
    create table(:youtube_states, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :generation, :uuid, null: false
      add :revision, :uuid, null: false
      add :channels, {:array, :map}, default: []
      add :selected_ids, {:array, :text}, default: []
      add :videos, {:array, :map}, default: []
      add :catalog_at, :utc_datetime_usec
      add :fetched_at, :utc_datetime_usec
      add :error, :text
      add :next_poll_at, :utc_datetime_usec, null: false
      add :cooldown_until, :utc_datetime_usec
      add :loading, :boolean, null: false
      add :truncated, :boolean, null: false
      add :catalog_truncated, :boolean, null: false
      add :job_id, :bigint
      add :requested_at, :utc_datetime_usec

      add :account_id,
          references(:gmail_accounts,
            column: :id,
            name: "youtube_states_account_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false
    end

    create unique_index(:youtube_states, [:account_id],
             name: "youtube_states_account_state_index"
           )
  end

  def down do
    drop table(:youtube_states)
  end
end
