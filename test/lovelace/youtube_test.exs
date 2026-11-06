defmodule Lovelace.YouTubeTest.Provider do
  @behaviour Lovelace.YouTube.Provider
  def start(channels, videos) do
    Agent.start_link(
      fn ->
        %{
          pages: %{nil => {:ok, %{channels: channels, next_page: nil}}},
          videos: videos,
          calls: [],
          failure: nil,
          wait: nil
        }
      end,
      name: __MODULE__
    )
  end

  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
  def change(changes), do: Agent.update(__MODULE__, &Map.merge(&1, changes))

  defp record(call),
    do: Agent.update(__MODULE__, &Map.update!(&1, :calls, fn calls -> [call | calls] end))

  @impl true
  def subscriptions(token, page) do
    record({:subscriptions, token, page})

    case Agent.get(__MODULE__, fn state -> state.failure || Map.fetch!(state.pages, page) end) do
      :raise -> raise "synthetic provider failure with private text"
      :throw -> throw({:private, "synthetic provider failure"})
      response -> response
    end
  end

  @impl true
  def uploads_playlists(token, ids) do
    record({:playlists, token, ids})

    Agent.get(__MODULE__, fn state ->
      Map.get(state, :playlists, {:ok, Map.new(ids, &{&1, "UU" <> String.slice(&1, 2..-1//1)})})
    end)
  end

  @impl true
  def uploads(token, playlist) do
    record({:uploads, token, playlist})
    wait = Agent.get(__MODULE__, & &1.wait)

    if wait do
      send(wait, {:youtube_waiting, self()})

      receive do
        :continue -> :ok
      end
    end

    Agent.get(__MODULE__, fn state ->
      case state.videos do
        {:error, reason} -> {:error, reason}
        rows -> {:ok, %{videos: Map.get(rows, playlist, []), truncated: false}}
      end
    end)
  end
end

defmodule Lovelace.YouTubeTest do
  use Lovelace.DataCase, async: false
  use Oban.Testing, repo: Lovelace.Repo, engine: Oban.Engines.Lite
  alias Ash.Resource.Info
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Lovelace.Google.Access
  alias Lovelace.YouTube
  alias Lovelace.YouTube.{Payload, PollWorker, Snapshot, State, SweepWorker}
  alias Lovelace.YouTubeTest.Provider
  @owner %{role: :local_owner}
  @a "UCaaaaaaaaaaaaaaaaaaaaaa"
  @b "UCbbbbbbbbbbbbbbbbbbbbbb"
  @c "UCcccccccccccccccccccccc"

  setup do
    {:ok, _} = Lovelace.TestMail.start()

    previous =
      Map.new(
        [:youtube_provider, :gmail_provider, :gmail_vault],
        &{&1, Application.get_env(:lovelace, &1)}
      )

    Application.put_env(:lovelace, :youtube_provider, Provider)
    Application.put_env(:lovelace, :gmail_provider, Lovelace.TestGoogle)
    Application.put_env(:lovelace, :gmail_vault, Lovelace.TestMailVault)

    on_exit(fn ->
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:lovelace, key, value),
          else: Application.delete_env(:lovelace, key)
      end
    end)

    workspace = Lovelace.Workspaces.create_workspace!("YouTube fixture", actor: @owner)

    {:ok, account} =
      Access.accept(
        workspace.id,
        %{subject: "youtube-a", email: "a@example.invalid"},
        "token-a",
        :youtube
      )

    {:ok, other} =
      Access.accept(
        workspace.id,
        %{subject: "youtube-b", email: "b@example.invalid"},
        "token-b",
        :youtube
      )

    channels = [
      %{"id" => @a, "title" => "A <script>"},
      %{"id" => @b, "title" => "B"},
      %{"id" => @c, "title" => "Never selected"}
    ]

    video = fn id, channel, at ->
      %{"id" => id, "title" => "Synthetic upload", "channel_id" => channel, "published_at" => at}
    end

    videos = %{
      "UUaaaaaaaaaaaaaaaaaaaaaa" => [
        video.("video000001", @a, "2026-11-05T12:00:00Z"),
        video.("video000002", @a, "2026-11-06T12:00:00Z"),
        video.("video000002", @a, "2026-11-06T12:00:00Z")
      ],
      "UUbbbbbbbbbbbbbbbbbbbbbb" => [video.("video000003", @b, "2026-11-06T11:00:00Z")],
      "UUcccccccccccccccccccccc" => [video.("video000004", @c, "2026-11-06T13:00:00Z")]
    }

    {:ok, _} = Provider.start(channels, videos)
    %{account: account, other: other, workspace: workspace, channels: channels, videos: videos}
  end

  defp snapshot(account), do: YouTube.snapshot!(account.id, actor: @owner)

  defp poll(account, revision),
    do: YouTube.poll!(account.id, account.generation, revision, actor: @owner)

  defp catalog(account) do
    prepared = YouTube.prepare!(account.id, actor: @owner)

    assert :ok =
             perform_job(PollWorker, %{
               account_id: account.id,
               generation: account.generation,
               revision: prepared.revision
             })

    snapshot(account)
  end

  defp selected(account, ids) do
    catalog(account)
    choose!(account, ids)
  end

  defp choose!(account, ids) do
    view = snapshot(account)
    YouTube.select_channels!(account.id, ids, view.generation, view.revision, actor: @owner)
  end

  defp choose(account, ids) do
    view = snapshot(account)
    YouTube.select_channels(account.id, ids, view.generation, view.revision, actor: @owner)
  end

  defp state(account),
    do:
      State
      |> Ash.Query.for_read(:read, %{account_id: account.id}, actor: @owner)
      |> Ash.read_one!()

  defp store_state(account, changes) do
    attrs = Map.take(state(account), Info.action(State, :store).accept)

    State
    |> Ash.Changeset.for_create(:store, Map.merge(attrs, changes), actor: @owner)
    |> Ash.create!()
  end

  defp expire_inflight(account, ids) do
    pending = selected(account, ids)
    Provider.change(%{wait: self()})
    task = Task.async(fn -> poll(account, pending.revision) end)
    Sandbox.allow(Lovelace.Repo, self(), task.pid)
    assert_receive {:youtube_waiting, pid}, 2000
    assert %DateTime{} = state(account).started_at
    store_state(account, %{started_at: DateTime.add(DateTime.utc_now(), -121)})
    view = snapshot(account)
    refute view.loading
    assert view.error == :unavailable
    calls = Provider.calls()
    send(pid, :continue)
    assert Task.await(task).skipped
    assert Provider.calls() == calls
    assert state(account).videos == []
    assert state(account).fetched_at == nil
    assert YouTube.sweep!(actor: @owner) == %{swept: true}
    recovered = state(account)
    assert recovered.loading && recovered.revision != pending.revision
    assert recovered.started_at == nil
    assert poll(account, pending.revision).skipped
  end

  test "owner-only local capabilities enqueue correlated ID-only jobs without provider calls",
       c do
    assert {:error, _} = YouTube.snapshot(c.account.id)
    assert {:error, _} = YouTube.prepare(c.account.id)
    assert {:error, _} = YouTube.refresh(c.account.id)

    assert {:error, _} =
             YouTube.select_channels(c.account.id, [], c.account.generation, Ash.UUID.generate())

    assert {:error, _} = YouTube.sweep()

    assert {:error, _} =
             State |> Ash.Query.for_read(:read, %{account_id: c.account.id}) |> Ash.read()

    pending = YouTube.prepare!(c.account.id, actor: @owner)
    assert pending.loading && pending.status == :loading
    assert pending.videos == [] && pending.selected_ids == []
    assert Provider.calls() == [] && Lovelace.TestMail.calls() == []

    assert_enqueued(
      worker: PollWorker,
      args: %{
        account_id: c.account.id,
        generation: c.account.generation,
        revision: pending.revision
      }
    )

    assert state(c.account).job_id
    assert snapshot(c.other).videos == []
  end

  test "never auto-selects, selected-only uploads are deduplicated and newest first", c do
    assert catalog(c.account).status == :empty
    assert snapshot(c.account).selected_ids == []
    refute Enum.any?(Provider.calls(), &(elem(&1, 0) in [:playlists, :uploads]))
    pending = choose!(c.account, [@a, @b])
    assert poll(c.account, pending.revision).status == :ready
    result = snapshot(c.account)
    assert Enum.map(result.videos, & &1["id"]) == ["video000002", "video000003", "video000001"]
    assert Enum.all?(result.videos, &(&1["channel_id"] in [@a, @b]))
    assert hd(result.videos)["channel_title"] == "A <script>"
    refute Enum.any?(Provider.calls(), &match?({:uploads, _, "UUcccccccccccccccccccccc"}, &1))
    calls = Provider.calls()
    empty = choose!(c.account, [])
    assert empty.status == :empty && empty.videos == [] && empty.selected_ids == []
    assert Provider.calls() == calls
    assert snapshot(c.other).videos == []
  end

  test "pending work coalesces and duplicate completed delivery cannot fetch again", c do
    one = YouTube.prepare!(c.account.id, actor: @owner)
    two = YouTube.refresh!(c.account.id, actor: @owner)
    assert one.revision == two.revision
    assert length(all_enqueued(worker: PollWorker)) == 1
    poll(c.account, one.revision)
    calls = Provider.calls()
    assert poll(c.account, one.revision).skipped
    assert Provider.calls() == calls
  end

  test "durable worker publishes only its selected account and obsolete delivery stays inert",
       c do
    pending = selected(c.account, [@a])

    args = %{
      account_id: c.account.id,
      generation: c.account.generation,
      revision: pending.revision
    }

    assert :ok = perform_job(PollWorker, args)
    result = snapshot(c.account)
    assert result.status == :ready && !result.loading
    assert Enum.map(result.videos, & &1["id"]) == ["video000002", "video000001"]
    assert %DateTime{} = result.fetched_at
    assert snapshot(c.other).videos == []
    calls = Provider.calls()
    assert :ok = perform_job(PollWorker, args)
    assert Provider.calls() == calls
    assert snapshot(c.account).fetched_at == result.fetched_at

    {:ok, replacement} =
      Access.accept(
        c.workspace.id,
        %{subject: c.account.subject, email: c.account.email},
        :reuse_existing,
        :youtube,
        c.account.generation
      )

    assert :ok = perform_job(PollWorker, args)
    assert Provider.calls() == calls
    assert snapshot(replacement).videos == []
    assert state(replacement) == nil
  end

  test "disabled consent cannot be revived by refresh or an already open selection form", c do
    catalog(c.account)
    form = snapshot(c.account)

    Lovelace.Mail.update_account!(
      c.account,
      %{expected_generation: c.account.generation, youtube_enabled: false},
      actor: @owner
    )

    calls = Provider.calls()
    jobs = all_enqueued(worker: PollWorker)

    for action <- [&YouTube.prepare/2, &YouTube.refresh/2] do
      assert {:ok, view} = action.(c.account.id, actor: @owner)
      refute view.enabled
      assert view.videos == [] && !view.loading
    end

    assert {:error, _} =
             YouTube.select_channels(c.account.id, [@a], form.generation, form.revision,
               actor: @owner
             )

    assert Provider.calls() == calls
    assert all_enqueued(worker: PollWorker) == jobs
    assert snapshot(c.account).selected_ids == []
  end

  test "missing or malformed playlist mappings never publish a partial replacement feed", c do
    pending = selected(c.account, [@a, @b])
    poll(c.account, pending.revision)
    cached = snapshot(c.account)

    for response <- [
          {:ok, %{@a => "UUaaaaaaaaaaaaaaaaaaaaaa"}},
          {:ok, []},
          {:error, :insufficient_permissions}
        ] do
      Provider.change(%{playlists: response})
      previous_calls = Provider.calls()
      refresh = YouTube.refresh!(c.account.id, actor: @owner)
      result = poll(c.account, refresh.revision)
      assert result.status == :stale && !result.loading

      assert result.error ==
               if(response == {:error, :insufficient_permissions},
                 do: :reconnect,
                 else: :provider
               )

      assert result.videos == cached.videos && result.fetched_at == cached.fetched_at

      refute Enum.any?(
               Enum.drop(Provider.calls(), length(previous_calls)),
               &match?({:uploads, _, _}, &1)
             )
    end
  end

  test "bounded videos keep first duplicates and use stable IDs for equal instants" do
    first = %{"id" => "z", "published_at" => "2026-11-06T12:00:00.100000Z", "title" => "first"}

    rows = [
      first,
      %{"id" => "b", "published_at" => "2026-11-06T12:00:00.1Z"},
      %{"id" => "z", "published_at" => "2026-11-06T14:00:00Z", "title" => "duplicate"},
      %{"id" => "a", "published_at" => "2026-11-06T13:00:00.100+01:00"}
    ]

    assert [a, b, ^first] = Payload.bounded(rows)
    assert a["id"] == "a" && b["id"] == "b"
  end

  test "normal reads distinguish availability from consent and failed projections are unavailable",
       c do
    assert snapshot(c.account).available
    assert Snapshot.build(nil, nil).available
    failed = Snapshot.build(nil, nil, :unavailable)
    refute failed.available
    refute failed.enabled
    assert failed.status == :error && failed.error == :unavailable
    assert Enum.sort(Map.keys(failed)) == Enum.sort(Map.keys(snapshot(c.account)))
  end

  test "queue delay does not expire a durable request or its revision", c do
    pending = YouTube.prepare!(c.account.id, actor: @owner)
    old = DateTime.add(DateTime.utc_now(), -1800)
    store_state(c.account, %{requested_at: old, next_poll_at: DateTime.add(old, 900)})
    assert snapshot(c.account).loading
    assert YouTube.refresh!(c.account.id, actor: @owner).revision == pending.revision
    assert YouTube.sweep!(actor: @owner) == %{swept: true}
    assert state(c.account).revision == pending.revision
    assert state(c.account).started_at == nil
    assert poll(c.account, pending.revision).status == :empty
    assert DateTime.compare(state(c.account).started_at, old) == :gt
  end

  test "execution expiry prevents subsequent channel reads and sweep recovers promptly", c do
    expire_inflight(c.account, [@a, @b])
  end

  test "execution expiry fences publication after the final provider response", c do
    expire_inflight(c.account, [@a])
  end

  test "interrupted claims stop loading and recover without the fifteen-minute interval", c do
    pending = YouTube.prepare!(c.account.id, actor: @owner)
    current = store_state(c.account, %{started_at: DateTime.utc_now()})
    assert :ok = Oban.cancel_job(current.job_id)
    refute snapshot(c.account).loading
    assert snapshot(c.account).error == :unavailable
    assert YouTube.sweep!(actor: @owner) == %{swept: true}
    recovered = state(c.account)
    assert recovered.loading && recovered.revision != pending.revision
    assert recovered.started_at == nil
    assert Provider.calls() == []
  end

  test "sweep reports admission failures instead of claiming successful recovery", c do
    YouTube.prepare!(c.account.id, actor: @owner)
    store_state(c.account, %{loading: false, next_poll_at: DateTime.add(DateTime.utc_now(), -1)})

    SQL.query!(
      Lovelace.Repo,
      "CREATE TEMP TRIGGER reject_youtube_jobs BEFORE INSERT ON oban_jobs WHEN NEW.worker = 'Lovelace.YouTube.PollWorker' BEGIN SELECT RAISE(ABORT, 'synthetic admission rejection'); END",
      []
    )

    assert {:error, _} = YouTube.sweep(actor: @owner)
    SQL.query!(Lovelace.Repo, "DROP TRIGGER reject_youtube_jobs", [])
  end

  test "normal prepare honors fifteen-minute interval and sweep queues only due reads", c do
    catalog(c.account)
    original = state(c.account)
    assert DateTime.diff(original.next_poll_at, DateTime.utc_now()) in 895..900
    assert YouTube.prepare!(c.account.id, actor: @owner).revision == original.revision
    calls = Provider.calls()
    store_state(c.account, %{next_poll_at: DateTime.add(DateTime.utc_now(), -1)})
    assert :ok = perform_job(SweepWorker, %{})
    current = state(c.account)
    assert current.loading && current.revision != original.revision
    assert Provider.calls() == calls

    assert_enqueued(
      worker: PollWorker,
      args: %{
        account_id: c.account.id,
        generation: c.account.generation,
        revision: current.revision
      }
    )
  end

  test "ineligible accounts cannot starve interrupted ready reads at the sweep limit", c do
    YouTube.prepare!(c.account.id, actor: @owner)

    for reason <- [:not_ready, :disabled, :stale_generation] do
      older = DateTime.add(DateTime.utc_now(), -3600)

      for n <- 1..100 do
        account =
          Lovelace.Mail.save_connection!(
            %{
              subject: "sweep-#{reason}-#{n}",
              email: "sweep-#{reason}-#{n}@example.invalid",
              generation: Ash.UUID.generate(),
              youtube_enabled: reason != :disabled
            },
            actor: @owner
          )

        if reason == :not_ready do
          Lovelace.Mail.update_account!(
            account,
            %{expected_generation: account.generation, status: :reconnect},
            actor: @owner
          )
        end

        State
        |> Ash.Changeset.for_create(
          :store,
          %{
            account_id: account.id,
            generation:
              if(reason == :stale_generation, do: Ash.UUID.generate(), else: account.generation),
            revision: Ash.UUID.generate(),
            next_poll_at: older
          },
          actor: @owner
        )
        |> Ash.create!()
      end

      before = state(c.account)
      assert :ok = Oban.cancel_job(before.job_id)

      store_state(c.account, %{
        loading: true,
        started_at: DateTime.utc_now(),
        next_poll_at: DateTime.add(DateTime.utc_now(), 900)
      })

      calls = Provider.calls()
      assert :ok = perform_job(SweepWorker, %{})
      recovered = state(c.account)
      assert recovered.loading && recovered.revision != before.revision
      assert recovered.started_at == nil
      assert Provider.calls() == calls
      assert poll(c.account, recovered.revision).status == :empty
    end
  end

  test "shared reconnect health hides the feed but preserves YouTube reconnect guidance", c do
    pending = selected(c.account, [@a])
    poll(c.account, pending.revision)
    cached = state(c.account)
    assert snapshot(c.account).videos != []

    account =
      Lovelace.Mail.update_account!(
        c.account,
        %{expected_generation: c.account.generation, status: :reconnect},
        actor: @owner
      )

    view = snapshot(account)
    assert view.available
    refute view.enabled
    assert view.error == :reconnect
    assert view.videos == [] && view.channels == [] && view.selected_ids == []
    assert Snapshot.build(account, cached, :unavailable).error == :unavailable
    assert Snapshot.build(%{account | youtube_enabled: false}, cached).error == nil
  end

  test "shared Gmail cooldown blocks YouTube reads without overwriting Gmail health", c do
    Lovelace.Mail.update_account!(
      c.account,
      %{
        expected_generation: c.account.generation,
        last_error: :rate_limited,
        next_poll_at: DateTime.add(DateTime.utc_now(), 600)
      },
      actor: @owner
    )

    view = YouTube.prepare!(c.account.id, actor: @owner)
    assert view.error == :rate_limited && !view.loading
    refute_enqueued(worker: PollWorker)
    assert Provider.calls() == [] && Lovelace.TestMail.calls() == []
    assert Lovelace.Mail.get_account!(c.account.id, actor: @owner).last_error == :rate_limited
  end

  test "wrong service, obsolete generation and selection fail before provider access", c do
    pending = YouTube.prepare!(c.account.id, actor: @owner)

    assert {:error, _} =
             YouTube.poll(c.account.id, c.account.generation, pending.revision,
               actor: %{role: :mail_service, account_id: c.other.id}
             )

    assert YouTube.poll!(c.account.id, Ash.UUID.generate(), pending.revision, actor: @owner).skipped

    assert YouTube.poll!(c.account.id, c.account.generation, Ash.UUID.generate(), actor: @owner).skipped

    assert Provider.calls() == [] && Lovelace.TestMail.calls() == []
  end

  test "a delayed selection form cannot overwrite another revision or connection", c do
    catalog(c.account)
    form = snapshot(c.account)
    changed = choose!(c.account, [@a])

    assert {:error, _} =
             YouTube.select_channels(c.account.id, [@b], form.generation, form.revision,
               actor: @owner
             )

    assert state(c.account).revision == changed.revision

    {:ok, replacement} =
      Access.accept(
        c.workspace.id,
        %{subject: c.account.subject, email: c.account.email},
        :reuse_existing,
        :youtube,
        c.account.generation
      )

    catalog(replacement)

    assert {:error, _} =
             YouTube.select_channels(replacement.id, [@b], form.generation, form.revision,
               actor: @owner
             )

    assert state(replacement).selected_ids == []
  end

  test "in-flight selection results cannot publish or fetch another channel after change", c do
    pending = selected(c.account, [@a, @b])
    Provider.change(%{wait: self()})
    task = Task.async(fn -> poll(c.account, pending.revision) end)
    Sandbox.allow(Lovelace.Repo, self(), task.pid)
    assert_receive {:youtube_waiting, pid}, 2000
    replacement = choose!(c.account, [@c])
    calls = Provider.calls()
    send(pid, :continue)
    assert Task.await(task).skipped
    assert Provider.calls() == calls
    assert snapshot(c.account).videos == []
    assert state(c.account).revision == replacement.revision
  end

  test "in-flight generation results cannot contaminate a reconnected account", c do
    pending = selected(c.account, [@a])
    Provider.change(%{wait: self()})
    task = Task.async(fn -> poll(c.account, pending.revision) end)
    Sandbox.allow(Lovelace.Repo, self(), task.pid)
    assert_receive {:youtube_waiting, pid}, 2000

    {:ok, replacement} =
      Access.accept(
        c.workspace.id,
        %{subject: c.account.subject, email: c.account.email},
        :reuse_existing,
        :youtube,
        c.account.generation
      )

    send(pid, :continue)
    assert Task.await(task).skipped
    assert replacement.generation != c.account.generation
    assert state(replacement) == nil
    assert snapshot(replacement).videos == []
  end

  test "feed failure retains original observation while catalog has its own clock", c do
    pending = selected(c.account, [@a])
    poll(c.account, pending.revision)
    before = snapshot(c.account)
    old_catalog = DateTime.add(DateTime.utc_now(), -1000)
    store_state(c.account, %{catalog_at: old_catalog})
    Provider.change(%{videos: {:error, :provider}})
    pending = YouTube.refresh!(c.account.id, actor: @owner)
    assert poll(c.account, pending.revision).status == :stale
    after_failure = snapshot(c.account)
    assert after_failure.videos == before.videos && after_failure.fetched_at == before.fetched_at
    assert DateTime.compare(state(c.account).catalog_at, old_catalog) == :gt
    assert after_failure.error == :provider
    assert Lovelace.Mail.get_account!(c.account.id, actor: @owner).last_error == nil
  end

  test "catalog and feed TTL never expose expired provider payloads or admit stale selection",
       c do
    pending = selected(c.account, [@a])
    poll(c.account, pending.revision)
    expired = DateTime.add(DateTime.utc_now(), -86_401)
    store_state(c.account, %{catalog_at: expired})
    assert snapshot(c.account).channels == []
    assert snapshot(c.account).videos != []
    assert {:error, _} = choose(c.account, [@b])
    store_state(c.account, %{fetched_at: expired})
    assert snapshot(c.account).videos == [] && snapshot(c.account).fetched_at == nil
    assert :ok = perform_job(SweepWorker, %{})
    assert state(c.account).channels == [] && state(c.account).videos == []
    assert state(c.account).selected_ids == [@a]
  end

  test "quota cooldown survives new selection and is honored by manual refresh", c do
    pending = selected(c.account, [@a])
    Provider.change(%{videos: {:error, :rate_limited}})
    assert poll(c.account, pending.revision).error == :rate_limited
    deadline = state(c.account).cooldown_until
    assert DateTime.diff(deadline, DateTime.utc_now()) in 295..300
    calls = Provider.calls()
    revised = choose!(c.account, [@b])
    refute revised.loading
    YouTube.refresh!(c.account.id, actor: @owner)
    assert state(c.account).cooldown_until == deadline
    assert poll(c.account, revised.revision).skipped
    assert Provider.calls() == calls
  end

  test "catalog follows only two pages and preserves an explicitly selected absent bounded entry",
       c do
    pending = selected(c.account, [@a])
    poll(c.account, pending.revision)

    page_one =
      for n <- 1..50,
          do: %{
            "id" => "UC" <> String.pad_leading(Integer.to_string(n), 22, "0"),
            "title" => "Synthetic #{n}"
          }

    page_two =
      for n <- 51..100,
          do: %{
            "id" => "UC" <> String.pad_leading(Integer.to_string(n), 22, "0"),
            "title" => "Synthetic #{n}"
          }

    Provider.change(%{
      pages: %{
        nil => {:ok, %{channels: page_one, next_page: "two"}},
        "two" => {:ok, %{channels: page_two, next_page: "three"}}
      }
    })

    refresh = YouTube.refresh!(c.account.id, actor: @owner)
    result = poll(c.account, refresh.revision)
    assert length(result.channels) == 100 && result.truncated
    assert result.selected_ids == [@a] && result.videos != []
    assert {:ok, _} = choose(c.account, [@a])
    refute Enum.any?(Provider.calls(), &match?({:subscriptions, _, "three"}, &1))
  end

  test "selection limit, unknown IDs and malformed fake payloads are rejected", c do
    catalog(c.account)
    assert {:error, _} = choose(c.account, ["https://attacker.invalid"])
    assert {:error, _} = choose(c.account, ["UCdddddddddddddddddddddd"])
    assert {:error, _} = choose(c.account, List.duplicate(@a, 11))

    Provider.change(%{
      pages: %{
        nil => {:ok, %{channels: [%{"id" => "bad", "title" => "Untrusted"}], next_page: nil}}
      }
    })

    pending = YouTube.refresh!(c.account.id, actor: @owner)
    result = poll(c.account, pending.revision)
    assert result.error == :provider
    assert result.channels == c.channels
  end

  test "failed enqueue atomically rolls back both new state and durable intent", c do
    SQL.query!(
      Lovelace.Repo,
      "CREATE TEMP TRIGGER reject_youtube_jobs BEFORE INSERT ON oban_jobs WHEN NEW.worker = 'Lovelace.YouTube.PollWorker' BEGIN SELECT RAISE(ABORT, 'synthetic admission rejection'); END",
      []
    )

    assert {:error, _} = YouTube.prepare(c.account.id, actor: @owner)
    assert state(c.account) == nil
    refute_enqueued(worker: PollWorker)
    SQL.query!(Lovelace.Repo, "DROP TRIGGER reject_youtube_jobs", [])
  end

  test "provider video normalization rejects cross-channel, invalid text and impossible dates atomically",
       c do
    pending = selected(c.account, [@a, @b])
    assert poll(c.account, pending.revision).status == :ready
    cached = snapshot(c.account)
    [valid | _] = c.videos["UUaaaaaaaaaaaaaaaaaaaaaa"]

    for changes <- [
          %{"channel_id" => @b},
          %{"title" => <<"invalid UTF-8 ", 255>>},
          %{"title" => String.duplicate("x", 4097)},
          %{"published_at" => "2026-02-30T12:00:00Z"}
        ] do
      invalid = valid |> Map.put("id", "video000009") |> Map.merge(changes)
      videos = Map.put(c.videos, "UUaaaaaaaaaaaaaaaaaaaaaa", [valid, invalid])
      Provider.change(%{videos: videos})
      previous_calls = Provider.calls()
      refresh = YouTube.refresh!(c.account.id, actor: @owner)
      result = poll(c.account, refresh.revision)

      assert result.status == :stale && result.error == :provider
      refute result.loading
      assert result.videos == cached.videos
      assert result.fetched_at == cached.fetched_at
      assert result.selected_ids == [@a, @b]
      assert state(c.account).videos == cached.videos
      assert state(c.account).fetched_at == cached.fetched_at

      new_calls = Enum.drop(Provider.calls(), length(previous_calls))

      assert [{:uploads, _, "UUaaaaaaaaaaaaaaaaaaaaaa"}] =
               Enum.filter(new_calls, &match?({:uploads, _, _}, &1))
    end
  end

  test "successful provider rows normalize publication offsets and discard unexpected metadata",
       c do
    pending = selected(c.account, [@a])

    Provider.change(%{
      videos: %{
        "UUaaaaaaaaaaaaaaaaaaaaaa" => [
          %{
            "id" => "video000009",
            "title" => "Safe upload",
            "channel_id" => @a,
            "published_at" => "2026-11-06T14:00:00+02:00",
            "channel_title" => "Provider cannot override catalog title",
            "description" => "Private description",
            "thumbnail" => "https://attacker.invalid/private"
          }
        ]
      }
    })

    result = poll(c.account, pending.revision)
    assert result.status == :ready && result.error == nil

    assert result.videos == [
             %{
               "id" => "video000009",
               "title" => "Safe upload",
               "channel_id" => @a,
               "published_at" => "2026-11-06T12:00:00Z",
               "channel_title" => "A <script>"
             }
           ]

    assert state(c.account).videos == result.videos
    assert snapshot(c.account).videos == result.videos
  end

  test "malformed provider collections cannot erase a previously observed catalog or feed", c do
    pending = selected(c.account, [@a])
    poll(c.account, pending.revision)
    cached = snapshot(c.account)

    for page <- [
          %{},
          %{channels: nil, next_page: nil},
          %{channels: [nil], next_page: nil}
        ] do
      Provider.change(%{pages: %{nil => {:ok, page}}})
      refresh = YouTube.refresh!(c.account.id, actor: @owner)
      result = poll(c.account, refresh.revision)
      assert result.error == :provider && result.status == :stale
      assert result.channels == cached.channels && result.videos == cached.videos
      assert result.fetched_at == cached.fetched_at
    end

    Provider.change(%{pages: %{nil => {:ok, %{channels: c.channels, next_page: nil}}}})

    for rows <- [nil, [nil]] do
      Provider.change(%{videos: %{"UUaaaaaaaaaaaaaaaaaaaaaa" => rows}})
      refresh = YouTube.refresh!(c.account.id, actor: @owner)
      result = poll(c.account, refresh.revision)
      assert result.error == :provider && !result.loading
      assert result.videos == cached.videos && result.fetched_at == cached.fetched_at
    end
  end

  test "provider exceptions settle durable work without leaking details or inventing freshness",
       c do
    pending = selected(c.account, [@a])
    poll(c.account, pending.revision)
    cached = snapshot(c.account)

    for failure <- [:raise, :throw] do
      Provider.change(%{failure: failure})
      pending = YouTube.refresh!(c.account.id, actor: @owner)

      assert :ok =
               perform_job(PollWorker, %{
                 account_id: c.account.id,
                 generation: c.account.generation,
                 revision: pending.revision
               })

      result = snapshot(c.account)
      assert result.error == :provider && result.status == :stale && !result.loading
      assert result.videos == cached.videos && result.fetched_at == cached.fetched_at
    end
  end

  test "unavailable storage is not disabled consent and corrupt durable identity fails safely",
       c do
    catalog(c.account)
    calls = Provider.calls()

    SQL.query!(
      Lovelace.Repo,
      "ALTER TABLE youtube_states RENAME TO unavailable_youtube_states",
      []
    )

    try do
      assert {:ok, result} = YouTube.snapshot(c.account.id, actor: @owner)
      refute result.available
      assert result.error == :unavailable && result.status == :error
      assert result.channels == [] && result.videos == []
      assert {:error, _} = YouTube.refresh(c.account.id, actor: @owner)
    after
      SQL.query!(
        Lovelace.Repo,
        "ALTER TABLE unavailable_youtube_states RENAME TO youtube_states",
        []
      )
    end

    assert {:error, :youtube_unavailable} =
             perform_job(PollWorker, %{
               account_id: "not-an-account-uuid",
               generation: c.account.generation,
               revision: Ash.UUID.generate()
             })

    assert snapshot(c.account).channels == c.channels
    assert Provider.calls() == calls
  end
end
