defmodule Lovelace.OnboardingTest do
  use Lovelace.DataCase, async: false

  alias Lovelace.Integrations.Google.ClientCredentials
  alias Lovelace.{Mail, Onboarding, Workspaces}
  alias Lovelace.TestSupport.OnboardingKeychain

  @owner [actor: %{role: :local_owner}]

  setup do
    start_supervised!(OnboardingKeychain)
    previous = Application.fetch_env(:lovelace, :google_client_keychain)
    Application.put_env(:lovelace, :google_client_keychain, OnboardingKeychain)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:lovelace, :google_client_keychain, value)
        :error -> Application.delete_env(:lovelace, :google_client_keychain)
      end
    end)
  end

  test "existing installations without guide state retain Home as the unlock default" do
    assert {:ok, nil} = Onboarding.progress(@owner)
    assert Onboarding.entry_path() == "/"
    refute Onboarding.pending?()
    assert {:ok, nil} = Onboarding.progress(@owner)
  end

  test "explicit start is owner-only, idempotent, and resumes saved progress" do
    assert {:error, _} = Onboarding.start()
    assert {:error, _} = Onboarding.progress()
    assert {:ok, %{step: :workspace, workspace_id: nil}} = Onboarding.start(@owner)
    assert Workspaces.list_workspaces!(@owner) == []
    assert {:ok, nil} = Onboarding.workspace(@owner)
    assert Onboarding.pending?()
    assert Onboarding.entry_path() == "/onboarding/workspace"

    assert {:ok, %{step: :project, workspace_id: id}} =
             Onboarding.save_workspace("Research", @owner)

    assert {:ok, %{id: ^id, name: "Research"}} = Onboarding.workspace(@owner)
    assert {:ok, %{step: :authentication}} = Onboarding.continue(:project, @owner)
    assert {:ok, %{step: :authentication, workspace_id: ^id}} = Onboarding.start(@owner)
    assert Onboarding.entry_path() == "/onboarding/authentication"
    assert [%{id: ^id, name: "Research"}] = Workspaces.list_workspaces!(@owner)
    assert {:ok, %{step: :audience}} = Onboarding.continue(:authentication, @owner)
    assert {:ok, %{step: :client}} = Onboarding.continue(:audience, @owner)
    assert {:error, :save_credentials_first} = Onboarding.continue(:client, @owner)
    assert Onboarding.entry_path() == "/onboarding/client"
  end

  test "workspace is required before Google setup, skipping, and finishing" do
    assert {:ok, %{workspace_id: nil}} = Onboarding.start(@owner)

    for step <- Onboarding.steps() do
      assert {:error, :workspace_required} = Onboarding.continue(step, @owner)
    end

    for step <- [:project, :authentication, :audience, :client, :connect, :calendar] do
      assert {:error, :workspace_required} = Onboarding.skip(step, @owner)
    end

    assert {:error, :workspace_required} = Onboarding.finish(@owner)

    assert {:error, :workspace_required} =
             Onboarding.save_credentials("synthetic-client", "synthetic-secret", @owner)

    assert OnboardingKeychain.writes() == 0
    assert {:ok, %{step: :workspace, finished: false}} = Onboarding.progress(@owner)
    assert Workspaces.list_workspaces!(@owner) == []
  end

  test "workspace names are trimmed and invalid submissions never create a workspace" do
    for name <- [nil, "", " \t\n", String.duplicate("x", 65), String.duplicate("é", 65)] do
      assert {:error, _} = Onboarding.save_workspace(name, @owner)
      assert Workspaces.list_workspaces!(@owner) == []
      assert {:ok, nil} = Onboarding.progress(@owner)
    end

    assert {:ok, %{workspace_id: id}} = Onboarding.save_workspace("  Quiet room \n", @owner)
    assert {:ok, %{id: ^id, name: "Quiet room"}} = Onboarding.workspace(@owner)

    assert {:error, _} = Onboarding.save_workspace("   ", @owner)
    assert {:ok, %{id: ^id, name: "Quiet room"}} = Onboarding.workspace(@owner)
  end

  test "workspace creation and renaming remain owner-only" do
    for opts <- [[], [actor: %{}], [actor: %{role: :service}]] do
      assert {:error, _} = Onboarding.save_workspace("Denied", opts)
      assert {:error, _} = Onboarding.workspace(opts)
      assert Workspaces.list_workspaces!(@owner) == []
    end

    assert {:ok, %{workspace_id: id}} = Onboarding.save_workspace("Private", @owner)
    assert {:error, _} = Onboarding.save_workspace("Denied", actor: %{role: :service})
    assert {:ok, %{id: ^id, name: "Private"}} = Onboarding.workspace(@owner)
  end

  test "duplicate submissions and Back rename the same persisted workspace" do
    assert {:ok, %{workspace_id: id}} = Onboarding.save_workspace("Reading", @owner)
    assert {:ok, %{step: :authentication}} = Onboarding.continue(:project, @owner)
    assert {:ok, %{step: :authentication, workspace_id: ^id}} = Onboarding.start(@owner)

    for name <- ["Reading", "  Writing  ", "Writing"] do
      assert {:ok, %{step: :project, workspace_id: ^id}} =
               Onboarding.save_workspace(name, @owner)
    end

    assert [%{id: ^id, name: "Writing"}] = Workspaces.list_workspaces!(@owner)
  end

  test "simultaneous submissions converge on one guide workspace" do
    submissions =
      for _ <- 1..2 do
        Task.async(fn -> Onboarding.save_workspace("Shared draft", @owner) end)
      end

    ids =
      Enum.map(submissions, fn task ->
        assert {:ok, %{workspace_id: id}} = Task.await(task)
        id
      end)

    assert [id] = Enum.uniq(ids)
    assert [%{id: ^id, name: "Shared draft"}] = Workspaces.list_workspaces!(@owner)
    assert {:ok, %{workspace_id: ^id}} = Onboarding.progress(@owner)
  end

  test "workspace creation and guide association roll back together" do
    assert {:error, _} =
             Ash.transact([Onboarding.State, Lovelace.Workspaces.Workspace], fn ->
               assert {:ok, %{workspace_id: id}} =
                        Onboarding.save_workspace("Rolled back", @owner)

               assert {:ok, %{id: ^id}} = Onboarding.workspace(@owner)
               {:error, :intentional_rollback}
             end)

    assert Workspaces.list_workspaces!(@owner) == []
    assert {:ok, nil} = Onboarding.progress(@owner)

    assert {:ok, %{workspace_id: id}} = Onboarding.save_workspace("Kept", @owner)
    assert {:ok, %{step: :authentication}} = Onboarding.continue(:project, @owner)

    assert {:error, _} =
             Ash.transact([Onboarding.State, Lovelace.Workspaces.Workspace], fn ->
               assert {:ok, _} = Onboarding.save_workspace("Rolled back rename", @owner)
               {:error, :intentional_rollback}
             end)

    assert {:ok, %{workspace_id: ^id, step: :authentication}} = Onboarding.progress(@owner)
    assert {:ok, %{id: ^id, name: "Kept"}} = Onboarding.workspace(@owner)
  end

  test "credential action owns direct bounded keychain storage but never provider verification" do
    assert {:error, _} = Onboarding.save_credentials("synthetic-client", "synthetic-secret")
    assert OnboardingKeychain.writes() == 0
    assert {:ok, _} = Onboarding.save_workspace("Google setup", @owner)

    assert {:ok, true} =
             Onboarding.save_credentials("synthetic-client", "synthetic-secret", @owner)

    assert {:ok, %{client_id: "synthetic-client", client_secret: "synthetic-secret"}} =
             ClientCredentials.read()

    assert {:ok, %{step: :connect, credentials_saved: true}} = Onboarding.progress(@owner)
    assert {:ok, nil} = Onboarding.connection(@owner)
    assert OnboardingKeychain.calls() == []
    assert {:ok, %{step: :connect}} = Onboarding.continue(:client, @owner)
  end

  test "invalid credentials and private adapter failures never advance progress or echo values" do
    Onboarding.save_workspace("Google setup", @owner)

    for value <- ["", "synthetic secret", "synthetic\nsecret", String.duplicate("x", 8193)] do
      assert {:error, error} = Onboarding.save_credentials("synthetic-client", value, @owner)
      refute inspect(error) =~ "synthetic-client"
      refute inspect(error) =~ "synthetic secret"
      assert {:ok, %{step: :project, credentials_saved: false}} = Onboarding.progress(@owner)
    end

    OnboardingKeychain.fail("synthetic private native diagnostic")

    assert {:error, error} =
             Onboarding.save_credentials("synthetic-client", "synthetic-secret", @owner)

    refute inspect(error) =~ "synthetic private native diagnostic"
    assert {:ok, %{credentials_saved: false}} = Onboarding.progress(@owner)
  end

  test "every Google guide step can be skipped without credentials or premature completion" do
    assert {:ok, %{workspace_id: workspace_id}} = Onboarding.save_workspace("Quiet", @owner)

    for step <- [:project, :authentication, :audience, :client] do
      assert {:ok, %{step: :complete, finished: false, credentials_saved: false}} =
               Onboarding.skip(step, @owner)

      assert Onboarding.pending?()
      assert {:ok, %{workspace_id: ^workspace_id}} = Onboarding.progress(@owner)
      assert Mail.list_accounts!(@owner) == []
      assert OnboardingKeychain.writes() == 0
      assert OnboardingKeychain.calls() == []
    end

    assert {:error, _} = Onboarding.skip(:project)
    assert {:error, _} = Onboarding.skip(:client, actor: %{role: :service})
    assert {:ok, %{finished: true}} = Onboarding.finish(@owner)
    assert Onboarding.entry_path() == "/"
  end

  test "optional Gmail and Calendar skips persist resume steps without connecting providers" do
    assert {:ok, _} = Onboarding.save_workspace("Optional providers", @owner)
    assert {:ok, %{step: :calendar, finished: false}} = Onboarding.skip(:connect, @owner)
    assert {:ok, %{step: :calendar}} = Onboarding.start(@owner)
    assert Onboarding.entry_path() == "/onboarding/calendar"
    assert Onboarding.pending?()
    assert {:ok, nil} = Onboarding.connection(@owner)

    assert {:ok, %{step: :complete, finished: false}} = Onboarding.skip(:calendar, @owner)
    assert {:ok, %{step: :complete}} = Onboarding.start(@owner)
    assert Onboarding.entry_path() == "/onboarding/complete"
    assert Onboarding.pending?()
    assert {:ok, nil} = Onboarding.connection(@owner)
    assert OnboardingKeychain.calls() == []

    assert {:ok, %{finished: true}} = Onboarding.finish(@owner)
    refute Onboarding.pending?()
    assert Onboarding.entry_path() == "/"
    assert {:ok, %{step: :complete, finished: true}} = Onboarding.start(@owner)
    assert Onboarding.path(:project) == "/onboarding/project"
    assert Onboarding.path(:calendar) == "/onboarding/calendar"
    assert Onboarding.parse_step("calendar") == :calendar
    assert {:ok, nil} = Onboarding.connection(@owner)
  end

  test "Calendar continuation and finishing remain owner-only" do
    assert {:ok, _} = Onboarding.save_workspace("Owner workspace", @owner)
    assert {:ok, %{step: :calendar}} = Onboarding.continue(:connect, @owner)

    for opts <- [[], [actor: %{role: :service}]] do
      assert {:error, _} = Onboarding.continue(:calendar, opts)
      assert {:error, _} = Onboarding.finish(opts)
      assert {:ok, %{step: :calendar, finished: false}} = Onboarding.progress(@owner)
    end
  end

  test "connection evidence belongs to the receiving workspace and preserves first-read uncertainty" do
    assert {:ok, %{workspace_id: workspace_id}} = Onboarding.save_workspace("Chosen", @owner)

    assert {:ok, true} =
             Onboarding.save_credentials("synthetic-client", "synthetic-secret", @owner)

    other = Workspaces.create_workspace!("Other fixture workspace", @owner)

    account =
      Mail.save_connection!(
        %{
          subject: "synthetic-subject",
          email: "synthetic@example.invalid",
          generation: Ash.UUID.generate()
        },
        @owner
      )

    Mail.attach_account!(%{workspace_id: other.id, account_id: account.id}, @owner)
    assert {:ok, nil} = Onboarding.connection(@owner)

    Mail.attach_account!(
      %{workspace_id: workspace_id, account_id: account.id},
      @owner
    )

    assert {:ok,
            %{
              id: id,
              email: "synthetic@example.invalid",
              calendar_enabled: false,
              status: :ready,
              last_success_at: nil,
              inbox_unread_at: nil
            }} =
             Onboarding.connection(@owner)

    assert id == account.id
    assert {:ok, %{generation: generation}} = Onboarding.connection(@owner)
    assert generation == account.generation

    assert {:ok, %{step: :calendar}} = Onboarding.skip(:connect, @owner)
    assert {:ok, %{step: :complete}} = Onboarding.skip(:calendar, @owner)
    assert {:ok, %{id: ^id, calendar_enabled: false}} = Onboarding.connection(@owner)

    account =
      Mail.update_account!(
        account,
        %{expected_generation: account.generation, calendar_enabled: true},
        @owner
      )

    writes = OnboardingKeychain.writes()

    for step <- [:client, :connect, :calendar] do
      assert {:ok, %{credentials_saved: true, finished: false}} = Onboarding.skip(step, @owner)

      assert {:ok, %{id: ^id, generation: ^generation, calendar_enabled: true}} =
               Onboarding.connection(@owner)

      assert OnboardingKeychain.writes() == writes
    end

    assert {:ok, %{client_id: "synthetic-client", client_secret: "synthetic-secret"}} =
             ClientCredentials.read()

    assert {:ok, %{id: ^id, calendar_enabled: true}} = Onboarding.connection(@owner)

    Mail.update_account!(
      account,
      %{expected_generation: account.generation, status: :reconnect},
      @owner
    )

    assert {:ok, %{status: :reconnect}} = Onboarding.connection(@owner)

    Mail.update_account!(
      account,
      %{expected_generation: account.generation, status: :disconnected},
      @owner
    )

    assert {:ok, nil} = Onboarding.connection(@owner)
    assert OnboardingKeychain.calls() == []
  end
end
