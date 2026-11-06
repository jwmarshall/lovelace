defmodule Lovelace.Repo.Migrations.AddYoutubeConsent do
  use Ecto.Migration

  def up do
    alter table(:gmail_accounts) do
      add :youtube_enabled, :boolean, null: false, default: false
    end
  end

  def down do
    alter table(:gmail_accounts) do
      remove :youtube_enabled
    end
  end
end
