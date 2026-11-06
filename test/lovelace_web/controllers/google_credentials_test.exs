defmodule LovelaceWeb.GoogleCredentialsTest do
  use LovelaceWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Lovelace.{Google, Onboarding, Owner}
  alias Lovelace.Integrations.Google.ClientCredentials
  alias Lovelace.Mail.OAuth
  alias Lovelace.TestSupport.{OnboardingGoogleTransport, OnboardingKeychain}
  alias LovelaceWeb.Plugs.GoogleSetupCredentials

  @owner [actor: %{role: :local_owner}]
  @id "synthetic-global-google-client"
  @secret "synthetic-global-google-secret"

  setup %{conn: conn} do
    start_supervised!(OnboardingKeychain)
    {:ok, _} = Lovelace.TestMail.start()

    settings = [
      google_client_keychain: OnboardingKeychain,
      google_client_credentials: ClientCredentials,
      gmail_provider: Lovelace.Integrations.Google,
      calendar_provider: Lovelace.Integrations.Google.Calendar,
      gmail_vault: Lovelace.TestMailVault,
      gmail: [
        redirect_uri: "http://localhost:4000/oauth/google/callback",
        transport: OnboardingGoogleTransport
      ]
    ]

    previous = Enum.map(settings, fn {key, _} -> {key, Application.fetch_env(:lovelace, key)} end)
    Enum.each(settings, fn {key, value} -> Application.put_env(:lovelace, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:lovelace, key, value)
        {key, :error} -> Application.delete_env(:lovelace, key)
      end)
    end)

    %{conn: authenticate_owner(conn)}
  end

  test "global save needs no onboarding workspace, never advances the guide or calls Google", %{
    conn: conn
  } do
    assert {:ok, nil} = Onboarding.progress(@owner)
    assert Lovelace.Workspaces.list_workspaces!(@owner) == []
    observe_requests()

    assert capture_log(fn ->
             saved = submit(conn, %{client_id: @id, client_secret: @secret})
             assert redirected_to(saved, 303) == "/connections/google?google=saved"
             assert_private(saved)
             assert {:ok, :stored} = Google.client_status(@owner)
             assert {:ok, %{client_id: @id, client_secret: @secret}} = ClientCredentials.read()
             assert {:ok, nil} = Onboarding.progress(@owner)
             assert Lovelace.Workspaces.list_workspaces!(@owner) == []
           end) == ""

    refute_receive {:instrumented, _, _}
    assert OnboardingKeychain.writes() == 1
    assert OnboardingKeychain.calls() == []
  end

  test "global saves leave existing onboarding progress unchanged", %{conn: conn} do
    assert {:ok, _} = Onboarding.start(@owner)
    assert {:ok, before} = Onboarding.progress(@owner)
    saved = submit(conn, %{client_id: @id, client_secret: @secret})
    assert redirected_to(saved, 303) == "/connections/google?google=saved"
    assert {:ok, after_save} = Onboarding.progress(@owner)
    assert after_save.step == before.step
    assert after_save.credentials_saved == before.credentials_saved
    assert after_save.workspace_id == nil
  end

  for {field, replacement} <- [
        id: %{client_id: @id <> "-new", client_secret: @secret},
        secret: %{client_id: @id, client_secret: @secret <> "-new"}
      ] do
    @replacement replacement
    test "changed Desktop client #{field} fences both optional grants and pending consent without provider calls",
         %{conn: conn} do
      assert redirected_to(submit(conn, %{client_id: @id, client_secret: @secret}), 303) ==
               "/connections/google?google=saved"

      workspace = Lovelace.Workspaces.create_workspace!("Client replacement", @owner)

      account =
        Lovelace.Mail.save_connection!(
          %{
            subject: "synthetic-shared-subject",
            email: "synthetic-shared@example.invalid",
            generation: Ash.UUID.generate(),
            calendar_enabled: true,
            youtube_enabled: true
          },
          @owner
        )

      {:ok, state, _} =
        OAuth.begin(
          workspace.id,
          get_session(conn, :owner_session_token),
          account.id,
          :youtube,
          account.generation
        )

      saved = submit(conn, @replacement)
      assert redirected_to(saved, 303) == "/connections/google?google=saved"
      current = Lovelace.Mail.get_account!(account.id, @owner)
      assert current.generation != account.generation
      assert current.status == :reconnect
      refute current.calendar_enabled
      refute current.youtube_enabled

      assert {:error, :invalid_state} =
               OAuth.cancel(state, get_session(conn, :owner_session_token))

      assert OnboardingKeychain.calls() == []
    end
  end

  test "saving unchanged client settings does not invalidate an existing grant", %{conn: conn} do
    submit(conn, %{client_id: @id, client_secret: @secret})

    account =
      Lovelace.Mail.save_connection!(
        %{
          subject: "synthetic-unchanged-subject",
          email: "synthetic-unchanged@example.invalid",
          generation: Ash.UUID.generate(),
          calendar_enabled: true,
          youtube_enabled: true
        },
        @owner
      )

    saved = submit(conn, %{client_id: @id, client_secret: @secret})
    assert redirected_to(saved, 303) == "/connections/google?google=saved"
    current = Lovelace.Mail.get_account!(account.id, @owner)
    assert current.generation == account.generation
    assert current.calendar_enabled
    assert current.youtube_enabled
    assert OnboardingKeychain.calls() == []
  end

  test "anonymous and revoked owners are refused before parsing credentials", %{conn: conn} do
    anonymous = build_conn(:get, "http://localhost/")

    refused =
      anonymous
      |> put_req_header("content-type", "application/json")
      |> post("/connections/google", String.duplicate(@secret, 4000))

    assert redirected_to(refused, 303) == "/unlock"
    assert_private(refused)
    Owner.logout(get_session(conn, :owner_session_token))
    revoked = submit(conn, %{client_id: @id, client_secret: @secret})
    assert redirected_to(revoked, 303) == "/unlock"
    assert_private(revoked)
    assert OnboardingKeychain.writes() == 0
  end

  test "CSRF is required even for an active owner", %{conn: conn} do
    page = conn |> put_private(:plug_skip_csrf_protection, false) |> get("/")

    [csrf] =
      page
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query("#owner-lock-form input[name=_csrf_token]")
      |> LazyHTML.attribute("value")

    for token <- [nil, "invalid"] do
      refused =
        page
        |> recycle()
        |> put_private(:plug_skip_csrf_protection, false)
        |> submit(%{client_id: @id, client_secret: @secret, _csrf_token: token})

      assert refused.status == 403
      assert_private(refused)
      assert OnboardingKeychain.writes() == 0
    end

    saved =
      page
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> submit(%{client_id: @id, client_secret: @secret, _csrf_token: csrf})

    assert redirected_to(saved, 303) == "/connections/google?google=saved"
    assert OnboardingKeychain.writes() == 1
  end

  test "aliases cannot bypass the pre-instrumentation boundary", %{conn: conn} do
    observe_requests()

    for path <- ["/connections/google/", "/connections/%67oogle", "/connections//google"] do
      saved = submit(conn, %{client_id: @id, client_secret: @secret}, path)
      assert redirected_to(saved, 303) == "/connections/google?google=saved"
      assert_private(saved)
    end

    assert OnboardingKeychain.writes() == 3
    refute_receive {:instrumented, _, _}
  end

  test "query credentials, methods, content types and oversized or malformed bodies are private",
       %{conn: conn} do
    observe_requests()

    for {method, path, type, body, status} <- [
          {:post, "/connections/google?client_secret=" <> @secret,
           "application/x-www-form-urlencoded", "", 400},
          {:put, "/connections/google", "application/x-www-form-urlencoded", "", 400},
          {:delete, "/connections/google", "application/x-www-form-urlencoded", "", 400},
          {:post, "/connections/google", "application/json", "{}", 400},
          {:post, "/connections/google", "application/x-www-form-urlencoded",
           String.duplicate("x", 66_000), 400},
          {:post, "/connections/google", "application/x-www-form-urlencoded",
           "client_id[nested]=synthetic&client_secret=" <> @secret, 303},
          {:post, "/connections/google", "application/x-www-form-urlencoded", "client_id=" <> @id,
           303}
        ] do
      refused =
        conn |> put_req_header("content-type", type) |> dispatch(@endpoint, method, path, body)

      assert refused.status == status
      assert_private(refused)

      if status == 303 do
        assert redirected_to(refused, 303) == "/connections/google?google=failed"
      end
    end

    assert OnboardingKeychain.writes() == 0
    refute_receive {:instrumented, _, _}
  end

  test "locked and native failure paths never disclose submitted or adapter values", %{conn: conn} do
    observe_requests()

    assert capture_log(fn ->
             for reason <- [:locked, "synthetic-private-native-diagnostic"] do
               OnboardingKeychain.fail(reason)
               failed = submit(conn, %{client_id: @id, client_secret: @secret})
               assert redirected_to(failed, 303) == "/connections/google?google=failed"
               assert_private(failed)
               refute inspect(failed.resp_headers) =~ "synthetic-private-native-diagnostic"
               refute failed.resp_body =~ "synthetic-private-native-diagnostic"
               assert {:ok, status} = Google.client_status(@owner)
               assert status == if(reason == :locked, do: :locked, else: :unavailable)
             end
           end) == ""

    assert OnboardingKeychain.writes() == 0
    assert OnboardingKeychain.calls() == []
    refute_receive {:instrumented, _, _}
  end

  test "ordinary GET and HEAD pass through to the owner-protected LiveView route unchanged" do
    for method <- [:get, :head],
        path <- ["/connections/google", "/connections/google?google=saved"] do
      conn = Plug.Test.conn(method, path)
      assert GoogleSetupCredentials.call(conn, []) == conn
      refute conn.halted
    end
  end

  defp observe_requests do
    observer = self()
    handler = "google-client-private-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [[:phoenix, :endpoint, :start], [:phoenix, :router_dispatch, :start]],
      fn event, _, metadata, _ -> send(observer, {:instrumented, event, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp assert_private(conn) do
    assert conn.halted
    assert conn.params == %{}
    assert conn.body_params == %{}
    assert conn.query_params == %{}
    assert conn.query_string == ""
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    refute inspect(get_session(conn)) =~ @id
    refute inspect(get_session(conn)) =~ @secret
    refute inspect(conn.resp_headers) =~ @id
    refute inspect(conn.resp_headers) =~ @secret
    refute conn.resp_body =~ @id
    refute conn.resp_body =~ @secret
  end

  defp submit(conn, params, path \\ "/connections/google") do
    conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post(path, URI.encode_query(params))
  end
end
