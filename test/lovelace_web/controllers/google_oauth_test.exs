defmodule LovelaceWeb.GoogleOAuthTest do
  use LovelaceWeb.ConnCase
  alias Lovelace.Google.Access
  alias Lovelace.Mail.OAuth
  alias Lovelace.TestSupport.OAuthJobs
  @owner %{role: :local_owner}

  setup %{conn: conn} do
    {:ok, _} = Lovelace.TestMail.start()

    previous =
      for key <- [:gmail_provider, :gmail_vault],
          into: %{},
          do: {key, Application.get_env(:lovelace, key)}

    Application.put_env(:lovelace, :gmail_provider, Lovelace.TestGoogle)
    Application.put_env(:lovelace, :gmail_vault, Lovelace.TestMailVault)

    on_exit(fn ->
      Enum.each(previous, fn {k, v} ->
        if v, do: Application.put_env(:lovelace, k, v), else: Application.delete_env(:lovelace, k)
      end)
    end)

    conn = authenticate_owner(conn)
    workspace = Lovelace.Workspaces.create_workspace!("OAuth fixture", actor: @owner)
    %{conn: conn, workspace: workspace}
  end

  test "state is one-use, owner-session bound and expires", %{workspace: w} do
    assert {:ok, state, verifier} = OAuth.begin(w.id, "first")
    assert byte_size(verifier) == 43
    assert {:error, :invalid_state} = OAuth.cancel(state, "second")
    assert {:error, :invalid_state} = OAuth.cancel(state, "first")
    {:ok, state, _} = OAuth.begin(w.id, "first")

    :sys.replace_state(OAuth, fn attempts ->
      Map.new(attempts, fn {k, a} ->
        {k, %{a | expires: System.monotonic_time(:millisecond) - 1}}
      end)
    end)

    assert {:error, :invalid_state} = OAuth.cancel(state, "first")
  end

  test "connection start requires an unlocked session", %{workspace: w} do
    conn =
      post(build_conn(:get, "http://localhost/"), "/oauth/google/start", %{workspace_id: w.id})

    assert redirected_to(conn) == "/unlock"
  end

  test "setup Gmail start failures return to the fixed connection step", %{conn: conn} do
    response =
      post(conn, "/oauth/google/start", %{
        workspace_id: Ash.UUID.generate(),
        origin: "onboarding",
        return_to: "https://untrusted.invalid/"
      })

    assert redirected_to(response) == "/onboarding/connect?notice=connection_failed"
    assert Lovelace.Mail.list_accounts!(actor: @owner) == []
  end

  test "setup Gmail cancellation trusts only the validated one-use attempt", %{
    conn: conn,
    workspace: w
  } do
    session = get_session(conn, :owner_session_token)
    {:ok, setup_state, _} = OAuth.begin(w.id, session, nil, :gmail, nil, :onboarding)
    {:ok, normal_state, _} = OAuth.begin(w.id, session)

    response =
      OAuthJobs.get(
        conn,
        "/oauth/google/callback?" <>
          URI.encode_query(%{
            state: setup_state,
            error: "access_denied",
            error_description: "private-provider-detail",
            origin: "connections",
            return_to: "https://untrusted.invalid/"
          })
      )

    assert redirected_to(response, 303) == "/onboarding/connect?notice=connection_failed"
    assert {:error, :invalid_state} = OAuth.cancel(setup_state, session)

    response =
      OAuthJobs.get(
        conn,
        "/oauth/google/callback?" <>
          URI.encode_query(%{state: normal_state, error: "access_denied", origin: "onboarding"})
      )

    assert_failure(response, "consent", "denied")

    response =
      OAuthJobs.get(
        conn,
        "/oauth/google/callback?" <>
          URI.encode_query(%{
            state: setup_state,
            code: "fake-code",
            origin: "onboarding",
            return_to: "/onboarding/complete"
          })
      )

    assert_failure(response, "state", "invalid_state")
    assert Lovelace.Mail.list_accounts!(actor: @owner) == []
    assert {:ok, nil} = Lovelace.Onboarding.progress(actor: @owner)
  end

  test "setup Gmail consent returns to Calendar in the saved workspace", %{conn: conn} do
    assert {:ok, %{workspace_id: workspace_id}} =
             Lovelace.Onboarding.save_workspace("My first workspace", actor: @owner)

    {:ok, state, _} =
      OAuth.begin(
        workspace_id,
        get_session(conn, :owner_session_token),
        nil,
        :gmail,
        nil,
        :onboarding
      )

    response =
      OAuthJobs.get(
        conn,
        "/oauth/google/callback?" <> URI.encode_query(%{code: "fake-code", state: state})
      )

    assert redirected_to(response, 303) == "/onboarding/calendar"

    assert {:ok, %{step: :calendar, workspace_id: ^workspace_id, finished: false}} =
             Lovelace.Onboarding.progress(actor: @owner)

    assert [%{subject: "new-subject"} = account] = Lovelace.Mail.list_accounts!(actor: @owner)
    assert [%{account_id: id}] = Lovelace.Mail.workspace_accounts!(workspace_id, actor: @owner)
    assert id == account.id
    refute account.calendar_enabled
    refute account.youtube_enabled
  end

  test "callback binds Google subject and leaks no code into Phoenix telemetry", %{
    conn: conn,
    workspace: w
  } do
    session = get_session(conn, :owner_session_token)
    {:ok, state, _} = OAuth.begin(w.id, session)
    pid = self()
    handler = "oauth-privacy-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [
        [:phoenix, :endpoint, :start],
        [:phoenix, :endpoint, :stop],
        [:phoenix, :router_dispatch, :start],
        [:phoenix, :router_dispatch, :stop]
      ],
      fn event, _, metadata, _ -> send(pid, {:observed, event, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    conn =
      OAuthJobs.get(
        conn,
        "/oauth/google/callback?" <> URI.encode_query(%{code: "fake-code", state: state})
      )

    assert redirected_to(conn, 303) == "/workspaces/#{w.id}?gmail=connected"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert [%{subject: "new-subject"}] = Lovelace.Mail.list_accounts!(actor: @owner)
    refute_receive {:observed, _, _}
    assert {:error, :invalid_state} = OAuth.cancel(state, session)
  end

  test "reconnect cannot silently replace an account with another Google subject", %{
    conn: conn,
    workspace: w
  } do
    {:ok, original} =
      Access.accept(
        w.id,
        %{subject: "original", email: "original@example.invalid"},
        "original-refresh"
      )

    {:ok, state, _} =
      OAuth.begin(
        w.id,
        get_session(conn, :owner_session_token),
        original.id,
        :gmail,
        original.generation
      )

    conn =
      OAuthJobs.get(
        conn,
        "/oauth/google/callback?" <> URI.encode_query(%{code: "fake-code", state: state})
      )

    assert_failure(conn, "account_binding", "wrong_account")
    assert [%{subject: "original"}] = Lovelace.Mail.list_accounts!(actor: @owner)
    assert {:ok, "original-refresh"} = Lovelace.TestMailVault.get(original.id)
  end

  test "final storage failure exposes only a safe Keychain category", %{conn: conn, workspace: w} do
    Application.put_env(:lovelace, :gmail_vault, Lovelace.TestMailReadDenied)
    {:ok, state, _} = OAuth.begin(w.id, get_session(conn, :owner_session_token))

    conn =
      OAuthJobs.get(
        conn,
        "/oauth/google/callback?" <> URI.encode_query(%{code: "fake-code", state: state})
      )

    assert_failure(conn, "keychain", "locked")
    refute redirected_to(conn, 303) =~ "fake-code"
    refute redirected_to(conn, 303) =~ "new-refresh"
    assert Lovelace.Mail.list_accounts!(actor: @owner) == []
  end

  test "callback after logout cannot exchange authorization", %{conn: conn, workspace: w} do
    session = get_session(conn, :owner_session_token)
    {:ok, state, _} = OAuth.begin(w.id, session)
    Lovelace.Owner.logout!(session)

    conn =
      OAuthJobs.get(
        conn,
        "/oauth/google/callback?" <> URI.encode_query(%{code: "fake-code", state: state})
      )

    assert_failure(conn, "session", "unavailable")
    assert Lovelace.Mail.list_accounts!(actor: @owner) == []
  end

  test "password path aliases cannot fall through into Phoenix request telemetry", %{conn: conn} do
    pid = self()
    handler = "unlock-alias-privacy-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [[:phoenix, :endpoint, :start], [:phoenix, :router_dispatch, :start]],
      fn event, _, _, _ -> send(pid, {:instrumented, event}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    for path <- ["/unlock/", "/%75nlock", "/unlock//"] do
      response =
        conn
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> post(path, URI.encode_query(%{password: "wrong-synthetic-password"}))

      assert response.status == 401
    end

    refute_receive {:instrumented, _}
  end

  test "callback path aliases stay in the early boundary", %{conn: conn, workspace: w} do
    for path <- ["/oauth/google/callback/", "/oauth//google/callback", "/oauth/%67oogle/callback"] do
      {:ok, state, _} = OAuth.begin(w.id, get_session(conn, :owner_session_token))

      response =
        OAuthJobs.get(
          conn,
          path <> "?" <> URI.encode_query(%{code: "fake-code", state: state})
        )

      assert redirected_to(response, 303) == "/workspaces/#{w.id}?gmail=connected"
    end
  end

  test "loopback IP browser aliases redirect to the canonical localhost origin", %{conn: conn} do
    conn = get(%{conn | host: "127.0.0.1"}, "/unlock")
    port = LovelaceWeb.Endpoint.config(:http) |> Keyword.fetch!(:port)
    assert redirected_to(conn, 303) == "http://localhost:#{port}/"
  end

  defp assert_failure(conn, stage, reason) do
    uri = URI.parse(redirected_to(conn, 303))
    assert uri.path == "/connections/gmail"

    assert URI.decode_query(uri.query) == %{
             "gmail" => "failed",
             "stage" => stage,
             "reason" => reason
           }
  end

  test "DNS rebinding host is rejected", %{conn: conn} do
    conn = get(%{conn | host: "attacker.invalid"}, "/")
    assert response(conn, 400) == "Invalid local host"
  end
end
