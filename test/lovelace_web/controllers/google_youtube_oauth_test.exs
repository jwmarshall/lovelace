defmodule LovelaceWeb.GoogleYouTubeOAuthTest do
  use LovelaceWeb.ConnCase
  alias Ash.Resource.Info
  alias Lovelace.Calendar.State, as: CalendarState
  alias Lovelace.Google.Access
  alias Lovelace.Mail.{DisconnectWorker, OAuth}
  alias Lovelace.TestSupport.OAuthJobs
  alias Lovelace.YouTube.State, as: YouTubeState
  @owner %{role: :local_owner}
  @gmail "https://www.googleapis.com/auth/gmail.readonly"
  @youtube "https://www.googleapis.com/auth/youtube.readonly"
  @calendar [
    "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
    "https://www.googleapis.com/auth/calendar.events.readonly"
  ]

  defmodule Provider do
    @behaviour Lovelace.Google.OAuthProvider
    @impl true
    def authorization_url(params) do
      Lovelace.TestMail.record({:authorization, params})

      {:ok,
       "https://accounts.google.com/o/oauth2/v2/auth?" <> URI.encode_query(%{state: params.state})}
    end

    @impl true
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

    @impl true
    def identity(_) do
      Lovelace.TestMail.record(:identity)

      owner =
        Agent.get_and_update(Lovelace.TestMail, fn state ->
          {Map.get(state, :identity_owner), Map.delete(state, :identity_owner)}
        end)

      if owner do
        send(owner, {:identity_waiting, self()})

        receive do
          :continue -> :ok
        end
      end

      {:ok, %{subject: "youtube-sub", email: "youtube@example.invalid"}}
    end

    @impl true
    def refresh(_), do: {:ok, %{access_token: "synthetic-access", expires_in: 3600}}
    @impl true
    def revoke(_), do: :ok
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
    workspace = Lovelace.Workspaces.create_workspace!("YouTube OAuth", actor: @owner)

    {:ok, account} =
      Access.accept(
        workspace.id,
        %{subject: "youtube-sub", email: "youtube@example.invalid"},
        "prior-refresh"
      )

    Lovelace.TestMail.response({:ok, tokens()})
    %{conn: conn, workspace: workspace, account: account}
  end

  test "YouTube consent requires owner authorization and CSRF", c do
    anonymous = post(build_conn(:get, "http://localhost/"), "/oauth/google/start", intent(c))
    assert redirected_to(anonymous) == "/unlock"

    for csrf <- [nil, "invalid-synthetic-csrf"] do
      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        c.conn
        |> recycle()
        |> put_private(:plug_skip_csrf_protection, false)
        |> post("/oauth/google/start", Map.put(intent(c), :_csrf_token, csrf))
      end
    end

    refute Enum.any?(Lovelace.TestMail.calls(), &match?({:authorization, _}, &1))
    assert_unchanged(c)
  end

  test "YouTube start binds an existing identity and disallows onboarding", c do
    refute c.account.youtube_enabled

    for changes <- [
          %{expected_account_id: nil},
          %{expected_account_id: ""},
          %{expected_account_id: Ash.UUID.generate()},
          %{workspace_id: Ash.UUID.generate()},
          %{origin: "onboarding"}
        ] do
      response = post(c.conn, "/oauth/google/start", Map.merge(intent(c), changes))
      assert redirected_to(response) == "/connections/youtube"
    end

    refute Enum.any?(Lovelace.TestMail.calls(), &match?({:authorization, _}, &1))
    response = post(c.conn, "/oauth/google/start", intent(c))
    assert URI.parse(redirected_to(response, 303)).host == "accounts.google.com"

    assert [{:authorization, %{capability: :youtube, capabilities: [:youtube]} = params}] =
             Lovelace.TestMail.calls()

    assert {:ok, attempt} = OAuth.cancel(params.state, session(c))
    assert attempt.expected_account_id == c.account.id
    assert attempt.expected_generation == c.account.generation
    assert attempt.origin == :connections
  end

  test "scope-backed consent reuses the same account and dedicated credential", c do
    response = finish(c)
    assert redirected_to(response, 303) == "/connections/youtube?youtube=connected"
    saved = current(c)
    assert saved.youtube_enabled
    refute saved.calendar_enabled
    assert saved.generation != c.account.generation
    assert saved.subject == c.account.subject
    assert {:ok, "new-refresh"} = Lovelace.TestMailVault.get(saved.id)
    assert [only] = Lovelace.Mail.list_accounts!(actor: @owner)
    assert only.id == c.account.id
  end

  test "YouTube consent preserves previously explicit Calendar, never surplus returned scopes",
       c do
    Lovelace.TestMail.response({:ok, tokens(@calendar)})
    assert redirected_to(finish(c), 303) == "/connections/youtube?youtube=connected"
    refute current(c).calendar_enabled

    c = %{c | account: current(c)}
    {:ok, account} = Access.accept(c.workspace.id, identity(c), "prior-refresh", :calendar)
    c = %{c | account: account}
    post(c.conn, "/oauth/google/start", intent(c))

    assert [{:authorization, %{capabilities: [:calendar, :youtube]} = params} | _] =
             Lovelace.TestMail.calls()

    assert redirected_to(OAuthJobs.get(c.conn, callback_url(params.state)), 303) ==
             "/connections/youtube?youtube=connected"

    assert current(c).calendar_enabled
    assert current(c).youtube_enabled
  end

  test "Calendar request preserves explicitly granted YouTube with returned evidence", c do
    {:ok, account} = Access.accept(c.workspace.id, identity(c), "prior-refresh", :youtube)
    c = %{c | account: account}
    Lovelace.TestMail.response({:ok, tokens(@calendar)})
    response = post(c.conn, "/oauth/google/start", %{intent(c) | capability: "calendar"})
    assert redirected_to(response, 303) =~ "https://accounts.google.com/"

    assert [{:authorization, %{capabilities: [:calendar, :youtube]} = params} | _] =
             Lovelace.TestMail.calls()

    assert redirected_to(OAuthJobs.get(c.conn, callback_url(params.state)), 303) ==
             "/connections/calendar?calendar=connected"

    assert current(c).calendar_enabled
    assert current(c).youtube_enabled
  end

  test "YouTube consent missing previously granted Calendar preserves credentials and both caches",
       c do
    assert_partial_grant_preserves(c, :calendar, :youtube, [@gmail, @youtube])
  end

  test "Calendar consent missing previously granted YouTube preserves credentials and both caches",
       c do
    assert_partial_grant_preserves(c, :youtube, :calendar, [@gmail | @calendar])
  end

  test "missing YouTube scope evidence or denial preserves the old connection", c do
    for scope <- [nil, [], [@gmail], [@youtube]] do
      token =
        if is_nil(scope), do: Map.delete(tokens(), :scopes), else: %{tokens() | scopes: scope}

      Lovelace.TestMail.response({:ok, token})
      assert redirected_to(finish(c), 303) == "/connections/youtube?youtube=failed"
      assert_unchanged(c)
    end

    refute :identity in Lovelace.TestMail.calls()
    before = Enum.count(Lovelace.TestMail.calls(), &(&1 == :exchange))
    state = begin_attempt(c)

    response =
      OAuthJobs.get(
        c.conn,
        "/oauth/google/callback?" <>
          URI.encode_query(%{
            state: state,
            error: "access_denied",
            return_to: "https://untrusted.invalid"
          })
      )

    assert redirected_to(response, 303) == "/connections/youtube?youtube=failed"
    assert Enum.count(Lovelace.TestMail.calls(), &(&1 == :exchange)) == before
    assert_unchanged(c)
  end

  test "wrong Google subject cannot replace the expected account", c do
    {:ok, other} =
      Access.accept(
        c.workspace.id,
        %{subject: "other-sub", email: "other@example.invalid"},
        "other-refresh"
      )

    other_context = %{c | account: other}
    assert redirected_to(finish(other_context), 303) == "/connections/youtube?youtube=failed"
    assert_unchanged(c)
    assert {:ok, "other-refresh"} = Lovelace.TestMailVault.get(other.id)
    refute current(other_context).youtube_enabled
  end

  test "stale consent cannot survive reconnect, client replacement, or disconnect", c do
    for replacement <- [:reconnect, :client, :disconnect] do
      c = %{c | account: current(c)}

      if c.account.status == :disconnected do
        {:ok, account} = Access.accept(c.workspace.id, identity(c), "prior-refresh")
        assert account.status == :ready
      end

      c = %{c | account: current(c)}
      state = begin_attempt(c)

      case replacement do
        :reconnect ->
          assert {:ok, _} = Access.accept(c.workspace.id, identity(c), "replacement-refresh")

        :client ->
          assert :ok = OAuth.client_change(fn -> Access.client_changed() end)

        :disconnect ->
          assert {:ok, _} = Lovelace.Mail.disconnect(c.account.id, actor: @owner)
      end

      saved = current(c)
      calls = Lovelace.TestMail.calls()

      OAuthJobs.get(c.conn, callback_url(state))

      assert Lovelace.TestMail.calls() == calls
      assert current(c).generation == saved.generation
      refute current(c).youtube_enabled
    end

    response = post(c.conn, "/oauth/google/start", intent(c))
    assert redirected_to(response) == "/connections/youtube"
  end

  test "reconnect during identity lookup fences late publication and credential reuse", c do
    Lovelace.TestMail.response({:ok, Map.delete(tokens(), :refresh_token)})
    owner = self()
    Agent.update(Lovelace.TestMail, &Map.put(&1, :identity_owner, owner))
    task = Task.async(fn -> finish(c) end)
    assert_receive {:identity_waiting, worker}
    {:ok, replacement} = Access.accept(c.workspace.id, identity(c), "replacement-refresh")
    send(worker, :continue)
    assert redirected_to(Task.await(task), 303) == "/connections/youtube?youtube=failed"
    assert current(c).generation == replacement.generation
    assert {:ok, "replacement-refresh"} = Lovelace.TestMailVault.get(c.account.id)
    refute current(c).youtube_enabled
  end

  test "attempts are session bound and one-use; logout before commit preserves prior grant", c do
    state = begin_attempt(c, "different-session")
    response = OAuthJobs.get(c.conn, callback_url(state) <> "&capability=youtube")
    assert URI.parse(redirected_to(response, 303)).path == "/connections/gmail"
    refute :exchange in Lovelace.TestMail.calls()
    assert_unchanged(c)

    state = begin_attempt(c)

    assert redirected_to(OAuthJobs.get(c.conn, callback_url(state)), 303) ==
             "/connections/youtube?youtube=connected"

    calls = Lovelace.TestMail.calls()

    assert URI.parse(redirected_to(OAuthJobs.get(c.conn, callback_url(state)), 303)).path ==
             "/connections/gmail"

    assert Lovelace.TestMail.calls() == calls
    c = %{c | account: current(c)}
    Lovelace.TestMail.response({:logout, session(c), tokens()})
    assert redirected_to(finish(c), 303) == "/connections/youtube?youtube=failed"
    assert current(c).generation == c.account.generation
    assert current(c).youtube_enabled
  end

  test "ordinary Gmail reconnect disables both optional capabilities even with surplus scope evidence",
       c do
    Lovelace.TestMail.response({:ok, tokens(@calendar)})

    {:ok, account} =
      Access.accept(
        c.workspace.id,
        identity(c),
        "prior-refresh",
        :youtube,
        c.account.generation,
        %{id: c.account.id, generation: c.account.generation},
        %{calendar_enabled: true, youtube_enabled: true}
      )

    c = %{c | account: account}

    assert redirected_to(finish(c, :gmail), 303) ==
             "/workspaces/#{c.workspace.id}?gmail=connected"

    refute current(c).youtube_enabled
    refute current(c).calendar_enabled
  end

  test "missing refresh token reuses only the same current subject credential", c do
    Lovelace.TestMail.response({:ok, Map.delete(tokens(), :refresh_token)})
    assert redirected_to(finish(c), 303) == "/connections/youtube?youtube=connected"
    assert {:ok, "prior-refresh"} = Lovelace.TestMailVault.get(c.account.id)
  end

  test "client replacement preserves the generation owned by admitted disconnect cleanup", c do
    assert {:ok, operation} = Lovelace.Mail.disconnect(c.account.id, actor: @owner)
    disconnected = current(c)
    assert :ok = OAuth.client_change(fn -> Access.client_changed() end)
    assert current(c).generation == disconnected.generation

    assert :ok =
             DisconnectWorker.perform(%Oban.Job{
               args: %{"operation_id" => operation.operation_id}
             })

    assert {:error, :not_found} = Lovelace.TestMailVault.get(c.account.id)
    refute current(c).youtube_enabled
    refute current(c).calendar_enabled
  end

  defp intent(c),
    do: %{workspace_id: c.workspace.id, expected_account_id: c.account.id, capability: "youtube"}

  defp tokens(extra \\ []),
    do: %{
      access_token: "synthetic-access",
      refresh_token: "new-refresh",
      expires_in: 3600,
      scopes: [@gmail, @youtube | extra]
    }

  defp session(c), do: get_session(c.conn, :owner_session_token)
  defp identity(c), do: %{subject: c.account.subject, email: c.account.email}
  defp current(c), do: Lovelace.Mail.get_account!(c.account.id, actor: @owner)

  defp callback_url(state),
    do: "/oauth/google/callback?" <> URI.encode_query(%{code: "synthetic-code", state: state})

  defp begin_attempt(c, session \\ nil, capability \\ :youtube) do
    {:ok, state, _} =
      OAuth.begin(
        c.workspace.id,
        session || session(c),
        c.account.id,
        capability,
        c.account.generation
      )

    state
  end

  defp finish(c, capability \\ :youtube),
    do: OAuthJobs.get(c.conn, callback_url(begin_attempt(c, nil, capability)))

  defp assert_partial_grant_preserves(c, enabled, requested, scopes) do
    {:ok, account} = Access.accept(c.workspace.id, identity(c), "prior-refresh", enabled)
    c = %{c | account: account}
    seed_caches(account)
    prior_calendar = cached_state(CalendarState, account.id)
    prior_youtube = cached_state(YouTubeState, account.id)
    Lovelace.TestMail.response({:ok, %{tokens() | scopes: scopes}})
    post(c.conn, "/oauth/google/start", %{intent(c) | capability: Atom.to_string(requested)})

    assert [{:authorization, %{capabilities: [:calendar, :youtube]} = params} | _] =
             Lovelace.TestMail.calls()

    OAuthJobs.get(c.conn, callback_url(params.state))

    saved = current(c)
    assert saved.generation == account.generation
    assert saved.status == account.status
    assert saved.calendar_enabled == account.calendar_enabled
    assert saved.youtube_enabled == account.youtube_enabled
    assert {:ok, "prior-refresh"} = Lovelace.TestMailVault.get(account.id)
    assert cached_state(CalendarState, account.id) == prior_calendar
    assert cached_state(YouTubeState, account.id) == prior_youtube
    assert :exchange in Lovelace.TestMail.calls()
    refute :identity in Lovelace.TestMail.calls()
  end

  defp seed_caches(account) do
    now = DateTime.utc_now()

    shared = %{
      account_id: account.id,
      generation: account.generation,
      revision: Ash.UUID.generate(),
      selected_ids: ["synthetic-selection"],
      catalog_at: now,
      fetched_at: now,
      next_poll_at: DateTime.add(now, 180)
    }

    calendar =
      Map.merge(shared, %{
        calendars: [%{"id" => "synthetic-selection", "name" => "Synthetic calendar"}],
        events: [%{"id" => "synthetic-event", "title" => "Synthetic event"}],
        explicit_selection: true,
        from_at: now,
        to_at: DateTime.add(now, 86_400),
        local_date: DateTime.to_date(now),
        timezone: "UTC",
        context_at: now
      })

    youtube =
      Map.merge(shared, %{
        channels: [%{"id" => "synthetic-selection", "title" => "Synthetic channel"}],
        videos: [%{"id" => "synthetic-video", "title" => "Synthetic video"}]
      })

    CalendarState
    |> Ash.Changeset.for_create(:store, calendar, actor: @owner)
    |> Ash.create!()

    YouTubeState
    |> Ash.Changeset.for_create(:store, youtube, actor: @owner)
    |> Ash.create!()
  end

  defp cached_state(resource, account_id) do
    resource
    |> Ash.Query.for_read(:read, %{account_id: account_id}, actor: @owner)
    |> Ash.read_one!()
    |> Map.take(Info.action(resource, :store).accept)
  end

  defp assert_unchanged(c) do
    saved = current(c)
    assert saved.generation == c.account.generation
    assert saved.status == c.account.status
    refute saved.youtube_enabled
    assert {:ok, "prior-refresh"} = Lovelace.TestMailVault.get(saved.id)
  end
end
