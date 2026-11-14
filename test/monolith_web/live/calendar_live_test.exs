defmodule MonolithWeb.CalendarLiveTest do
  use MonolithWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Monolith.TestSupport.BackgroundWork, only: [complete: 1]
  alias Ash.Resource.Info
  alias Ecto.Adapters.SQL
  alias Monolith.{Calendar, Mail, Workspaces}
  alias Monolith.Calendar.State
  alias Monolith.Integrations.Google.ClientCredentials
  alias Monolith.TestSupport.OnboardingKeychain
  alias MonolithWeb.CalendarComponents
  @owner %{role: :local_owner}

  defmodule FakeIO do
    @moduledoc false
    @behaviour Monolith.Calendar.Provider
    def get(id), do: {:ok, "synthetic:" <> id}
    def refresh(token), do: {:ok, %{access_token: token}}

    @impl true
    def calendars(token) do
      send(Application.fetch_env!(:monolith, :calendar_live_owner), {:calendar_provider, token})

      case Application.fetch_env!(:monolith, :calendar_live_response) do
        :ok ->
          {:ok,
           %{
             calendars: [%{id: "primary", name: "Synthetic shared calendar", selected: true}],
             truncated: false
           }}

        response ->
          response
      end
    end

    @impl true
    def events(token, "primary", _from, _to) do
      day = Date.utc_today()

      events =
        case Application.fetch_env!(:monolith, :calendar_live_events) do
          :default ->
            [
              %{
                id: "same-event",
                title: "<img src='https://calendar-fixture.invalid/image'> " <> token,
                start: Date.to_iso8601(day),
                end: Date.to_iso8601(Date.add(day, 1)),
                all_day: true,
                url: "https://calendar.google.com/calendar/event?eid=synthetic"
              }
            ]

          events ->
            events
        end

      {:ok, %{events: events, truncated: false}}
    end
  end

  setup %{conn: conn} do
    start_supervised!(OnboardingKeychain)

    for {key, value} <- [
          gmail_provider: FakeIO,
          gmail_vault: FakeIO,
          calendar_provider: FakeIO,
          google_client_keychain: OnboardingKeychain,
          calendar_live_owner: self(),
          calendar_live_response: :ok,
          calendar_live_events: :default
        ] do
      previous = Application.fetch_env(:monolith, key)
      Application.put_env(:monolith, key, value)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:monolith, key, value)
          :error -> Application.delete_env(:monolith, key)
        end
      end)
    end

    :ok = ClientCredentials.save("synthetic-calendar-client", "synthetic-calendar-secret")

    a = account("a", true)
    b = account("b", true)
    disabled = account("disabled", false)
    workspace = Workspaces.create_workspace!("Calendar studio", actor: @owner)
    Mail.attach_account!(%{workspace_id: workspace.id, account_id: a.id}, actor: @owner)
    day = Date.utc_today()

    window = %{
      "from" => DateTime.new!(day, ~T[00:00:00]) |> DateTime.to_iso8601(),
      "to" => DateTime.new!(Date.add(day, 1), ~T[00:00:00]) |> DateTime.to_iso8601(),
      "date" => Date.to_iso8601(day),
      "timezone" => "UTC"
    }

    %{
      conn: authenticate_owner(conn),
      a: a,
      b: b,
      disabled: disabled,
      workspace: workspace,
      window: window
    }
  end

  test "failed account directory reads remain distinct from confirmed absence", ctx do
    socket = MonolithWeb.HomeCalendar.init(%Phoenix.LiveView.Socket{})
    ready = MonolithWeb.HomeCalendar.reload(socket)
    assert ready.assigns.calendar_accounts_state == :ready
    assert Enum.any?(ready.assigns.calendar_accounts, &(&1.id == ctx.a.id))

    # Fail the actual capability read inside this test's disposable sandbox.
    SQL.query!(
      Monolith.Repo,
      "ALTER TABLE gmail_accounts RENAME TO calendar_directory_unavailable"
    )

    failed =
      try do
        assert {:error, _} = Mail.list_accounts(actor: @owner)
        failed = MonolithWeb.HomeCalendar.reload(ready)
        first_failed = MonolithWeb.HomeCalendar.reload(socket)
        assert first_failed.assigns.calendar_accounts == []
        assert first_failed.assigns.calendar_accounts_state == :unavailable
        assert failed.assigns.calendar_accounts == ready.assigns.calendar_accounts
        failed
      after
        SQL.query!(
          Monolith.Repo,
          "ALTER TABLE calendar_directory_unavailable RENAME TO gmail_accounts"
        )
      end

    assert failed.assigns.calendar_accounts_state == :unavailable
    assert_directory_unavailable(failed)

    for account <- [ctx.a, ctx.b, ctx.disabled] do
      Mail.update_account!(
        account,
        %{status: :disconnected, expected_generation: account.generation},
        actor: @owner
      )
    end

    empty = MonolithWeb.HomeCalendar.reload(failed)
    assert empty.assigns.calendar_accounts == []
    assert empty.assigns.calendar_accounts_state == :ready

    agenda =
      render_component(&CalendarComponents.agenda/1,
        accounts: empty.assigns.calendar_accounts,
        accounts_state: empty.assigns.calendar_accounts_state
      )

    connections =
      render_component(&CalendarComponents.connections/1,
        accounts: empty.assigns.calendar_accounts,
        accounts_state: empty.assigns.calendar_accounts_state,
        workspace_options: [],
        google_status: :stored
      )

    agenda = LazyHTML.from_document(agenda)
    connections = LazyHTML.from_document(connections)

    assert Enum.any?(LazyHTML.query(agenda, ".calendar-empty a[data-phx-link='patch']"))

    assert Enum.any?(
             LazyHTML.query(connections, "a[href='/connections/gmail'][data-phx-link='patch']")
           )

    assert Enum.empty?(LazyHTML.query(agenda, "#calendar-agenda-directory-status"))
    assert Enum.empty?(LazyHTML.query(connections, "#calendar-connections-directory-status"))
  end

  test "day preparation is provider-free, Home stays per-account and events never enter socket assigns",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    render_hook(view, "calendar:day", ctx.window)
    refute_receive {:calendar_provider, _}
    assert has_element?(view, "#calendar-agenda-account-#{ctx.a.id}", "Updating Calendar")
    refute has_element?(view, "#calendar-agenda-account-#{ctx.disabled.id}")
    poll(ctx.a, ctx.window)
    poll(ctx.b, ctx.window)
    send(view.pid, {:calendar_changed, ctx.a.id})
    html = render(view)
    assert has_element?(view, "#calendar-agenda-account-#{ctx.a.id}", "synthetic:#{ctx.a.id}")
    refute has_element?(view, "#calendar-agenda-account-#{ctx.a.id}", "synthetic:#{ctx.b.id}")
    assert has_element?(view, "#calendar-agenda-account-#{ctx.b.id}", "synthetic:#{ctx.b.id}")

    assert has_element?(
             view,
             "#calendar-agenda-account-#{ctx.a.id} button[data-calendar-event-open]" <>
               "[data-event-account='#{ctx.a.email}'][aria-controls='calendar-agenda-event-dialog']"
           )

    refute has_element?(
             view,
             "#calendar-agenda-account-#{ctx.a.id} button[data-event-account='#{ctx.b.email}']"
           )

    assert has_element?(
             view,
             "#calendar-agenda-event-dialog[aria-labelledby='calendar-agenda-event-title']"
           )

    assert has_element?(
             view,
             "#calendar-agenda-event-dialog form[method='dialog'] button",
             "Close event"
           )

    assert has_element?(view, "#calendar-agenda-event-dialog [data-calendar-dialog-link][hidden]")
    refute has_element?(view, "#calendar-agenda img")
    refute has_element?(view, "#calendar-agenda button[phx-click='calendar:refresh']")
    refute has_element?(view, "#calendar-agenda", "Last checked")
    assert has_element?(view, "#calendar-agenda [data-warnings-only=true]")
    assert html =~ "&lt;img"
    refute inspect(:sys.get_state(view.pid).socket.assigns) =~ "calendar-fixture.invalid"
    assert Mail.list_workspace_accounts!(actor: @owner) |> length() == 1
  end

  test "workspace agenda includes attached accounts only and scenery/navigation does not change membership",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    render_hook(view, "calendar:day", ctx.window)
    poll(ctx.a, ctx.window)
    poll(ctx.b, ctx.window)
    view |> element("#show-workspaces") |> render_click()
    render_click(view, "open_workspace", %{"id" => ctx.workspace.id})
    assert has_element?(view, "#calendar-agenda-account-#{ctx.a.id}")
    assert has_element?(view, "#calendar-agenda button[phx-click='calendar:refresh']", "Refresh")
    assert has_element?(view, "#calendar-agenda [data-warnings-only=false]")
    refute has_element?(view, "#calendar-agenda-account-#{ctx.b.id}")
    view |> element("#home-link") |> render_click()
    assert has_element?(view, "#calendar-agenda-account-#{ctx.b.id}")
    refute has_element?(view, "#calendar-agenda button[phx-click='calendar:refresh']")
    assert Mail.list_workspace_accounts!(actor: @owner) |> length() == 1
  end

  test "Calendar Connections is exclusive, optional consent is POST and clearing all selections is valid",
       ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    render_hook(view, "calendar:day", ctx.window)
    poll(ctx.a, ctx.window)
    view |> element("#show-connections") |> render_click()
    view |> element("#open-connection-calendar") |> render_click()
    complete(view)
    assert has_element?(view, "#calendar-connections")
    refute has_element?(view, "#connections-panel, #gemini-connection")

    assert has_element?(
             view,
             "#calendar-connections-authorize-#{ctx.disabled.id}[method=post][action='/oauth/google/start']"
           )

    assert has_element?(
             view,
             "#calendar-connections-authorize-#{ctx.disabled.id} input[name=capability][value=calendar]"
           )

    view
    |> form("#calendar-connections-select-#{ctx.a.id}", %{"calendar_ids" => [""]})
    |> render_submit()

    assert {:ok, snapshot} =
             Calendar.snapshot(ctx.a.id, ctx.window["from"], ctx.window["to"], ctx.window["date"],
               actor: @owner
             )

    assert snapshot.explicit_selection
    assert snapshot.selected_ids == []

    view
    |> element(
      "#calendar-connections-disconnect-help a[href='/connections/gmail'][data-phx-link=patch]"
    )
    |> render_click()

    assert has_element?(view, "#connections-panel")
    refute has_element?(view, "#calendar-connections")
  end

  test "a late displayed Calendar form cannot change a refreshed connection", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/connections/calendar")
    render_hook(view, "calendar:day", ctx.window)
    poll(ctx.a, ctx.window)
    complete(view)

    [displayed_generation] =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#calendar-connections-select-#{ctx.a.id} input[name=generation]")
      |> LazyHTML.attribute("value")

    assert displayed_generation == ctx.a.generation

    current =
      Monolith.Google.Access.serial(ctx.a.id, fn ->
        Mail.update_account!(
          ctx.a,
          %{generation: Ash.UUID.generate(), expected_generation: ctx.a.generation},
          actor: @owner
        )
      end)

    poll(current, ctx.window)
    before = snapshot(current, ctx.window)
    assert before.selected_ids == ["primary"]
    assert before.events != []

    for ids <- [["primary"], [""]] do
      render_submit(view, "calendar:select", %{
        "account_id" => ctx.a.id,
        "generation" => displayed_generation,
        "calendar_ids" => ids
      })

      assert snapshot(current, ctx.window) == before
    end
  end

  test "unavailable Google settings disable Calendar changes without hiding cached data", ctx do
    for failure <- [:not_found, :locked, :unavailable] do
      poll(ctx.a, ctx.window)
      OnboardingKeychain.fail(failure)
      {:ok, view, _} = live(ctx.conn, ~p"/connections/calendar")
      render_hook(view, "calendar:day", ctx.window)
      complete(view)

      assert has_element?(
               view,
               "#calendar-connections-google-prerequisite a[href='/connections/google']"
             )

      assert has_element?(
               view,
               "#calendar-connections-authorize-#{ctx.disabled.id} button[disabled]"
             )

      assert has_element?(view, "#calendar-connections-workspace-#{ctx.disabled.id}[disabled]")
      assert has_element?(view, "#calendar-connections-select-#{ctx.a.id} fieldset[disabled]")

      assert has_element?(
               view,
               "#calendar-connections-account-#{ctx.a.id} button[phx-click='calendar:refresh'][disabled]"
             )

      assert has_element?(
               view,
               "#calendar-connections-select-#{ctx.a.id} input[value=primary][checked]"
             )

      assert {:ok, before} =
               Calendar.snapshot(
                 ctx.a.id,
                 ctx.window["from"],
                 ctx.window["to"],
                 ctx.window["date"],
                 actor: @owner
               )

      render_submit(view, "calendar:select", %{
        "account_id" => ctx.a.id,
        "generation" => ctx.a.generation,
        "calendar_ids" => [""]
      })

      render_click(view, "calendar:refresh", %{"id" => ctx.a.id})

      assert {:ok, ^before} =
               Calendar.snapshot(
                 ctx.a.id,
                 ctx.window["from"],
                 ctx.window["to"],
                 ctx.window["date"],
                 actor: @owner
               )

      OnboardingKeychain.fail(nil)
      view |> element("#calendar-connections-google-prerequisite a") |> render_click()
      complete(view)
      view |> element("#connections-calendar") |> render_click()
      complete(view)
      refute has_element?(view, "#calendar-connections-select-#{ctx.a.id} fieldset[disabled]")

      refute has_element?(
               view,
               "#calendar-connections-authorize-#{ctx.disabled.id} button[disabled]"
             )

      view
      |> form("#calendar-connections-select-#{ctx.a.id}", %{"calendar_ids" => [""]})
      |> render_submit()

      assert {:ok, after_selection} =
               Calendar.snapshot(
                 ctx.a.id,
                 ctx.window["from"],
                 ctx.window["to"],
                 ctx.window["date"],
                 actor: @owner
               )

      assert after_selection.explicit_selection
      assert after_selection.selected_ids == []

      Calendar.select_calendars(ctx.a.id, ctx.a.generation, ["primary"], actor: @owner)
      GenServer.stop(view.pid)
    end
  end

  test "waiting and stale local agendas do not claim a successful empty day", ctx do
    html = agenda(ctx.a, ctx.window)
    assert html =~ "Waiting for today"
    refute html =~ "No events today"
    refute html =~ "No calendars selected"
    refute_receive {:calendar_provider, _}

    poll(ctx.a, ctx.window)
    assert_receive {:calendar_provider, _}
    observed_at = DateTime.add(DateTime.utc_now(), -181)
    update_state(ctx.a, %{fetched_at: observed_at})

    html = agenda(ctx.a, ctx.window)
    assert html =~ "Showing a previous local copy"
    assert html =~ "synthetic:#{ctx.a.id}"
    assert html =~ "Last checked"
    assert html =~ ~s(data-failed="true")
    assert html =~ ~s(data-observed-at="#{DateTime.to_iso8601(observed_at)}")
    refute html =~ "No events today"
    refute_receive {:calendar_provider, _}
  end

  test "Home keeps the empty-day heading without the workspace explanation", ctx do
    Application.put_env(:monolith, :calendar_live_events, [])
    poll(ctx.a, ctx.window)
    window = Map.new(ctx.window, fn {key, value} -> {String.to_existing_atom(key), value} end)

    home =
      render_component(&CalendarComponents.agenda/1,
        accounts: [ctx.a],
        window: window,
        home: true
      )
      |> LazyHTML.from_fragment()

    workspace = agenda(ctx.a, ctx.window) |> LazyHTML.from_fragment()
    selector = "#calendar-agenda-account-#{ctx.a.id} .calendar-message"

    assert [_] = LazyHTML.query(home, selector <> " .empty-state-title") |> Enum.to_list()
    assert [] == LazyHTML.query(home, selector <> " .empty-state-copy") |> Enum.to_list()
    assert [_] = LazyHTML.query(workspace, selector <> " .empty-state-copy") |> Enum.to_list()
  end

  test "failed first updates are warnings, never successful empty agendas", ctx do
    for {reason, warning} <- [
          keychain: "Credential store unavailable. Check Connections.",
          rate_limited: "Google is rate limiting Calendar updates; polling will wait.",
          unavailable:
            "Calendar update unavailable. Any displayed events are a previous local copy.",
          insufficient_permissions: "Calendar authorization needs reconnecting."
        ] do
      account = account("uncached-#{reason}", true)
      Application.put_env(:monolith, :calendar_live_response, {:error, reason})
      poll(account, ctx.window)
      assert_receive {:calendar_provider, _}

      html = agenda(account, ctx.window)
      assert html =~ warning
      refute html =~ "No events today"
      refute html =~ "No calendars selected"
      refute html =~ "Last checked"
      refute html =~ ~s(class="calendar-event")
      refute html =~ "Updating Calendar"
      refute_receive {:calendar_provider, _}
    end
  end

  test "cached rows and their observation survive failed Calendar updates", ctx do
    for {reason, warning} <- [
          keychain: "Credential store unavailable. Check Connections.",
          rate_limited: "Google is rate limiting Calendar updates; polling will wait.",
          provider:
            "Calendar update unavailable. Any displayed events are a previous local copy.",
          insufficient_permissions: "Calendar authorization needs reconnecting."
        ] do
      account = account("cached-#{reason}", true)
      Application.put_env(:monolith, :calendar_live_response, :ok)
      poll(account, ctx.window)
      assert_receive {:calendar_provider, _}
      before = snapshot(account, ctx.window)

      Application.put_env(:monolith, :calendar_live_response, {:error, reason})
      assert {:ok, _} = Calendar.refresh(account.id, actor: @owner)
      poll(account, ctx.window)
      assert_receive {:calendar_provider, _}

      after_failure = snapshot(account, ctx.window)
      assert after_failure.events == before.events
      assert after_failure.fetched_at == before.fetched_at
      assert after_failure.stale

      html = agenda(account, ctx.window)
      assert html =~ warning
      assert html =~ "synthetic:#{account.id}"
      assert html =~ ~s(data-failed="true")
      assert html =~ ~s(data-observed-at="#{DateTime.to_iso8601(before.fetched_at)}")
      refute html =~ "No events today"
      refute html =~ "No calendars selected"
      refute_receive {:calendar_provider, _}
    end
  end

  test "Calendar-only reconnect keeps Gmail ready and offers Calendar consent", ctx do
    poll(ctx.a, ctx.window)
    assert_receive {:calendar_provider, _}
    Application.put_env(:monolith, :calendar_live_response, {:error, :insufficient_permissions})
    assert {:ok, _} = Calendar.refresh(ctx.a.id, actor: @owner)
    poll(ctx.a, ctx.window)
    assert_receive {:calendar_provider, _}

    [account] =
      Monolith.Mail.Account
      |> Ash.Query.for_read(:scoped, %{account_id: ctx.a.id}, actor: @owner)
      |> Ash.read!()

    assert account.status == :ready
    assert account.last_error == nil
    html = agenda(account, ctx.window)
    assert html =~ "Authorize Calendar again in Connections"
    assert html =~ ~s(href="/connections/calendar")

    {:ok, view, _} = live(ctx.conn, ~p"/connections/calendar")
    render_hook(view, "calendar:day", ctx.window)
    complete(view)

    assert has_element?(
             view,
             "#calendar-connections-account-#{ctx.a.id}",
             "Authorize Calendar again"
           )

    assert has_element?(
             view,
             "#calendar-connections-authorize-#{ctx.a.id} input[name=capability][value=calendar]"
           )

    assert has_element?(
             view,
             "#calendar-connections-authorize-#{ctx.a.id} input[name=expected_account_id][value='#{ctx.a.id}']"
           )

    refute_receive {:calendar_provider, _}
  end

  test "a shared Google reconnect cannot look like a successful empty Calendar", ctx do
    account =
      Mail.update_account!(
        ctx.a,
        %{status: :reconnect, expected_generation: ctx.a.generation},
        actor: @owner
      )

    html = agenda(account, ctx.window)
    assert html =~ "Calendar authorization needs reconnecting."
    assert html =~ "Authorize Calendar again in Connections"
    refute html =~ "Updating Calendar"
    refute html =~ "No events today"
    refute html =~ "No calendars selected"
    refute html =~ "Calendar is not connected"
    refute_receive {:calendar_provider, _}
  end

  test "untrusted event content stays text and only safe Calendar links are offered", ctx do
    day = Date.utc_today()
    tomorrow = Date.add(day, 1)
    title = "<script>alert(\"calendar\")</script> & private"

    event = %{
      id: "all-day",
      title: title,
      start: Date.to_iso8601(day),
      end: Date.to_iso8601(tomorrow),
      all_day: true,
      url: "https://calendar.google.com/calendar/event?eid=safe"
    }

    unsafe_urls = [
      "javascript:alert(1)",
      "http://calendar.google.com/calendar/event",
      "https://calendar.google.com.evil.invalid/calendar/event",
      "https://calendar.google.com@evil.invalid/calendar/event",
      "https://calendar.google.com/not-calendar",
      nil
    ]

    unsafe_events =
      Enum.with_index(unsafe_urls, fn url, index ->
        %{event | id: "unsafe-#{index}", title: "", url: url}
      end)

    timed = %{
      event
      | id: "timed",
        title: "Timed event",
        start: ctx.window["from"],
        end: ctx.window["to"],
        all_day: false,
        url: "https://www.google.com/calendar/event?eid=timed"
    }

    malformed = %{event | id: "invalid-date", title: "Invalid date event", start: "not-a-date"}

    Application.put_env(:monolith, :calendar_live_events, [
      event,
      timed,
      malformed | unsafe_events
    ])

    poll(ctx.a, ctx.window)
    assert_receive {:calendar_provider, _}

    html = agenda(ctx.a, ctx.window)
    document = LazyHTML.from_fragment(html)
    assert Enum.count(LazyHTML.query(document, ".calendar-event")) == 8
    assert Enum.empty?(LazyHTML.query(document, "script, img"))
    assert LazyHTML.query(document, ".calendar-event-title") |> LazyHTML.text() =~ title
    assert html =~ "&lt;script&gt;"
    assert html =~ "(Untitled event)"
    refute html =~ "Invalid date event"

    links = LazyHTML.query(document, ".calendar-event-link")

    assert LazyHTML.attribute(links, "href") == [
             "https://calendar.google.com/calendar/event?eid=safe",
             "https://www.google.com/calendar/event?eid=timed"
           ]

    assert LazyHTML.attribute(links, "target") == ["_blank", "_blank"]
    assert LazyHTML.attribute(links, "rel") == ["noopener noreferrer", "noopener noreferrer"]
    assert LazyHTML.attribute(links, "referrerpolicy") == ["no-referrer", "no-referrer"]

    all_day = LazyHTML.query(document, ~s([data-all-day="true"]))
    assert Enum.count(all_day) == 7
    assert Enum.uniq(LazyHTML.attribute(all_day, "data-start")) == [Date.to_iso8601(day)]
    assert Enum.uniq(LazyHTML.attribute(all_day, "data-end")) == [Date.to_iso8601(tomorrow)]
    assert LazyHTML.text(all_day) =~ "All day"
    timed = LazyHTML.query(document, ~s([data-all-day="false"]))
    assert LazyHTML.attribute(timed, "data-start") == [ctx.window["from"]]
    assert LazyHTML.attribute(timed, "data-end") == [ctx.window["to"]]
    assert html =~ "Local time loading"
    refute_receive {:calendar_provider, _}
  end

  test "invalid browser contexts are ignored without provider calls", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/")
    render_hook(view, "calendar:day", %{ctx.window | "to" => ctx.window["from"]})
    refute_receive {:calendar_provider, _}
    assert :sys.get_state(view.pid).socket.assigns.calendar_window == nil
  end

  defp assert_directory_unavailable(socket) do
    for {component, id, extra} <- [
          {&CalendarComponents.agenda/1, "calendar-agenda", []},
          {&CalendarComponents.connections/1, "calendar-connections",
           [workspace_options: [], google_status: :stored]}
        ] do
      html =
        render_component(
          component,
          [
            accounts: socket.assigns.calendar_accounts,
            accounts_state: socket.assigns.calendar_accounts_state
          ] ++ extra
        )

      html = LazyHTML.from_document(html)

      assert Enum.any?(LazyHTML.query(html, "##{id}-directory-status[role='status']"))

      assert Enum.any?(
               LazyHTML.query(html, "##{id}-directory-status a[href='/connections/calendar']")
             )

      assert Enum.empty?(LazyHTML.query(html, ".calendar-empty"))
      assert Enum.empty?(LazyHTML.query(html, ".calendar-account"))
      assert Enum.empty?(LazyHTML.query(html, "a[href='/connections/gmail']"))
    end
  end

  defp agenda(account, window) do
    render_component(&CalendarComponents.agenda/1,
      accounts: [account],
      window: %{
        from: window["from"],
        to: window["to"],
        date: window["date"],
        timezone: window["timezone"]
      }
    )
  end

  defp snapshot(account, window) do
    Calendar.snapshot!(account.id, window["from"], window["to"], window["date"], actor: @owner)
  end

  defp update_state(account, changes) do
    state =
      State
      |> Ash.Query.for_read(:read, %{account_id: account.id}, actor: @owner)
      |> Ash.read_one!()

    attributes =
      state
      |> Map.from_struct()
      |> Map.take(Info.action(State, :store).accept)
      |> Map.merge(changes)

    State
    |> Ash.Changeset.for_create(:store, attributes, actor: @owner)
    |> Ash.create!()
  end

  defp poll(account, window) do
    {:ok, %{revision: revision}} =
      Calendar.prepare(
        account.id,
        window["from"],
        window["to"],
        window["date"],
        window["timezone"],
        actor: @owner
      )

    assert {:ok, _} = Calendar.poll(account.id, account.generation, revision, actor: @owner)
  end

  defp account(label, enabled) do
    Mail.save_connection!(
      %{
        id: Ash.UUID.generate(),
        subject: "calendar-live-" <> label,
        email: label <> "@example.test",
        generation: Ash.UUID.generate(),
        calendar_enabled: enabled
      },
      actor: @owner
    )
  end
end
