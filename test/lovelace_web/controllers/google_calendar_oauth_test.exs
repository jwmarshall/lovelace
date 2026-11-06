defmodule LovelaceWeb.GoogleCalendarOAuthTest do
  use LovelaceWeb.ConnCase
  alias Lovelace.Google.Access
  alias Lovelace.Mail.{DisconnectWorker, OAuth}
  alias Lovelace.TestSupport.OAuthJobs
  @owner %{role: :local_owner}
  @scopes [
    "https://www.googleapis.com/auth/gmail.readonly",
    "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
    "https://www.googleapis.com/auth/calendar.events.readonly"
  ]

  defmodule Provider do
    def authorization_url(params) do
      Lovelace.TestMail.record({:authorization, params})

      default =
        {:ok,
         "https://accounts.google.com/o/oauth2/v2/auth?" <>
           URI.encode_query(%{state: params.state})}

      Agent.get(Lovelace.TestMail, &Map.get(&1, :authorization_result, default))
    end

    def exchange_code(_, _, _) do
      Lovelace.TestMail.record(:exchange)

      case Lovelace.TestMail.result() do
        {:logout, session, tokens} ->
          Lovelace.Owner.logout!(session)
          {:ok, tokens}

        result ->
          result
      end
    end

    def revoke(_), do: :ok

    def identity(_) do
      Lovelace.TestMail.record(:identity)

      owner =
        Agent.get_and_update(Lovelace.TestMail, fn state ->
          {Map.get(state, :identity_race_owner), Map.delete(state, :identity_race_owner)}
        end)

      if owner do
        send(owner, {:identity_waiting, self()})

        receive do
          :continue -> :ok
        end
      end

      {:ok, %{subject: "calendar-sub", email: "calendar@example.invalid"}}
    end

    def refresh(token) do
      Lovelace.TestMail.record({:refresh, token})
      {:ok, %{access_token: "rotated-access", refresh_token: "rotated-refresh"}}
    end
  end

  defmodule PausingVault do
    def get(id) do
      snapshot = Lovelace.TestMailVault.get(id)

      owner =
        Agent.get_and_update(Lovelace.TestMail, fn state ->
          {Map.get(state, :calendar_race_owner), Map.delete(state, :calendar_race_owner)}
        end)

      if owner do
        send(owner, {:credential_read, self()})

        receive do
          :continue -> snapshot
        end
      else
        snapshot
      end
    end

    def put(id, token) do
      Lovelace.TestMail.record({:vault_put, id})
      Lovelace.TestMailVault.put(id, token)
    end

    defdelegate delete(id), to: Lovelace.TestMailVault
  end

  setup %{conn: conn} do
    {:ok, _} = Lovelace.TestMail.start()

    previous =
      for key <- [:gmail_provider, :gmail_vault],
          into: %{},
          do: {key, Application.get_env(:lovelace, key)}

    Application.put_env(:lovelace, :gmail_provider, Provider)
    Application.put_env(:lovelace, :gmail_vault, Lovelace.TestMailVault)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value,
          do: Application.put_env(:lovelace, key, value),
          else: Application.delete_env(:lovelace, key)
      end)
    end)

    conn = authenticate_owner(conn)

    {:ok, %{workspace_id: workspace_id}} =
      Lovelace.Onboarding.save_workspace("Calendar OAuth", actor: @owner)

    workspace = Lovelace.Workspaces.get_workspace!(workspace_id, actor: @owner)

    {:ok, account} =
      Access.accept(
        workspace.id,
        %{subject: "calendar-sub", email: "calendar@example.invalid"},
        "prior-refresh"
      )

    Lovelace.TestMail.response({:ok, tokens()})
    %{conn: conn, workspace: workspace, account: account}
  end

  test "Calendar start requires an existing account and valid receiving workspace", %{
    conn: conn,
    workspace: w,
    account: account
  } do
    for params <- [
          %{workspace_id: w.id, capability: "calendar"},
          %{workspace_id: w.id, capability: "calendar", expected_account_id: ""},
          %{workspace_id: w.id, capability: "calendar", expected_account_id: Ash.UUID.generate()},
          %{
            workspace_id: Ash.UUID.generate(),
            capability: "calendar",
            expected_account_id: account.id
          },
          %{workspace_id: w.id, capability: "unknown", expected_account_id: account.id}
        ] do
      response = post(conn, "/oauth/google/start", params)
      assert response.status == 302, "invalid intent was accepted: #{inspect(params)}"
      expected = if params.capability == "calendar", do: "calendar", else: "gmail"
      assert redirected_to(response) == "/connections/#{expected}"
    end

    refute Enum.any?(Lovelace.TestMail.calls(), &match?({:authorization, _}, &1))

    response =
      post(conn, "/oauth/google/start", %{
        workspace_id: w.id,
        capability: "calendar",
        expected_account_id: account.id
      })

    assert [%{capability: :calendar} = params] =
             for({:authorization, p} <- Lovelace.TestMail.calls(), do: p)

    assert {:ok, attempt} = OAuth.cancel(params.state, get_session(conn, :owner_session_token))
    assert attempt.capability == :calendar
    assert attempt.expected_account_id == account.id
    assert attempt.workspace_id == w.id
    assert attempt.expected_generation == account.generation
    assert URI.parse(redirected_to(response, 303)).host == "accounts.google.com"
  end

  test "default Gmail attempts remain Gmail; Calendar cannot start without expected account", %{
    conn: conn,
    workspace: w
  } do
    response = post(conn, "/oauth/google/start", %{workspace_id: w.id})
    assert redirected_to(response, 303) =~ "https://accounts.google.com/"
    assert [{:authorization, params} | _] = Lovelace.TestMail.calls()
    assert params.capability == :gmail
    assert {:ok, attempt} = OAuth.cancel(params.state, get_session(conn, :owner_session_token))
    assert attempt.capability == :gmail
    assert {:error, :invalid_request} = OAuth.begin(w.id, "session", nil, :calendar)
  end

  test "Calendar callback requires scope evidence, binds subject, and enables only existing connection",
       %{conn: conn, workspace: w, account: account} do
    response = callback(conn, w.id, account.id)
    assert redirected_to(response, 303) == "/connections/calendar?calendar=connected"
    assert {:ok, saved} = Lovelace.Mail.get_account(account.id, actor: @owner)
    assert saved.calendar_enabled
    assert {:ok, "new-refresh"} = Lovelace.TestMailVault.get(account.id)
    assert [only] = Lovelace.Mail.list_accounts!(actor: @owner)
    assert only.id == account.id
  end

  test "setup Calendar consent returns to the picker without advancing the guide", %{
    conn: conn,
    workspace: w,
    account: account
  } do
    assert {:ok, %{step: :calendar}} = Lovelace.Onboarding.continue(:connect, actor: @owner)

    response =
      post(conn, "/oauth/google/start", %{
        workspace_id: w.id,
        expected_account_id: account.id,
        capability: "calendar",
        origin: "onboarding"
      })

    assert URI.parse(redirected_to(response, 303)).host == "accounts.google.com"
    assert [{:authorization, params} | _] = Lovelace.TestMail.calls()
    assert params.capability == :calendar

    response = OAuthJobs.get(conn, callback_url(params.state))
    assert redirected_to(response, 303) == "/onboarding/calendar"

    assert {:ok, %{step: :calendar, finished: false}} =
             Lovelace.Onboarding.progress(actor: @owner)

    assert {:ok, saved} = Lovelace.Mail.get_account(account.id, actor: @owner)
    assert saved.calendar_enabled
    assert saved.subject == account.subject
    assert saved.status == account.status
    assert {:ok, "new-refresh"} = Lovelace.TestMailVault.get(account.id)
    assert [only] = Lovelace.Mail.list_accounts!(actor: @owner)
    assert only.id == account.id

    assert {:error, :invalid_state} =
             OAuth.cancel(params.state, get_session(conn, :owner_session_token))
  end

  test "setup Calendar callback cannot update a replacement guide workspace", %{
    conn: conn,
    workspace: workspace,
    account: account
  } do
    assert {:ok, %{step: :calendar}} = Lovelace.Onboarding.continue(:connect, actor: @owner)

    {:ok, state, _} =
      OAuth.begin(
        workspace.id,
        get_session(conn, :owner_session_token),
        account.id,
        :calendar,
        account.generation,
        :onboarding
      )

    replacement = Lovelace.Workspaces.create_workspace!("Replacement guide", actor: @owner)
    {:ok, progress} = Lovelace.Onboarding.progress(actor: @owner)

    Ash.update!(progress, %{workspace_id: replacement.id},
      action: :save_workspace,
      actor: @owner
    )

    response = OAuthJobs.get(conn, callback_url(state))
    assert redirected_to(response, 303) == "/onboarding/calendar?notice=calendar_failed"

    assert {:ok, %{step: :project, workspace_id: saved_workspace}} =
             Lovelace.Onboarding.progress(actor: @owner)

    assert saved_workspace == replacement.id
    refute :exchange in Lovelace.TestMail.calls()
    assert {:ok, saved} = Lovelace.Mail.get_account(account.id, actor: @owner)
    assert saved.generation == account.generation
    refute saved.calendar_enabled
    assert {:ok, "prior-refresh"} = Lovelace.TestMailVault.get(account.id)
  end

  test "setup Calendar denial and missing scopes keep Gmail intact and return to the guide", %{
    conn: conn,
    workspace: w,
    account: account
  } do
    assert {:ok, %{step: :calendar}} = Lovelace.Onboarding.continue(:connect, actor: @owner)
    session = get_session(conn, :owner_session_token)

    for result <- [:denied, :missing_scopes] do
      {:ok, state, _} =
        OAuth.begin(w.id, session, account.id, :calendar, account.generation, :onboarding)

      response =
        case result do
          :denied ->
            OAuthJobs.get(
              conn,
              "/oauth/google/callback?" <>
                URI.encode_query(%{
                  state: state,
                  error: "access_denied",
                  error_description: "private-provider-detail"
                })
            )

          :missing_scopes ->
            Lovelace.TestMail.response({:ok, Map.delete(tokens(), :scopes)})
            OAuthJobs.get(conn, callback_url(state))
        end

      assert redirected_to(response, 303) == "/onboarding/calendar?notice=calendar_failed"

      assert {:ok, %{step: :calendar, finished: false}} =
               Lovelace.Onboarding.progress(actor: @owner)

      assert {:ok, saved} = Lovelace.Mail.get_account(account.id, actor: @owner)
      assert saved.status == account.status
      assert saved.generation == account.generation
      refute saved.calendar_enabled
      assert {:ok, "prior-refresh"} = Lovelace.TestMailVault.get(account.id)
      assert {:error, :invalid_state} = OAuth.cancel(state, session)

      if result == :denied, do: refute(:exchange in Lovelace.TestMail.calls())
    end

    refute :identity in Lovelace.TestMail.calls()
    assert [only] = Lovelace.Mail.list_accounts!(actor: @owner)
    assert only.id == account.id
  end

  test "setup Calendar start failures use a fixed guide destination", %{
    conn: conn,
    workspace: w,
    account: account
  } do
    params = %{
      workspace_id: w.id,
      expected_account_id: account.id,
      capability: "calendar",
      origin: "onboarding",
      return_to: "https://untrusted.invalid/"
    }

    response = post(conn, "/oauth/google/start", Map.delete(params, :expected_account_id))
    assert redirected_to(response) == "/onboarding/calendar?notice=calendar_failed"
    refute Enum.any?(Lovelace.TestMail.calls(), &match?({:authorization, _}, &1))

    Agent.update(
      Lovelace.TestMail,
      &Map.put(&1, :authorization_result, {:error, "private-provider-detail"})
    )

    response = post(conn, "/oauth/google/start", params)
    assert redirected_to(response) == "/onboarding/calendar?notice=calendar_failed"
    assert {:ok, saved} = Lovelace.Mail.get_account(account.id, actor: @owner)
    refute saved.calendar_enabled
    assert {:ok, "prior-refresh"} = Lovelace.TestMailVault.get(account.id)
  end

  test "Calendar origin belongs to each attempt, never callback params or another attempt", %{
    conn: conn,
    workspace: w,
    account: account
  } do
    session = get_session(conn, :owner_session_token)
    assert {:ok, %{step: :calendar}} = Lovelace.Onboarding.continue(:connect, actor: @owner)

    {:ok, setup_state, _} =
      OAuth.begin(w.id, session, account.id, :calendar, account.generation, :onboarding)

    {:ok, normal_state, _} =
      OAuth.begin(w.id, session, account.id, :calendar, account.generation)

    response =
      OAuthJobs.get(
        conn,
        callback_url(normal_state) <> "&origin=onboarding&return_to=/onboarding/complete"
      )

    assert redirected_to(response, 303) == "/connections/calendar?calendar=connected"
    assert {:ok, %{step: :calendar}} = Lovelace.Onboarding.progress(actor: @owner)

    response =
      OAuthJobs.get(
        conn,
        "/oauth/google/callback?" <>
          URI.encode_query(%{state: setup_state, error: "access_denied", origin: "connections"})
      )

    assert redirected_to(response, 303) == "/onboarding/calendar?notice=calendar_failed"
    assert {:ok, %{step: :calendar}} = Lovelace.Onboarding.progress(actor: @owner)
  end

  test "invalid or mismatched setup Calendar state cannot trust callback origin", %{
    conn: conn,
    workspace: w,
    account: account
  } do
    {:ok, state, _} =
      OAuth.begin(w.id, "another-session", account.id, :calendar, account.generation, :onboarding)

    for attempt_state <- [state, "unknown-state"] do
      response =
        OAuthJobs.get(
          conn,
          callback_url(attempt_state) <>
            "&origin=onboarding&capability=calendar&return_to=/onboarding/complete"
        )

      assert_failure(response, "state", "invalid_state")
    end

    assert {:error, :invalid_state} = OAuth.cancel(state, get_session(conn, :owner_session_token))
    refute :exchange in Lovelace.TestMail.calls()
    assert {:ok, saved} = Lovelace.Mail.get_account(account.id, actor: @owner)
    refute saved.calendar_enabled
  end

  test "setup Calendar consent cannot survive a Gmail reconnect", %{
    conn: conn,
    workspace: w,
    account: account
  } do
    assert {:ok, %{step: :calendar}} = Lovelace.Onboarding.continue(:connect, actor: @owner)

    {:ok, state, _} =
      OAuth.begin(
        w.id,
        get_session(conn, :owner_session_token),
        account.id,
        :calendar,
        account.generation,
        :onboarding
      )

    {:ok, current} =
      Access.accept(
        w.id,
        %{subject: account.subject, email: account.email},
        "reconnected-refresh"
      )

    response = OAuthJobs.get(conn, callback_url(state))
    assert redirected_to(response, 303) == "/onboarding/calendar?notice=calendar_failed"
    assert {:ok, %{step: :calendar}} = Lovelace.Onboarding.progress(actor: @owner)
    assert {:ok, saved} = Lovelace.Mail.get_account(account.id, actor: @owner)
    assert saved.generation == current.generation
    refute saved.calendar_enabled
    assert {:ok, "reconnected-refresh"} = Lovelace.TestMailVault.get(account.id)
  end

  test "setup Calendar rechecks the owner session before consent is saved", %{
    conn: conn,
    workspace: w,
    account: account
  } do
    assert {:ok, %{step: :calendar}} = Lovelace.Onboarding.continue(:connect, actor: @owner)
    session = get_session(conn, :owner_session_token)
    Lovelace.TestMail.response({:logout, session, tokens()})

    {:ok, state, _} =
      OAuth.begin(w.id, session, account.id, :calendar, account.generation, :onboarding)

    response = OAuthJobs.get(conn, callback_url(state))
    assert redirected_to(response, 303) == "/onboarding/calendar?notice=calendar_failed"
    assert {:ok, %{step: :calendar}} = Lovelace.Onboarding.progress(actor: @owner)
    assert {:ok, saved} = Lovelace.Mail.get_account(account.id, actor: @owner)
    assert saved.generation == account.generation
    refute saved.calendar_enabled
    assert {:ok, "prior-refresh"} = Lovelace.TestMailVault.get(account.id)
  end

  test "missing or partial returned scopes fail before identity, vault writes or persistence", %{
    conn: conn,
    workspace: w,
    account: account
  } do
    for scopes <- [nil, [], tl(@scopes), List.delete_at(@scopes, 1), List.delete_at(@scopes, 2)] do
      token =
        if is_nil(scopes), do: Map.delete(tokens(), :scopes), else: %{tokens() | scopes: scopes}

      Lovelace.TestMail.response({:ok, token})
      response = callback(conn, w.id, account.id)
      assert_failure(response, "consent", "forbidden")
      assert {:ok, "prior-refresh"} = Lovelace.TestMailVault.get(account.id)
      assert {:ok, unchanged} = Lovelace.Mail.get_account(account.id, actor: @owner)
      assert unchanged.generation == account.generation
      refute unchanged.calendar_enabled
    end

    refute :identity in Lovelace.TestMail.calls()
  end

  test "Calendar callback cannot select a different Google identity", %{conn: conn, workspace: w} do
    {:ok, other} =
      Access.accept(
        w.id,
        %{subject: "other-sub", email: "other@example.invalid"},
        "other-refresh"
      )

    response = callback(conn, w.id, other.id)
    assert_failure(response, "account_binding", "wrong_account")
    assert {:ok, "other-refresh"} = Lovelace.TestMailVault.get(other.id)
  end

  test "Calendar callback rechecks owner session after exchange before persisting", %{
    conn: conn,
    workspace: w,
    account: account
  } do
    Lovelace.TestMail.response({:logout, get_session(conn, :owner_session_token), tokens()})
    response = callback(conn, w.id, account.id)
    assert_failure(response, "session", "unavailable")
    assert {:ok, "prior-refresh"} = Lovelace.TestMailVault.get(account.id)
  end

  test "Calendar attempt is session bound and one use", %{
    conn: conn,
    workspace: w,
    account: account
  } do
    session = get_session(conn, :owner_session_token)

    {:ok, state, _} =
      OAuth.begin(w.id, "different-session", account.id, :calendar, account.generation)

    response = OAuthJobs.get(conn, callback_url(state))
    assert_failure(response, "state", "invalid_state")
    assert {:error, :invalid_state} = OAuth.cancel(state, session)
    refute :exchange in Lovelace.TestMail.calls()
  end

  test "Gmail reconnect disables Calendar locally even if returned token still includes Calendar scopes",
       %{conn: conn, workspace: w, account: account} do
    {:ok, current} =
      Access.accept(
        w.id,
        %{subject: account.subject, email: account.email},
        "prior-refresh",
        :calendar
      )

    {:ok, state, _} =
      OAuth.begin(
        w.id,
        get_session(conn, :owner_session_token),
        current.id,
        :gmail,
        current.generation
      )

    response = OAuthJobs.get(conn, callback_url(state))
    assert redirected_to(response, 303) == "/workspaces/#{w.id}?gmail=connected"
    assert {:ok, saved} = Lovelace.Mail.get_account(account.id, actor: @owner)
    refute saved.calendar_enabled
  end

  test "delayed Calendar consent cannot survive Gmail reconnect", %{
    conn: conn,
    workspace: w,
    account: account
  } do
    {:ok, state, _} =
      OAuth.begin(
        w.id,
        get_session(conn, :owner_session_token),
        account.id,
        :calendar,
        account.generation
      )

    {:ok, current} =
      Access.accept(
        w.id,
        %{subject: account.subject, email: account.email},
        "reconnected-refresh"
      )

    response = OAuthJobs.get(conn, callback_url(state))
    assert_failure(response, "account_binding", "wrong_account")
    assert {:ok, "reconnected-refresh"} = Lovelace.TestMailVault.get(account.id)
    assert Lovelace.Mail.get_account!(account.id, actor: @owner).generation == current.generation
  end

  test "delayed Calendar consent cannot resurrect a disconnected connection", %{
    conn: conn,
    workspace: w,
    account: account
  } do
    {:ok, state, _} =
      OAuth.begin(
        w.id,
        get_session(conn, :owner_session_token),
        account.id,
        :calendar,
        account.generation
      )

    assert {:ok, operation} = Lovelace.Mail.disconnect(account.id, actor: @owner)
    response = OAuthJobs.get(conn, callback_url(state))
    assert_failure(response, "account_binding", "wrong_account")

    assert :ok =
             DisconnectWorker.perform(%Oban.Job{
               args: %{"operation_id" => operation.operation_id}
             })

    assert {:error, :not_found} = Lovelace.TestMailVault.get(account.id)
    assert Lovelace.Mail.get_account!(account.id, actor: @owner).status == :disconnected

    response =
      post(conn, "/oauth/google/start", %{
        workspace_id: w.id,
        expected_account_id: account.id,
        capability: "calendar"
      })

    assert redirected_to(response) == "/connections/calendar"
    refute Enum.any?(Lovelace.TestMail.calls(), &match?({:authorization, _}, &1))
  end

  test "authoritative accept lock prevents reconnect from interleaving with credential reuse", %{
    conn: conn,
    workspace: w,
    account: account
  } do
    Lovelace.TestMail.response({:ok, Map.delete(tokens(), :refresh_token)})
    owner = self()
    Agent.update(Lovelace.TestMail, &Map.put(&1, :calendar_race_owner, owner))
    Application.put_env(:lovelace, :gmail_vault, PausingVault)
    task = Task.async(fn -> callback(conn, w.id, account.id) end)
    assert_receive {:credential_read, worker}

    reconnect =
      Task.async(fn ->
        send(owner, :reconnect_started)

        Access.accept(
          w.id,
          %{subject: account.subject, email: account.email},
          "race-refresh"
        )
      end)

    assert_receive :reconnect_started
    assert Task.yield(reconnect, 100) == nil
    send(worker, :continue)
    assert redirected_to(Task.await(task), 303) == "/connections/calendar?calendar=connected"
    assert {:ok, current} = Task.await(reconnect)
    assert current.generation != account.generation
    refute current.calendar_enabled
    assert {:ok, "race-refresh"} = Lovelace.TestMailVault.get(account.id)
    assert Lovelace.Mail.get_account!(account.id, actor: @owner).generation == current.generation
  end

  test "missing refresh token reuses a same-generation rotation without rewriting the vault", %{
    conn: conn,
    workspace: w,
    account: account
  } do
    Lovelace.TestMail.response({:ok, Map.delete(tokens(), :refresh_token)})
    owner = self()
    Agent.update(Lovelace.TestMail, &Map.put(&1, :identity_race_owner, owner))
    Application.put_env(:lovelace, :gmail_vault, PausingVault)
    task = Task.async(fn -> callback(conn, w.id, account.id) end)
    assert_receive {:identity_waiting, worker}

    assert {:ok, "rotated-access"} = Access.access_token(account)
    assert Lovelace.Mail.get_account!(account.id, actor: @owner).generation == account.generation
    assert {:ok, "rotated-refresh"} = Lovelace.TestMailVault.get(account.id)
    send(worker, :continue)
    assert redirected_to(Task.await(task), 303) == "/connections/calendar?calendar=connected"
    assert {:ok, "rotated-refresh"} = Lovelace.TestMailVault.get(account.id)

    assert [{:vault_put, id}] =
             Enum.filter(Lovelace.TestMail.calls(), &match?({:vault_put, _}, &1))

    assert id == account.id
    assert Lovelace.Mail.get_account!(account.id, actor: @owner).calendar_enabled
  end

  test "missing refresh token fails reuse when the locked vault read finds no credential", %{
    conn: conn,
    workspace: w,
    account: account
  } do
    Lovelace.TestMail.response({:ok, Map.delete(tokens(), :refresh_token)})
    Lovelace.TestMailVault.delete(account.id)
    Application.put_env(:lovelace, :gmail_vault, PausingVault)
    assert_failure(callback(conn, w.id, account.id), "connection", "reconnect")
    assert {:error, :not_found} = Lovelace.TestMailVault.get(account.id)
    refute Enum.any?(Lovelace.TestMail.calls(), &match?({:vault_put, _}, &1))
    assert Lovelace.Mail.get_account!(account.id, actor: @owner).generation == account.generation
  end

  defp tokens,
    do: %{access_token: "synthetic-access", refresh_token: "new-refresh", scopes: @scopes}

  defp callback(conn, workspace, account) do
    current = Lovelace.Mail.get_account!(account, actor: @owner)

    {:ok, state, _} =
      OAuth.begin(
        workspace,
        get_session(conn, :owner_session_token),
        account,
        :calendar,
        current.generation
      )

    OAuthJobs.get(conn, callback_url(state))
  end

  defp callback_url(state),
    do: "/oauth/google/callback?" <> URI.encode_query(%{code: "synthetic-code", state: state})

  defp assert_failure(conn, stage, reason) do
    uri = URI.parse(redirected_to(conn, 303))
    assert uri.path == "/connections/gmail"

    assert URI.decode_query(uri.query) == %{
             "gmail" => "failed",
             "stage" => stage,
             "reason" => reason
           }
  end
end
