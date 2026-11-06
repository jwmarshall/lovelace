defmodule LovelaceWeb.YouTubeLiveTest do
  use LovelaceWeb.ConnCase, async: false
  use Oban.Testing, repo: Lovelace.Repo, engine: Oban.Engines.Lite
  import Phoenix.LiveViewTest
  import Lovelace.TestSupport.BackgroundWork, only: [complete: 1]
  alias Ash.Resource.Info
  alias Lovelace.Integrations.Google.ClientCredentials
  alias Lovelace.{Mail, Workspaces, YouTube}
  alias Lovelace.TestSupport.OnboardingKeychain
  alias Lovelace.YouTube.{PollWorker, Snapshot, State}
  alias LovelaceWeb.YouTubeComponents
  @owner %{role: :local_owner}
  @channel "UCaaaaaaaaaaaaaaaaaaaaaa"

  defmodule FakeIO do
    @moduledoc false
    @channel "UCaaaaaaaaaaaaaaaaaaaaaa"
    def get(id), do: {:ok, id}
    def refresh(token), do: {:ok, %{access_token: token}}

    def inbox_unread(_token), do: {:error, :invalid_grant}
    def inbox(_token, _page), do: {:error, :invalid_grant}

    def subscriptions(token, nil) do
      send(Application.fetch_env!(:lovelace, :youtube_ui_owner), {:youtube_provider, token})

      case Application.fetch_env!(:lovelace, :youtube_ui_subscriptions_error) do
        nil ->
          {:ok,
           %{channels: [%{"id" => @channel, "title" => "Synthetic channel"}], next_page: nil}}

        reason ->
          {:error, reason}
      end
    end

    def uploads_playlists(_token, [@channel]),
      do: {:ok, %{@channel => "UUaaaaaaaaaaaaaaaaaaaaaa"}}

    def uploads(token, "UUaaaaaaaaaaaaaaaaaaaaaa") do
      send(Application.fetch_env!(:lovelace, :youtube_ui_owner), {:youtube_uploads, token})
      id = Map.fetch!(Application.fetch_env!(:lovelace, :youtube_ui_videos), token)

      {:ok,
       %{
         videos: [
           %{
             "id" => id,
             "title" => "<img src='https://invalid.test/remote'> " <> token,
             "channel_id" => @channel,
             "published_at" => "2026-10-01T12:00:00Z"
           }
         ],
         truncated: false
       }}
    end
  end

  setup %{conn: conn} do
    start_supervised!(OnboardingKeychain)

    for {key, value} <- [
          gmail_provider: FakeIO,
          gmail_vault: FakeIO,
          youtube_provider: FakeIO,
          google_client_keychain: OnboardingKeychain,
          youtube_ui_owner: self(),
          youtube_ui_videos: %{},
          youtube_ui_subscriptions_error: nil
        ] do
      previous = Application.fetch_env(:lovelace, key)
      Application.put_env(:lovelace, key, value)

      on_exit(fn ->
        case previous do
          {:ok, original} -> Application.put_env(:lovelace, key, original)
          :error -> Application.delete_env(:lovelace, key)
        end
      end)
    end

    :ok =
      ClientCredentials.save("synthetic-client", "synthetic-secret")

    a = account("a", true)
    b = account("b", true)
    disabled = account("disabled", false)
    workspace = Workspaces.create_workspace!("YouTube studio", actor: @owner)
    Mail.attach_account!(%{workspace_id: workspace.id, account_id: a.id}, actor: @owner)

    Application.put_env(:lovelace, :youtube_ui_videos, %{
      a.id => "aaaaaaaaaaa",
      b.id => "bbbbbbbbbbb"
    })

    %{conn: authenticate_owner(conn), a: a, b: b, disabled: disabled, workspace: workspace}
  end

  test "YouTube remains optional, consent is account-bound POST, and Home has no YouTube readout",
       ctx do
    {:ok, view, _} = live(ctx.conn, "/")
    assert has_element?(view, "#youtube-nav-#{ctx.a.id}[href='/accounts/#{ctx.a.id}/youtube']")
    refute has_element?(view, "#youtube-feed, #youtube-connections, #youtube-videos")
    view |> element("#show-connections") |> render_click()
    view |> element("#open-connection-youtube") |> render_click()

    assert has_element?(
             view,
             "#youtube-authorize-#{ctx.disabled.id}[method=post][action='/oauth/google/start']"
           )

    assert has_element?(
             view,
             "#youtube-authorize-#{ctx.disabled.id} input[name=capability][value=youtube]"
           )

    assert has_element?(
             view,
             "#youtube-authorize-#{ctx.disabled.id} input[name=expected_account_id][value='#{ctx.disabled.id}']"
           )

    assert has_element?(view, "#youtube-authorize-#{ctx.disabled.id} select[name=workspace_id]")
    refute has_element?(view, "iframe, #youtube-feed")
    refute_receive {:youtube_provider, _}
  end

  test "stored Google settings enable YouTube consent after the durable diagnostic completes",
       ctx do
    {:ok, view, _} = live(ctx.conn, "/connections/youtube")
    authorize = "#youtube-authorize-#{ctx.disabled.id}"
    assert has_element?(view, "#{authorize} button[disabled]")
    assert has_element?(view, "#youtube-connections > p[role=status][aria-busy=true]")
    refute has_element?(view, "#youtube-connections > .calendar-warning")
    refute_receive {:youtube_provider, _}

    complete(view)

    assert has_element?(view, "#{authorize} button:not([disabled])")
    assert has_element?(view, "#{authorize} select:not([disabled])")
    refute has_element?(view, "#youtube-connections > .calendar-warning")
    refute has_element?(view, "#youtube-connections > p[aria-busy=true]")
    refute_receive {:youtube_provider, _}
  end

  test "missing Google settings keep YouTube consent disabled after a completed diagnostic",
       ctx do
    OnboardingKeychain.fail(:not_found)
    {:ok, view, _} = live(ctx.conn, "/connections/youtube")
    complete(view)

    authorize = "#youtube-authorize-#{ctx.disabled.id}"
    assert has_element?(view, "#{authorize} button[disabled]")
    assert has_element?(view, "#{authorize} select[disabled]")
    assert has_element?(view, "#youtube-connections > p[role=status][aria-busy=false]")

    assert has_element?(
             view,
             "#youtube-connections > .calendar-warning a[href='/connections/google']"
           )

    refute_receive {:youtube_provider, _}
  end

  test "an unavailable local snapshot exposes recovery without offering new consent", ctx do
    unavailable = Snapshot.build(nil, nil, :unavailable)

    html =
      render_component(&YouTubeComponents.connections/1,
        readouts: [{ctx.a, unavailable}],
        workspace_options: [{"YouTube studio", ctx.workspace.id}],
        google_status: :stored
      )

    document = LazyHTML.from_fragment(html)
    assert Enum.any?(LazyHTML.query(document, "#youtube-status-#{ctx.a.id} .calendar-warning"))
    refute Enum.any?(LazyHTML.query(document, "#youtube-authorize-#{ctx.a.id}"))
  end

  test "deep links accept only selected account feed membership and never mount a remote player",
       ctx do
    seed(ctx.a)
    seed(ctx.b)
    {:ok, view, html} = live(ctx.conn, "/accounts/#{ctx.a.id}/youtube/videos/aaaaaaaaaaa")
    assert has_element?(view, "#youtube-watch", ctx.a.id)
    refute has_element?(view, "#youtube-watch", ctx.b.id)

    assert has_element?(
             view,
             "#youtube-player[data-account-id='#{ctx.a.id}'][data-video-id=aaaaaaaaaaa]"
           )

    refute has_element?(view, "iframe, img[src^='https://']")
    assert html =~ "&lt;img"
    assert LovelaceWeb.OwnerReturnPath.safe("/accounts/#{ctx.a.id}/youtube/videos/aaaaaaaaaaa")
    {:ok, denied, _} = live(ctx.conn, "/accounts/#{ctx.a.id}/youtube/videos/bbbbbbbbbbb")
    refute has_element?(denied, "#youtube-player, iframe")
  end

  test "selection changes and account events remove the previously permitted video", ctx do
    seed(ctx.a)
    {:ok, view, _} = live(ctx.conn, "/accounts/#{ctx.a.id}/youtube/videos/aaaaaaaaaaa")
    render_submit(view, "youtube:select", %{"account_id" => ctx.b.id, "channel_ids" => [""]})
    assert {:ok, before} = YouTube.snapshot(ctx.a.id, actor: @owner)
    assert before.selected_ids == [@channel]

    render_submit(view, "youtube:select", %{
      "account_id" => ctx.a.id,
      "channel_ids" => [""],
      "generation" => before.generation,
      "revision" => before.revision
    })

    assert {:ok, after_selection} = YouTube.snapshot(ctx.a.id, actor: @owner)
    assert after_selection.selected_ids == []
    refute has_element?(view, "#youtube-player, iframe")
    send(view.pid, {:youtube_changed, ctx.b.id})
    refute has_element?(view, "#youtube-player, iframe")
  end

  for source <- [:poll, :interactive_read] do
    @failure_source source
    test "#{source} Gmail credential failure revokes an open YouTube watch admission", ctx do
      seed(ctx.a)
      {:ok, view, _} = live(ctx.conn, "/accounts/#{ctx.a.id}/youtube/videos/aaaaaaaaaaa")
      assert has_element?(view, "#youtube-player[data-video-id=aaaaaaaaaaa]")

      if @failure_source == :poll do
        Mail.poll!(ctx.a.id, ctx.a.generation,
          actor: %{role: :mail_service, account_id: ctx.a.id}
        )
      else
        # This is the public action used by an interactive read in another browser view.
        assert %{error: :reconnect} = Mail.account_page!(ctx.a.id, %{force: true}, actor: @owner)
      end

      assert Mail.get_account!(ctx.a.id, actor: @owner).status == :reconnect
      refute has_element?(view, "#youtube-player, [data-youtube-load]")
      refute has_element?(view, "#youtube-feed", "YouTube is not enabled")
    end
  end

  test "late account A work cannot replace account B's player when video IDs are reused", ctx do
    Application.put_env(:lovelace, :youtube_ui_videos, %{
      ctx.a.id => "aaaaaaaaaaa",
      ctx.b.id => "aaaaaaaaaaa"
    })

    seed(ctx.a)
    seed(ctx.b)
    {:ok, view, _} = live(ctx.conn, "/accounts/#{ctx.a.id}/youtube/videos/aaaaaaaaaaa")
    pending = YouTube.refresh!(ctx.a.id, actor: @owner)

    render_patch(view, "/accounts/#{ctx.b.id}/youtube/videos/aaaaaaaaaaa")
    YouTube.poll!(ctx.a.id, ctx.a.generation, pending.revision, actor: @owner)
    send(view.pid, {:youtube_changed, ctx.a.id})

    assert has_element?(
             view,
             "#youtube-player[data-account-id='#{ctx.b.id}'][data-video-id=aaaaaaaaaaa]"
           )

    assert has_element?(view, "#youtube-watch h4", ctx.b.id)
    refute has_element?(view, "#youtube-watch h4", ctx.a.id)
  end

  test "an old selection form cannot restore a selection changed in another tab", ctx do
    seed(ctx.a)
    {:ok, view, _} = live(ctx.conn, "/accounts/#{ctx.a.id}/youtube")
    {:ok, old} = YouTube.snapshot(ctx.a.id, actor: @owner)

    {:ok, current} =
      YouTube.select_channels(ctx.a.id, [], old.generation, old.revision, actor: @owner)

    render_submit(view, "youtube:select", %{
      "account_id" => ctx.a.id,
      "channel_ids" => [@channel],
      "generation" => old.generation,
      "revision" => old.revision
    })

    assert {:ok, after_stale_form} = YouTube.snapshot(ctx.a.id, actor: @owner)
    assert after_stale_form.selected_ids == []
    assert after_stale_form.revision == current.revision
  end

  test "requested watch destination survives owner unlock boundary", ctx do
    path = "/accounts/#{ctx.a.id}/youtube/videos/aaaaaaaaaaa"
    conn = Phoenix.ConnTest.build_conn(:get, "http://localhost/") |> get(path)
    assert redirected_to(conn) == "/unlock"
    assert get_session(conn, :owner_return_to) == path
  end

  test "expired local uploads revoke an open player and cannot admit a new watch route", ctx do
    seed(ctx.a)
    {:ok, view, _} = live(ctx.conn, "/accounts/#{ctx.a.id}/youtube/videos/aaaaaaaaaaa")
    assert has_element?(view, "#youtube-player[data-video-id=aaaaaaaaaaa]")

    store_state(ctx.a, %{fetched_at: DateTime.add(DateTime.utc_now(), -86_401)})
    send(view.pid, {:youtube_changed, ctx.a.id})

    refute has_element?(view, "#youtube-player, [data-youtube-load], iframe")
    refute has_element?(view, "#youtube-feed-status time")
    assert has_element?(view, "#youtube-watch [role=status]")

    {:ok, reopened, _} =
      live(ctx.conn, "/accounts/#{ctx.a.id}/youtube/videos/aaaaaaaaaaa")

    refute has_element?(reopened, "#youtube-player, [data-youtube-load], iframe")
  end

  test "rate limiting a manual refresh retains the last feed and cannot be bypassed", ctx do
    seed(ctx.a)
    consume_seed_calls(ctx.a)
    before = YouTube.snapshot!(ctx.a.id, actor: @owner)
    checked_at = DateTime.to_iso8601(before.fetched_at)
    {:ok, view, _} = live(ctx.conn, "/accounts/#{ctx.a.id}/youtube")

    view |> element("#youtube-refresh") |> render_click()
    assert has_element?(view, "#youtube-feed[aria-busy=true]")
    assert has_element?(view, "#youtube-videos a[href$='/videos/aaaaaaaaaaa']")
    assert has_element?(view, "#youtube-feed-status time[datetime='#{checked_at}']")

    pending = YouTube.snapshot!(ctx.a.id, actor: @owner)
    Application.put_env(:lovelace, :youtube_ui_subscriptions_error, :rate_limited)
    YouTube.poll!(ctx.a.id, ctx.a.generation, pending.revision, actor: @owner)
    assert_receive {:youtube_provider, account_id} when account_id == ctx.a.id

    assert has_element?(view, "#youtube-feed[aria-busy=false]")
    assert has_element?(view, "#youtube-feed-status .calendar-warning")
    assert has_element?(view, "#youtube-videos a[href$='/videos/aaaaaaaaaaa']")
    assert has_element?(view, "#youtube-feed-status time[datetime='#{checked_at}']")
    limited = YouTube.snapshot!(ctx.a.id, actor: @owner)
    assert limited.error == :rate_limited
    assert limited.videos == before.videos
    assert limited.fetched_at == before.fetched_at
    assert DateTime.compare(limited.cooldown_until, DateTime.utc_now()) == :gt
    assert has_element?(view, ".youtube-actions", DateTime.to_iso8601(limited.cooldown_until))
    jobs = all_enqueued(worker: PollWorker)

    for _ <- 1..2 do
      render_click(view, "youtube:refresh", %{"account_id" => ctx.a.id})
    end

    after_retry = YouTube.snapshot!(ctx.a.id, actor: @owner)
    assert after_retry.revision == limited.revision
    assert after_retry.cooldown_until == limited.cooldown_until
    assert after_retry.fetched_at == before.fetched_at
    refute after_retry.loading
    assert all_enqueued(worker: PollWorker) == jobs

    assert %{skipped: true} =
             YouTube.poll!(ctx.a.id, ctx.a.generation, pending.revision, actor: @owner)

    refute_receive {:youtube_provider, _}
    refute_receive {:youtube_uploads, _}
    assert has_element?(view, "#youtube-videos a[href$='/videos/aaaaaaaaaaa']")
    assert has_element?(view, "#youtube-feed-status time[datetime='#{checked_at}']")
  end

  test "bounded observation stops and Check local status reads without starting provider work",
       ctx do
    seed(ctx.a)
    consume_seed_calls(ctx.a)
    {:ok, view, _} = live(ctx.conn, "/accounts/#{ctx.a.id}/youtube")
    view |> element("#youtube-refresh") |> render_click()

    for attempt <- 1..20 do
      {timer, token} = observation_timer(view)
      Process.cancel_timer(timer)
      send(view.pid, {:youtube_observe, token, attempt})
      render(view)
    end

    assert has_element?(view, "#youtube-feed[aria-busy=true]")
    assert has_element?(view, "button[phx-click='youtube:check']")
    assert has_element?(view, "#youtube-videos a[href$='/videos/aaaaaaaaaaa']")
    pending = YouTube.snapshot!(ctx.a.id, actor: @owner)
    jobs = all_enqueued(worker: PollWorker)

    store_state(ctx.a, %{fetched_at: DateTime.add(DateTime.utc_now(), -86_401)})
    view |> element("button[phx-click='youtube:check']") |> render_click()

    refute has_element?(view, "#youtube-videos a, #youtube-feed-status time")
    assert has_element?(view, "#youtube-feed[aria-busy=true]")
    after_check = YouTube.snapshot!(ctx.a.id, actor: @owner)
    assert after_check.revision == pending.revision
    assert after_check.loading
    assert all_enqueued(worker: PollWorker) == jobs
    refute_receive {:youtube_provider, _}
    refute_receive {:youtube_uploads, _}
  end

  test "late observer ticks cannot exhaust another account or restore YouTube after navigation",
       ctx do
    seed(ctx.a)
    seed(ctx.b)
    {:ok, view, _} = live(ctx.conn, "/accounts/#{ctx.a.id}/youtube")
    view |> element("#youtube-refresh") |> render_click()
    {timer, old_token} = observation_timer(view)
    Process.cancel_timer(timer)
    YouTube.refresh!(ctx.b.id, actor: @owner)

    render_patch(view, "/accounts/#{ctx.b.id}/youtube/videos/bbbbbbbbbbb")
    send(view.pid, {:youtube_observe, old_token, 20})
    send(view.pid, {:youtube_changed, ctx.a.id})

    assert has_element?(view, "#youtube-feed[aria-busy=true]")
    assert has_element?(view, "#youtube-player[data-account-id='#{ctx.b.id}']")
    refute has_element?(view, "button[phx-click='youtube:check']")
    {new_timer, new_token} = observation_timer(view)
    Process.cancel_timer(new_timer)

    render_patch(view, "/")
    send(view.pid, {:youtube_observe, new_token, 20})
    send(view.pid, {:youtube_changed, ctx.b.id})
    render_click(view, "youtube:check", %{})

    refute has_element?(view, "#youtube-feed, #youtube-player, #youtube-connections")
    refute has_element?(view, "button[phx-click='youtube:check']")
  end

  defp observation_timer(view) do
    :sys.get_state(view.pid).socket.assigns.youtube_observer
  end

  defp consume_seed_calls(account) do
    assert_receive {:youtube_provider, id} when id == account.id
    assert_receive {:youtube_provider, id} when id == account.id
    assert_receive {:youtube_uploads, id} when id == account.id
  end

  defp store_state(account, changes) do
    state =
      State
      |> Ash.Query.for_read(:read, %{account_id: account.id}, actor: @owner)
      |> Ash.read_one!()

    attributes = Map.take(state, Info.action(State, :store).accept)

    State
    |> Ash.Changeset.for_create(:store, Map.merge(attributes, changes), actor: @owner)
    |> Ash.create!()
  end

  defp seed(account) do
    {:ok, catalog} = YouTube.prepare(account.id, actor: @owner)
    {:ok, _} = YouTube.poll(account.id, account.generation, catalog.revision, actor: @owner)

    {:ok, selection} =
      YouTube.select_channels(account.id, [@channel], catalog.generation, catalog.revision,
        actor: @owner
      )

    {:ok, _} = YouTube.poll(account.id, account.generation, selection.revision, actor: @owner)
  end

  defp account(subject, enabled) do
    Mail.save_connection!(
      %{
        id: Ecto.UUID.generate(),
        subject: "youtube-ui-" <> subject,
        email: subject <> "@example.test",
        generation: Ecto.UUID.generate(),
        youtube_enabled: enabled
      },
      actor: @owner
    )
  end
end
