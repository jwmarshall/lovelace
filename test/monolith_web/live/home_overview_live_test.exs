defmodule MonolithWeb.HomeOverviewLiveTest do
  use MonolithWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Monolith.Integrations.Google.ClientCredentials
  alias Monolith.Mail
  alias Monolith.Mail.Operations
  alias Monolith.TestSupport.BackgroundWork
  alias Monolith.Workspaces

  @owner %{role: :local_owner}

  defmodule Vault do
    @moduledoc false
    def get(id), do: {:ok, "synthetic-" <> id}
  end

  defmodule Provider do
    @moduledoc false
    @spec refresh(binary()) :: {:ok, Monolith.Google.OAuthProvider.tokens()}
    def refresh(token), do: {:ok, %{access_token: token, expires_in: 3600}}

    @spec inbox(binary(), Monolith.Mail.Provider.page_token()) ::
            {:ok, Monolith.Mail.Provider.page()}
    def inbox(token, _page) do
      send(Application.fetch_env!(:monolith, :home_test_owner), {:home_fetch, token})
      {:ok, %{threads: [], next_page_token: nil}}
    end

    @spec inbox_unread(binary()) :: {:ok, Monolith.Mail.Provider.unread()} | {:error, :timeout}
    def inbox_unread(_token), do: Application.fetch_env!(:monolith, :home_test_unread)
  end

  setup %{conn: conn} do
    start_supervised!(Monolith.TestSupport.OnboardingKeychain)

    for {key, value} <- [
          gmail_provider: Provider,
          gmail_vault: Vault,
          home_test_owner: self(),
          home_test_unread: {:ok, %{total: 0, recent: 0}},
          google_client_keychain: Monolith.TestSupport.OnboardingKeychain
        ] do
      previous = Application.fetch_env(:monolith, key)
      Application.put_env(:monolith, key, value)

      on_exit(fn ->
        case previous do
          {:ok, previous} -> Application.put_env(:monolith, key, previous)
          :error -> Application.delete_env(:monolith, key)
        end
      end)
    end

    {:ok, conn: authenticate_owner(conn)}
  end

  test "Gmail setup resolves workspace and Google prerequisites before offering account consent",
       %{
         conn: conn
       } do
    {:ok, view, _html} = live(conn, ~p"/connections/gmail")
    refute has_element?(view, "#new-gmail-connection, #mail-connect-new")

    view |> element("#connections-panel a[href='/workspaces']") |> render_click()
    assert_patch(view, "/workspaces")
    view |> element("#new-workspace") |> render_click()
    view |> form("#workspace-form", workspace: %{name: "Studio"}) |> render_submit()
    [workspace] = Workspaces.list_workspaces!(actor: @owner)
    refute has_element?(view, "#workspaces-empty")

    view |> element("#show-connections") |> render_click()
    view |> element("#open-connection-gmail") |> render_click()
    BackgroundWork.complete(view)
    assert has_element?(view, "#new-gmail-connection[disabled]")
    render_click(view, "mail:new_connection")
    refute has_element?(view, "#gmail-connection-modal")

    :ok =
      ClientCredentials.save(
        "synthetic-empty-google-client",
        "synthetic-empty-google-secret"
      )

    view |> element("#gmail-google-prerequisite a") |> render_click()
    BackgroundWork.complete(view)
    view |> element("#connections-gmail") |> render_click()
    BackgroundWork.complete(view)
    assert has_element?(view, "#new-gmail-connection:not([disabled])")
    view |> element("#new-gmail-connection") |> render_click()

    assert has_element?(
             view,
             "#gmail-connection-modal #mail-workspace-new option[value='#{workspace.id}']"
           )

    assert Mail.list_accounts!(actor: @owner) == []
  end

  test "Home shows account-specific unread metrics from metadata, with workspace labels", %{
    conn: conn
  } do
    first = account("first", 12, 3)
    second = account("second", 0, 0)
    orphan = account("orphan", nil)
    shared = Workspaces.create_workspace!("Shared", actor: @owner)
    personal = Workspaces.create_workspace!("Personal", actor: @owner)

    for workspace <- [shared, personal] do
      Mail.attach_account!(%{workspace_id: workspace.id, account_id: first.id}, actor: @owner)
    end

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(
             view,
             "#product-sidebar #home-link[aria-current=page]",
             "Home"
           )

    assert has_element?(view, ".workspace-directory-home #home-readouts > #home-overview")
    assert has_element?(view, "#home-readouts > #calendar-agenda")

    assert has_element?(
             view,
             "#home-account-#{first.id} .home-account-workspaces",
             "Personal · Shared"
           )

    assert has_element?(view, "#home-count-#{first.id}", "12")
    assert has_element?(view, "#home-count-#{first.id} .home-count-recent", "3")
    assert has_element?(view, "#home-count-#{second.id}", "0")
    assert has_element?(view, "#home-count-#{second.id} .home-count-recent", "0")
    assert has_element?(view, "#home-count-#{orphan.id} .home-count b", "—")
    assert has_element?(view, "#home-count-#{orphan.id} .sr-only", "Total unavailable")
    assert has_element?(view, "#home-count-#{orphan.id} .home-count-recent b", "—")
    assert has_element?(view, "#home-count-#{orphan.id} .sr-only", "Last 24 hours unavailable")
    assert has_element?(view, "#home-account-#{orphan.id}", "Not in a workspace")
    refute has_element?(view, "#home-overview a", "Open account inbox")
    refute has_element?(view, "#home-overview [phx-hook='ObservationTime']")

    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query(".home-account")
           |> Enum.count() == 3

    refute has_element?(view, "#workspace-list, #mail-search, #mail-threads")
    refute_receive {:home_fetch, _}
  end

  test "Home opens an unattached account inbox without attaching it, and navigation returns Home",
       %{conn: conn} do
    account = account("unattached", 7)
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#open-home-account-#{account.id}") |> render_click()
    BackgroundWork.complete(view)
    assert_receive {:home_fetch, token}
    assert token == "synthetic-" <> account.id
    assert has_element?(view, "#home-inbox .mail-inbox-heading #mail-heading", account.email)
    assert has_element?(view, ".mail-inbox-heading #mail-search input[aria-label='Search Gmail']")
    assert has_element?(view, "#mail-search button[type=submit]", "Search")
    refute has_element?(view, "#mail-panel button", "Home")
    refute has_element?(view, "#mail-panel a", "All accounts")
    assert has_element?(view, "#mail-threads", "Your inbox is empty")
    assert Mail.list_workspace_accounts!(actor: @owner) == []

    view |> element("#home-link") |> render_click()
    assert_push_event(view, "workspace:focus-heading", %{})
    assert has_element?(view, "#home-overview")
    refute has_element?(view, "#mail-account-view")
    refute_receive {:home_fetch, _}
  end

  test "count updates stay account-scoped and retain visible error context", %{conn: conn} do
    first = account("first", 8, 2)
    second = account("second", 19, 5)
    {:ok, view, _html} = live(conn, ~p"/")

    Mail.update_account!(
      first,
      %{expected_generation: first.generation, inbox_unread_error: :rate_limited},
      actor: @owner
    )

    Operations.broadcast(first.id)
    assert has_element?(view, "#home-count-#{first.id}", "8")
    assert has_element?(view, "#home-count-#{first.id} .home-count-recent", "2")
    refute has_element?(view, "#home-health-#{first.id} .connection-warning")
    assert has_element?(view, "#home-count-#{second.id}", "19")
    assert has_element?(view, "#home-count-#{second.id} .home-count-recent", "5")
    refute_receive {:home_fetch, _}
  end

  test "workspace readouts catch up on entry and follow account-scoped poll counts and errors", %{
    conn: conn
  } do
    first = account("workspace-first", 8, 2)
    second = account("workspace-second", 19, 5)
    workspace = Workspaces.create_workspace!("Polling", actor: @owner)

    for account <- [first, second] do
      Mail.attach_account!(%{workspace_id: workspace.id, account_id: account.id}, actor: @owner)
    end

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#show-settings") |> render_click()

    Application.put_env(:monolith, :home_test_unread, {:ok, %{total: 23, recent: 7}})
    assert %{error: nil} = poll(first)
    assert_receive {:home_fetch, token}
    assert token == "synthetic-" <> first.id

    render_patch(view, ~p"/workspaces/#{workspace.id}")
    assert has_element?(view, "#home-count-#{first.id} .sr-only", "23 total")
    assert has_element?(view, "#home-count-#{first.id} .home-count-recent b", "7")
    refute has_element?(view, ".mail-workspace-readout [phx-hook='ObservationTime']")
    refute has_element?(view, ".mail-workspace-readout a", "Open account inbox")

    Application.put_env(:monolith, :home_test_unread, {:ok, %{total: 31, recent: 9}})
    assert %{error: nil} = poll(first)
    assert_receive {:home_fetch, ^token}
    assert has_element?(view, "#home-count-#{first.id} .sr-only", "31 total")
    assert has_element?(view, "#home-count-#{first.id} .home-count-recent b", "9")
    assert has_element?(view, "#home-count-#{second.id} .sr-only", "19 total")
    assert has_element?(view, "#home-count-#{second.id} .home-count-recent b", "5")

    observed_at =
      first.id |> Mail.get_account!(actor: @owner) |> Map.fetch!(:inbox_unread_at)

    Application.put_env(:monolith, :home_test_unread, {:error, :timeout})
    assert %{error: :unavailable} = poll(first)
    assert_receive {:home_fetch, ^token}
    assert has_element?(view, "#home-count-#{first.id} .sr-only", "31 total")
    assert has_element?(view, "#home-count-#{first.id} .home-count-recent b", "9")
    assert has_element?(view, "#home-health-#{first.id}", "Update failed")

    assert Mail.get_account!(first.id, actor: @owner).inbox_unread_at == observed_at
    refute has_element?(view, "#home-health-#{second.id}", "Update failed")

    Application.put_env(:monolith, :home_test_unread, {:ok, %{total: 0, recent: 0}})
    assert %{error: nil} = poll(first)
    assert_receive {:home_fetch, ^token}
    assert has_element?(view, "#home-count-#{first.id} .sr-only", "0 total")
    assert has_element?(view, "#home-count-#{first.id} .home-count-recent b", "0")
    refute has_element?(view, "#home-health-#{first.id}", "Update failed")
    refute_receive {:home_fetch, _}
  end

  test "workspace reconnect clears the previous generation's counts, errors and observation", %{
    conn: conn
  } do
    account = account("workspace-reconnect", 41, 6)
    other = account("workspace-current", 19, 5)
    workspace = Workspaces.create_workspace!("Reconnect", actor: @owner)

    for account <- [account, other] do
      Mail.attach_account!(%{workspace_id: workspace.id, account_id: account.id}, actor: @owner)
    end

    Mail.update_account!(
      account,
      %{
        expected_generation: account.generation,
        status: :reconnect,
        last_error: :reconnect,
        inbox_unread_error: :reconnect
      },
      actor: @owner
    )

    {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}")
    assert has_element?(view, "#home-count-#{account.id} .sr-only", "41 total")
    assert has_element?(view, "#home-count-#{account.id} .home-count-recent b", "6")
    assert has_element?(view, "#home-health-#{account.id}", "Reconnect required")

    reconnected =
      Mail.save_connection!(
        %{
          id: account.id,
          subject: account.subject,
          email: account.email,
          generation: Ash.UUID.generate()
        },
        actor: @owner
      )

    Operations.broadcast(account.id)
    assert has_element?(view, "#home-count-#{account.id} .sr-only", "Total unavailable")

    assert has_element?(
             view,
             "#home-count-#{account.id} .sr-only",
             "Last 24 hours unavailable"
           )

    refute has_element?(view, "#home-health-#{account.id}", "Reconnect required")
    assert has_element?(view, "#home-unknown-#{account.id}", "No unread count observation")
    assert has_element?(view, "#home-count-#{other.id} .sr-only", "19 total")
    assert has_element?(view, "#home-count-#{other.id} .home-count-recent b", "5")

    assert %{skipped: true} = poll(account)
    Operations.broadcast(account.id)
    assert has_element?(view, "#home-count-#{account.id} .sr-only", "Total unavailable")
    refute_receive {:home_fetch, _}

    assert %{error: nil} = poll(reconnected)
    assert_receive {:home_fetch, token}
    assert token == "synthetic-" <> account.id
    assert has_element?(view, "#home-count-#{account.id} .sr-only", "0 total")
    assert has_element?(view, "#home-count-#{account.id} .home-count-recent b", "0")
    refute_receive {:home_fetch, _}
  end

  test "workspace removal and global disconnect remove their rendered observations", %{conn: conn} do
    account = account("workspace-removed", 71, 7)
    workspace = Workspaces.create_workspace!("First", actor: @owner)
    other = Workspaces.create_workspace!("Second", actor: @owner)

    for workspace <- [workspace, other] do
      Mail.attach_account!(%{workspace_id: workspace.id, account_id: account.id}, actor: @owner)
    end

    {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace.id}")
    assert has_element?(view, "#home-count-#{account.id} .sr-only", "71 total")

    assert Mail.unlink!(workspace.id, account.id, actor: @owner)
    refute has_element?(view, "#mail-account-#{account.id}")
    refute has_element?(view, "#home-count-#{account.id}, #home-health-#{account.id}")

    render_patch(view, ~p"/workspaces/#{other.id}")
    assert has_element?(view, "#home-count-#{account.id} .sr-only", "71 total")

    Mail.disconnect!(account.id, actor: @owner)
    refute has_element?(view, "#mail-account-#{account.id}")
    refute has_element?(view, "#home-count-#{account.id}, #home-health-#{account.id}")

    render_patch(view, ~p"/")
    assert has_element?(view, "#home-empty")
    refute has_element?(view, "#home-account-#{account.id}")
    refute_receive {:home_fetch, _}
  end

  test "unrelated account updates never request the selected Home inbox", %{conn: conn} do
    first = account("first", 2)
    second = account("second", 3)
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#open-home-account-#{first.id}") |> render_click()
    BackgroundWork.complete(view)
    assert_receive {:home_fetch, _}

    Operations.broadcast(second.id)
    assert has_element?(view, "#mail-heading", first.email)
    refute_receive {:home_fetch, _}

    view |> element("#home-link") |> render_click()
    view |> element("#open-home-account-#{second.id}") |> render_click()
    BackgroundWork.complete(view)
    assert_receive {:home_fetch, token}
    assert token == "synthetic-" <> second.id
    assert has_element?(view, "#mail-heading", second.email)
  end

  test "reconnect and removed accounts remain truthful and forged IDs do not open mail", %{
    conn: conn
  } do
    account = account("reconnect", nil)

    Mail.update_account!(
      account,
      %{expected_generation: account.generation, status: :reconnect, last_error: :reconnect},
      actor: @owner
    )

    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#home-health-#{account.id} .connection-warning")
    assert has_element?(view, "#home-count-#{account.id} .sr-only", "Total unavailable")
    assert has_element?(view, "#home-health-#{account.id} .home-recovery", "Connections")

    render_click(view, "open_home_account", %{"id" => Ash.UUID.generate()})
    refute has_element?(view, "#mail-account-view")
    assert has_element?(view, "#flash-error", "unavailable")

    view |> element("#open-home-account-#{account.id}") |> render_click()
    BackgroundWork.complete(view)

    assert has_element?(
             view,
             "#home-inbox a[href='/connections/gmail'][data-phx-link=patch]",
             "Reconnect in Connections"
           )

    refute_receive {:home_fetch, _}

    view |> element("#home-link") |> render_click()
    current = Mail.get_account!(account.id, actor: @owner)

    Mail.update_account!(
      current,
      %{expected_generation: current.generation, status: :disconnected},
      actor: @owner
    )

    Operations.broadcast(account.id)
    assert has_element?(view, "#home-empty")
    refute has_element?(view, "#home-account-#{account.id}")
  end

  test "empty Home offers real connection destinations and retains Home navigation", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(
             view,
             "#home-empty a[href='/connections/gmail'][data-phx-link=patch]",
             "Connect Gmail"
           )

    assert has_element?(
             view,
             "#calendar-agenda .calendar-empty a[href='/connections/calendar'][data-phx-link=patch]",
             "Set up Calendar"
           )

    view |> element("#show-connections") |> render_click()
    refute has_element?(view, "#back-from-connections")
    assert has_element?(view, "#product-sidebar #home-link[href='/']", "Home")
    view |> element("#home-link") |> render_click()
    assert has_element?(view, "#home-overview")
  end

  test "workspace navigation is explicit and reload returns Home", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#show-workspaces") |> render_click()
    assert has_element?(view, "#workspace-list")
    assert has_element?(view, "#show-workspaces[aria-current=page]")
    refute has_element?(view, "#home-overview")
    {:ok, reloaded, _html} = live(conn, ~p"/")
    assert has_element?(reloaded, "#home-overview")
    refute has_element?(reloaded, "#workspace-list")
  end

  test "reconnect retains its last known unread count and observation", %{conn: conn} do
    account = account("stale-reconnect", 9)

    Mail.update_account!(
      account,
      %{expected_generation: account.generation, status: :reconnect, last_error: :reconnect},
      actor: @owner
    )

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#home-count-#{account.id} .home-count b", "9")
    refute has_element?(view, "#home-health-#{account.id} .connection-warning")

    assert has_element?(
             view,
             "#home-health-#{account.id} a[href='/connections/gmail'][data-phx-link=patch]",
             "Connections"
           )

    refute_receive {:home_fetch, _}
  end

  defp poll(account),
    do:
      Mail.poll!(account.id, account.generation,
        actor: %{role: :mail_service, account_id: account.id}
      )

  defp account(name, count, recent_count \\ nil) do
    account =
      Mail.save_connection!(
        %{
          id: Ash.UUID.generate(),
          subject: "home-" <> name,
          email: name <> "@example.test",
          generation: Ash.UUID.generate()
        },
        actor: @owner
      )

    Mail.update_account!(
      account,
      %{
        expected_generation: account.generation,
        inbox_unread_count: count,
        inbox_unread_recent_count: recent_count,
        inbox_unread_at: if(is_integer(count), do: DateTime.utc_now(), else: nil)
      },
      actor: @owner
    )
  end
end
