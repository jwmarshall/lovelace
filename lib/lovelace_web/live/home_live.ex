defmodule LovelaceWeb.HomeLive do
  @moduledoc "The local owner's daily orientation, workspaces and separate Gmail accounts."
  use LovelaceWeb, :live_view

  alias Lovelace.Mail.ConnectionDiagnostics
  alias Lovelace.Workspaces
  alias Lovelace.Workspaces.Workspace

  alias LovelaceWeb.{
    CalendarComponents,
    GeminiComponents,
    GitHubComponents,
    GoogleComponents,
    HomeCalendar,
    HomeComponents,
    HomeGemini,
    HomeGitHub,
    HomeGoogle,
    HomeMail,
    HomeNavigation,
    HomeScenes,
    HomeYouTube,
    MailComponents,
    SceneComponents,
    WorkspaceComponents,
    YouTubeComponents
  }

  # Capability minted only behind the HTTP and LiveView owner-session boundaries.
  @owner %{role: :local_owner}

  @impl true
  def mount(params, session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Lovelace.PubSub, "stage_designer")

    background =
      case Lovelace.StageDesigner.background() do
        {:ok, background} -> background
        {:error, _reason} -> %{url: nil, status: :unavailable}
      end

    socket =
      socket
      |> assign(
        page_title: "Home",
        enter_on_return: session["workspace_return"] == true,
        navigation_ready: false,
        navigation_path: nil,
        home_accounts: [],
        home_error: false,
        onboarding_pending: Lovelace.Onboarding.pending?(),
        background: background,
        selected: nil,
        workspace_options: [],
        workspace_health: %{},
        directory_subscriptions: [],
        editor: nil,
        form: nil,
        form_failed: false,
        workspaces_error: false,
        loading: not connected?(socket),
        save_status: ""
      )
      |> stream(:workspaces, [])
      |> HomeNavigation.put(:index)
      |> HomeMail.init()
      |> HomeCalendar.init()
      |> HomeGemini.init()
      |> HomeGoogle.init()
      |> HomeGitHub.init(session)
      |> HomeScenes.init()
      |> HomeYouTube.init()

    socket = if connected?(socket), do: load_workspaces(socket), else: socket
    socket = resume_connection(socket, params)
    {:ok, socket}
  end

  @impl true
  def handle_info({:stage_background, %{url: _url, status: _status} = background}, socket) do
    socket = assign(socket, :background, background)
    {:noreply, if(socket.assigns.scenes, do: HomeScenes.refresh(socket), else: socket)}
  end

  def handle_info({:mail_changed, id} = message, socket) do
    socket = HomeCalendar.reload(socket)

    if id in socket.assigns.directory_subscriptions do
      {:noreply, load_workspaces(socket)}
    else
      reconcile_mail_navigation(socket, HomeMail.handle_info(message, socket))
    end
  end

  def handle_info({:calendar_changed, id}, socket) do
    if id in socket.assigns.directory_subscriptions || id in socket.assigns.mail.subscriptions do
      {:noreply, HomeCalendar.changed(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:youtube_changed, _id} = message, socket),
    do: {:noreply, HomeYouTube.handle_info(message, socket)}

  def handle_info({:google_changed, _id} = message, socket),
    do: {:noreply, HomeYouTube.handle_info(message, socket)}

  def handle_info({:youtube_observe, _token, _attempt} = message, socket),
    do: {:noreply, HomeYouTube.handle_info(message, socket)}

  def handle_info(:github_tick, socket), do: github_changed(:github_tick, socket)

  def handle_info(:github_auth_tick, socket),
    do: HomeGitHub.handle_info(:github_auth_tick, socket)

  def handle_info(:github_directory_changed, socket),
    do: github_changed(:github_directory_changed, socket)

  def handle_info({:github_changed, _id} = message, socket),
    do: github_changed(message, socket)

  def handle_info({:mail_operation, _id} = message, socket),
    do: reconcile_mail_navigation(socket, HomeMail.handle_info(message, socket))

  def handle_info({:mail_observe, _id, _attempt} = message, socket),
    do: reconcile_mail_navigation(socket, HomeMail.handle_info(message, socket))

  def handle_info({:connection_diagnostic, :google, _id} = message, socket),
    do: HomeGoogle.handle_info(message, socket)

  def handle_info({:connection_diagnostic, :gemini, _id} = message, socket),
    do: HomeGemini.handle_info(message, socket)

  def handle_info({:connection_diagnostic, :github, _id} = message, socket),
    do: HomeGitHub.handle_info(message, socket)

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event(name, params, socket) do
    {:noreply, socket} = event(name, params, socket)
    socket = socket |> accept_event_destination(name) |> HomeYouTube.sync()
    path = HomeNavigation.current(socket)

    {:noreply,
     if(path == socket.assigns.navigation_path, do: socket, else: push_patch(socket, to: path))}
  end

  defp event("youtube:" <> _ = event, params, socket),
    do: HomeYouTube.handle_event(event, params, socket)

  defp event("github:" <> _ = event, params, socket),
    do: HomeGitHub.handle_event(event, params, socket)

  defp event("calendar:" <> _ = event, params, socket),
    do: HomeCalendar.handle_event(event, params, socket)

  defp event("mail:accounts", _params, %{assigns: %{mail: %{scope: :home}}} = socket),
    do: event("show_home", %{}, socket)

  defp event("mail:search", %{"mail_search" => %{"query" => query}} = params, socket)
       when is_binary(query) do
    case HomeNavigation.destination(:inbox, %{"q" => String.trim(query)}) do
      {:ok, _} -> HomeMail.handle_event("mail:search", params, socket)
      _ -> {:noreply, put_flash(socket, :error, "This search is invalid. Try a shorter search.")}
    end
  end

  defp event("mail:" <> _ = event, params, socket),
    do: HomeMail.handle_event(event, params, socket)

  defp event("scenes:" <> _ = event, params, %{assigns: %{scenes: true}} = socket),
    do: HomeScenes.handle_event(event, params, socket)

  defp event("scenes:" <> _, _params, socket), do: {:noreply, socket}

  defp event("show_scenes", _params, socket) do
    {:noreply,
     socket
     |> HomeNavigation.put(:scenes)
     |> HomeMail.leave_workspace()
     |> directory_subscriptions([])
     |> assign(
       selected: nil,
       editor: nil,
       form: nil,
       page_title: "Scenes"
     )
     |> HomeScenes.open()
     |> focus_heading()}
  end

  defp event("show_settings", _params, socket) do
    {:noreply,
     socket
     |> HomeNavigation.put(:settings)
     |> HomeScenes.leave()
     |> HomeMail.leave_workspace()
     |> directory_subscriptions([])
     |> assign(
       selected: nil,
       editor: nil,
       form: nil,
       page_title: "Settings"
     )
     |> focus_heading()}
  end

  defp event("show_home", _params, socket) do
    {:noreply,
     socket
     |> HomeNavigation.put(:index)
     |> HomeScenes.leave()
     |> HomeMail.leave_workspace()
     |> assign(
       scene_confirmation: false,
       selected: nil,
       editor: nil,
       form: nil,
       page_title: "Home"
     )
     |> load_workspaces()
     |> focus_heading()}
  end

  defp event("open_home_account", %{"id" => id}, socket) do
    socket = load_workspaces(socket)

    if Enum.any?(socket.assigns.home_accounts, &(&1.id == id)) do
      {:noreply,
       socket
       |> HomeScenes.leave()
       |> HomeNavigation.put(:inbox, %{"account_id" => id})
       |> directory_subscriptions([])
       |> assign(
         scene_confirmation: false,
         selected: nil,
         editor: nil,
         form: nil,
         page_title: "Inbox"
       )
       |> HomeMail.open_home_account(id)
       |> focus_heading()}
    else
      {:noreply, put_flash(socket, :error, "This account is unavailable. Check Connections.")}
    end
  end

  defp event(
         "google:check",
         _params,
         %{assigns: %{connections: true, connection_view: :google}} = socket
       ),
       do: {:noreply, HomeGoogle.open(socket)}

  defp event("google:check", _params, socket), do: {:noreply, socket}

  defp event(
         "gemini:check",
         _params,
         %{assigns: %{connections: true, connection_view: :gemini}} = socket
       ),
       do: {:noreply, HomeGemini.open(socket)}

  defp event("gemini:check", _params, socket), do: {:noreply, socket}

  defp event(
         "select_connection",
         %{"provider" => provider},
         %{assigns: %{connections: true}} = socket
       )
       when provider in ["google", "gemini", "gmail", "calendar", "github", "youtube"] do
    view =
      Map.fetch!(
        %{
          "google" => :google,
          "gemini" => :gemini,
          "gmail" => :gmail,
          "calendar" => :calendar,
          "github" => :github,
          "youtube" => :youtube
        },
        provider
      )

    if view == socket.assigns.connection_view do
      {:noreply, socket}
    else
      socket =
        if socket.assigns.connection_view == :index, do: focus_heading(socket), else: socket

      socket =
        socket
        |> HomeMail.close_connection()
        |> HomeNavigation.put(:connection, %{"provider" => provider})

      socket =
        case view do
          view when view in [:google, :gmail, :calendar, :youtube] -> HomeGoogle.open(socket)
          :gemini -> HomeGemini.open(socket)
          :github -> HomeGitHub.open(socket)
        end

      socket = if view == :youtube, do: HomeYouTube.connections(socket), else: socket
      {:noreply, socket}
    end
  end

  defp event("select_connection", _params, socket), do: {:noreply, socket}

  defp event(
         "show_connections",
         _params,
         %{assigns: %{connections: true, connection_view: :index}} = socket
       ),
       do: {:noreply, socket}

  defp event("show_connections", _params, socket) do
    {:noreply,
     socket
     |> HomeNavigation.put(:connections)
     |> HomeScenes.leave()
     |> directory_subscriptions([])
     |> assign(
       selected: nil,
       scene_confirmation: false,
       editor: nil,
       form: nil,
       page_title: "Connections"
     )
     |> HomeMail.open_connections()
     |> focus_heading()}
  end

  defp event("retry_workspaces", _params, socket) do
    {:noreply, load_workspaces(socket)}
  end

  defp event("new_workspace", _params, socket) do
    form =
      Workspace
      |> AshPhoenix.Form.for_create(:create, as: "workspace", actor: @owner)
      |> to_form()

    {:noreply, assign(socket, editor: :new, form: form, form_failed: false, save_status: "")}
  end

  defp event("rename_workspace", %{"id" => id}, socket) do
    case Workspaces.get_workspace(id, actor: @owner) do
      {:ok, %Workspace{} = workspace} ->
        form =
          workspace
          |> AshPhoenix.Form.for_update(:rename, as: "workspace", actor: @owner)
          |> to_form()

        {:noreply,
         assign(socket, editor: :rename, form: form, form_failed: false, save_status: "")}

      _ ->
        {:noreply, put_flash(socket, :error, "This workspace is unavailable. Try again.")}
    end
  end

  defp event("cancel_workspace", _params, socket) do
    {:noreply, assign(socket, editor: nil, form: nil)}
  end

  defp event("validate_workspace", %{"workspace" => params}, socket) do
    if socket.assigns.form do
      form = AshPhoenix.Form.validate(socket.assigns.form, params)
      {:noreply, assign(socket, form: to_form(form), form_failed: false)}
    else
      {:noreply, socket}
    end
  end

  defp event("save_workspace", %{"workspace" => params}, socket) do
    if socket.assigns.form do
      save_workspace(socket, params)
    else
      {:noreply, socket}
    end
  end

  defp event("open_workspace", %{"id" => id}, socket) do
    case Workspaces.get_workspace(id, actor: @owner) do
      {:ok, %Workspace{} = workspace} ->
        {:noreply,
         socket
         |> HomeNavigation.put(:workspace, %{"workspace_id" => workspace.id})
         |> HomeScenes.leave()
         |> directory_subscriptions([])
         |> assign(
           selected: workspace,
           scene_confirmation: false,
           editor: nil,
           form: nil,
           page_title: workspace.name
         )
         |> HomeMail.open_workspace(workspace)
         |> focus_heading()}

      _ ->
        {:noreply, put_flash(socket, :error, "This workspace is unavailable. Try again.")}
    end
  end

  defp event("show_workspaces", _params, socket) do
    {:noreply,
     socket
     |> HomeNavigation.put(:workspaces)
     |> HomeScenes.leave()
     |> HomeMail.leave_workspace()
     |> assign(
       scene_confirmation: false,
       selected: nil,
       editor: nil,
       form: nil,
       page_title: "Workspaces"
     )
     |> load_workspaces()
     |> focus_heading()}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {:noreply, if(connected?(socket), do: navigate_params(socket, params, uri), else: socket)}
  end

  defp navigate_params(socket, params, uri) do
    %{path: path, query: query} = URI.parse(uri)
    path = if query, do: path <> "?" <> query, else: path

    socket =
      if socket.assigns.navigation_ready && HomeNavigation.current(socket) == path,
        do: socket,
        else: visit(socket, params)

    canonical = HomeNavigation.current(socket)

    socket =
      socket |> HomeYouTube.sync() |> assign(navigation_ready: true, navigation_path: canonical)

    if path == canonical, do: socket, else: push_patch(socket, to: canonical, replace: true)
  end

  # Account removal can arrive through PubSub or a delayed completion. Leave the
  # invalid route completely, rather than keeping an account-shaped empty shell.
  defp reconcile_mail_navigation(previous, {:noreply, socket}) do
    if previous.assigns.mail.account_id && is_nil(socket.assigns.mail.account_id) do
      socket =
        unavailable_destination(
          socket,
          "This account is no longer available in this view. Check Connections."
        )

      {:noreply, push_patch(socket, to: HomeNavigation.current(socket), replace: true)}
    else
      {:noreply, socket}
    end
  end

  defp visit(socket, params) do
    case HomeNavigation.destination(socket.assigns.live_action, params) do
      {:ok, destination} -> visit_destination(socket, destination)
      _ -> unavailable_destination(socket, "This link is invalid. Choose a view from navigation.")
    end
  end

  defp visit_destination(socket, %{action: :index}), do: transition(socket, "show_home")

  defp visit_destination(socket, %{action: :workspaces}),
    do: transition(socket, "show_workspaces")

  defp visit_destination(socket, %{action: :settings}),
    do: transition(socket, "show_settings")

  defp visit_destination(socket, %{action: :connections}),
    do: transition(socket, "show_connections")

  defp visit_destination(socket, %{action: :connection, provider: provider}) do
    socket =
      if socket.assigns.connections, do: socket, else: transition(socket, "show_connections")

    transition(socket, "select_connection", %{"provider" => to_string(provider)})
  end

  defp visit_destination(socket, %{action: action} = destination)
       when action in [:youtube, :youtube_video] do
    socket =
      socket
      |> HomeScenes.leave()
      |> HomeMail.leave_workspace()
      |> directory_subscriptions([])
      |> HomeNavigation.put(destination)
      |> assign(selected: nil, editor: nil, form: nil, page_title: "YouTube")

    case HomeYouTube.navigate(socket, destination) do
      {:ok, socket} ->
        focus_heading(socket)

      {:error, socket} ->
        socket
        |> transition("show_home")
        |> put_flash(
          :error,
          "This account or video is not available in the selected YouTube feed."
        )
    end
  end

  defp visit_destination(
         socket,
         %{action: :scenes, page: page, attempt_page: attempt_page} = destination
       ) do
    socket = if socket.assigns.scenes, do: socket, else: transition(socket, "show_scenes")

    socket =
      if socket.assigns.scene_page == page && socket.assigns.scene_attempt_page == attempt_page,
        do: socket,
        else:
          socket
          |> assign(scene_page: page, scene_attempt_page: attempt_page)
          |> HomeScenes.refresh()

    HomeNavigation.put(socket, destination)
  end

  defp visit_destination(socket, %{action: action} = destination)
       when action in [:workspace, :integration_add, :workspace_inbox, :workspace_thread] do
    socket = select_workspace(socket, destination.workspace_id)

    if socket.assigns.selected && socket.assigns.selected.id == destination.workspace_id do
      visit_workspace(socket, destination)
    else
      unavailable_destination(socket, "This workspace is unavailable. Choose another workspace.")
    end
  end

  defp visit_destination(socket, %{action: action} = destination)
       when action in [:inbox, :thread] do
    socket =
      if socket.assigns.mail.scope == :home do
        socket
      else
        socket
        |> HomeScenes.leave()
        |> HomeNavigation.put(destination)
        |> directory_subscriptions([])
        |> assign(
          selected: nil,
          editor: nil,
          form: nil,
          page_title: "Inbox"
        )
        |> HomeMail.open_home()
        |> focus_heading()
      end

    visit_mail(socket, destination)
  end

  defp visit_workspace(socket, destination) do
    socket =
      if socket.assigns.connections ||
           (socket.assigns.mail.account_id && is_nil(destination.account_id)),
         do: transition(socket, "open_workspace", %{"id" => destination.workspace_id}),
         else: socket

    cond do
      destination.account_id -> visit_mail(socket, destination)
      destination.action == :integration_add -> transition(socket, "mail:add")
      socket.assigns.mail.adding -> transition(socket, "mail:close_add")
      true -> socket
    end
  end

  defp visit_mail(socket, destination) do
    socket = HomeMail.navigate(socket, destination)

    if socket.assigns.mail.account_id == destination.account_id,
      do: HomeNavigation.put(socket, destination),
      else:
        unavailable_destination(
          socket,
          "This account is unavailable in this view. Check Connections."
        )
  end

  defp select_workspace(socket, id) do
    if socket.assigns.selected && socket.assigns.selected.id == id,
      do: socket,
      else: transition(socket, "open_workspace", %{"id" => id})
  end

  defp unavailable_destination(socket, message) do
    socket |> transition("show_workspaces") |> put_flash(:error, message)
  end

  defp transition(socket, name, params \\ %{}) do
    {:noreply, socket} = event(name, params, socket)
    accept_event_destination(socket, name)
  end

  defp accept_event_destination(socket, "mail:" <> _) do
    if socket.assigns.destination.action in [:inbox, :thread, :workspace_inbox, :workspace_thread] &&
         is_nil(socket.assigns.mail.account_id) do
      unavailable_destination(
        socket,
        "This account is no longer available in this view. Check Connections."
      )
    else
      case HomeNavigation.from_mail(socket) do
        {:ok, socket} ->
          socket

        :error ->
          unavailable_destination(socket, "This link is invalid. Choose a view from navigation.")
      end
    end
  end

  defp accept_event_destination(socket, name)
       when name in ["scenes:page", "scenes:attempt-page"] do
    if socket.assigns.destination.action == :scenes do
      HomeNavigation.put(socket, :scenes, %{
        "page" => to_string(socket.assigns.scene_page),
        "attempt_page" => to_string(socket.assigns.scene_attempt_page)
      })
    else
      socket
    end
  end

  defp accept_event_destination(socket, _name), do: socket

  defp save_workspace(socket, params) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, workspace} ->
        selected = socket.assigns.selected
        selected = if selected && selected.id == workspace.id, do: workspace, else: selected

        {:noreply,
         socket
         |> assign(
           selected: selected,
           editor: nil,
           form: nil,
           page_title: if(selected, do: selected.name, else: "Workspaces"),
           save_status: "Workspace saved."
         )
         |> load_workspaces()}

      {:error, form} ->
        {:noreply, assign(socket, form: to_form(form), form_failed: true)}
    end
  end

  defp github_changed(message, socket) do
    {:noreply, socket} = HomeGitHub.handle_info(message, socket)

    directory? = HomeNavigation.directory?(socket.assigns.destination)

    {:noreply, if(directory?, do: load_workspaces(socket), else: socket)}
  end

  defp load_workspaces(socket) do
    case Lovelace.Home.summary(actor: @owner) do
      {:ok, summary} ->
        workspaces = summary.workspaces

        ids =
          if HomeNavigation.directory?(socket.assigns.destination),
            do: summary.subscription_ids,
            else: []

        socket
        |> assign(
          workspaces_error: false,
          loading: false,
          workspace_options: Enum.map(workspaces, &{&1.name, &1.id}),
          workspace_health: summary.workspace_health,
          home_accounts: summary.accounts,
          home_error: summary.accounts_error?
        )
        |> HomeGitHub.reload()
        |> HomeCalendar.reload()
        |> HomeYouTube.reload_accounts()
        |> directory_subscriptions(ids)
        |> stream(:workspaces, workspaces, reset: true)

      _ ->
        socket
        |> assign(
          workspaces_error: true,
          home_error: true,
          workspace_health: %{},
          home_accounts: [],
          loading: false
        )
        |> directory_subscriptions([])
    end
  end

  defp directory_subscriptions(socket, ids) do
    old = socket.assigns.directory_subscriptions

    if connected?(socket) do
      Enum.each(old -- ids, &Phoenix.PubSub.unsubscribe(Lovelace.PubSub, "mail:#{&1}"))
      Enum.each(ids -- old, &Phoenix.PubSub.subscribe(Lovelace.PubSub, "mail:#{&1}"))
    end

    assign(socket, :directory_subscriptions, ids)
  end

  defp resume_connection(socket, params) do
    socket =
      case params["gmail"] do
        "connected" ->
          put_flash(socket, :info, "Gmail connected. Mail access is read-only.")

        "failed" ->
          put_flash(
            socket,
            :error,
            ConnectionDiagnostics.message(params["stage"], params["reason"])
          )

        _ ->
          socket
      end

    socket
    |> resume_youtube(params)
    |> resume_calendar(params)
    |> resume_gemini(params)
    |> resume_google(params)
    |> HomeGitHub.resume(params)
  end

  defp resume_calendar(socket, %{"calendar" => "connected"}) do
    socket
    |> put_flash(:info, "Calendar connected. Event access is read-only.")
    |> HomeCalendar.reload()
  end

  defp resume_calendar(socket, _params), do: socket

  defp resume_youtube(socket, %{"youtube" => "connected"}),
    do:
      put_flash(
        socket,
        :info,
        "YouTube connected, read-only. Choose channels in this account’s subscriptions page."
      )

  defp resume_youtube(socket, %{"youtube" => "failed"}),
    do:
      put_flash(
        socket,
        :error,
        "YouTube authorization was not completed. Existing Gmail and Calendar access is unchanged."
      )

  defp resume_youtube(socket, _), do: socket

  defp resume_gemini(socket, params) do
    if connected?(socket) && (params["connections"] == "gemini" || params["provider"] == "gemini") do
      message =
        case params["gemini"] do
          "saved" ->
            {:info, "Gemini API key saved in Keychain. No generation was started."}

          "removed" ->
            {:info, "Gemini API key removed. Existing scenery is unchanged."}

          "failed" ->
            {:error,
             "Gemini key could not be updated. Check the key format and Keychain access, then try again."}

          _ ->
            nil
        end

      if message, do: put_flash(socket, elem(message, 0), elem(message, 1)), else: socket
    else
      socket
    end
  end

  defp resume_google(socket, %{"provider" => "google", "google" => result})
       when result in ["saved", "failed"] do
    if connected?(socket) do
      case result do
        "saved" ->
          put_flash(socket, :info, "Google client settings saved. No account access was granted.")

        "failed" ->
          put_flash(
            socket,
            :error,
            "Google client settings could not be saved. Check the values and Keychain access, then try again."
          )
      end
    else
      socket
    end
  end

  defp resume_google(socket, _params), do: socket

  defp focus_heading(socket), do: push_event(socket, "workspace:focus-heading", %{})

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} background={@background} enter_on_return={@enter_on_return}>
      <h1 id="workspace-title" class="sr-only">LOVELACE</h1>
      <Layouts.brand />

      <div id="workspace-content" class="workspace-content" inert>
        <span id="calendar-context" phx-hook="CalendarDay" class="hidden" aria-hidden="true"></span>
        <p id="workspace-save-status" class="sr-only" role="status">{@save_status}</p>
        <div class="workspace-topline">
          <nav id="center-nav" class="center-nav" aria-label="Main navigation">
            <.link
              id="home-link"
              patch="/"
              class="workspace-nav-link"
              aria-label="Home"
              aria-current={if @home, do: "page"}
              aria-disabled={if @editor, do: "true"}
            >Home</.link>
            <.link
              id="show-workspaces"
              patch="/workspaces"
              class="workspace-nav-link"
              aria-current={
                if !@home && !@settings && !@connections && !@scenes && @mail.scope != :home &&
                     @destination.action not in [:youtube, :youtube_video],
                   do: "page"
              }
              aria-disabled={if @editor, do: "true"}
            >Workspaces</.link>
            <.link
              id="show-connections"
              patch="/connections"
              class="workspace-nav-link"
              aria-current={if @connections, do: "page"}
              aria-disabled={if @editor, do: "true"}
            >Connections</.link>
            <.link
              id="show-scenes"
              patch="/scenes"
              class="workspace-nav-link"
              aria-current={if @scenes, do: "page"}
              aria-disabled={if @editor, do: "true"}
            >Scenes</.link>
            <.link
              id="show-settings"
              patch="/settings"
              class="workspace-nav-link"
              aria-current={if @settings, do: "page"}
              aria-disabled={if @editor, do: "true"}
            >Settings</.link>
          </nav>
          <SceneComponents.activity background={@background} />
          <nav
            :if={Enum.any?(@youtube_accounts, & &1.youtube_enabled)}
            id="youtube-account-nav"
            class="connections-subnav"
            aria-label="YouTube accounts"
          >
            <.link
              :for={account <- Enum.filter(@youtube_accounts, & &1.youtube_enabled)}
              id={"youtube-nav-#{account.id}"}
              patch={HomeNavigation.youtube_path(account.id)}
              class="workspace-nav-link"
              aria-current={
                if @destination.action in [:youtube, :youtube_video] &&
                     @destination.account_id == account.id,
                   do: "page"
              }
            >
              YouTube · {account.email}
            </.link>
          </nav>
        </div>

        <section
          class={["workspace-directory", @home && "workspace-directory-home"]}
          aria-labelledby="directory-heading"
        >
          <.link
            :if={@selected && !@connections}
            id="back-to-workspaces"
            patch="/workspaces"
            class="workspace-back workspace-action workspace-action-link"
          >
            All workspaces
          </.link>

          <.link
            :if={@connections && @connection_view != :index}
            id="back-to-connections"
            patch="/connections"
            class="workspace-back workspace-action workspace-action-link"
          >
            All connections
          </.link>

          <HomeComponents.daily_heading :if={@home} />

          <div :if={!@home} class="workspace-directory-heading">
            <div>
              <h2 id="directory-heading" tabindex="-1" data-workspace-heading>
                {cond do
                  @settings -> "Settings"
                  @scenes -> "Scenes"
                  @connections -> "Connections"
                  @destination.action in [:youtube, :youtube_video] -> "YouTube"
                  @selected -> @selected.name
                  @mail.scope == :home -> "Inbox"
                  true -> "Workspaces"
                end}
              </h2>
            </div>
            <nav
              :if={@connections && @connection_view != :index}
              id="connections-subnav"
              class="connections-subnav"
              aria-label="Connection providers"
            >
              <.link
                id="connections-google"
                patch={HomeNavigation.connections_path(:google)}
                class="workspace-nav-link"
                aria-current={if @connection_view == :google, do: "page"}
              >Google</.link>
              <.link
                id="connections-gemini"
                patch={HomeNavigation.connections_path(:gemini)}
                class="workspace-nav-link"
                aria-current={if @connection_view == :gemini, do: "page"}
              >Gemini</.link>
              <.link
                id="connections-gmail"
                patch={HomeNavigation.connections_path(:gmail)}
                class="workspace-nav-link"
                aria-current={if @connection_view == :gmail, do: "page"}
              >Gmail</.link>
              <.link
                id="connections-calendar"
                patch={HomeNavigation.connections_path(:calendar)}
                class="workspace-nav-link"
                aria-current={if @connection_view == :calendar, do: "page"}
              >Calendar</.link>
              <.link
                id="connections-youtube"
                patch="/connections/youtube"
                class="workspace-nav-link"
                aria-current={if @connection_view == :youtube, do: "page"}
              >YouTube</.link>
              <.link
                id="connections-github"
                patch={HomeNavigation.connections_path(:github)}
                class="workspace-nav-link"
                aria-current={if @connection_view == :github, do: "page"}
              >GitHub</.link>
            </nav>
            <button
              :if={
                !@selected && !@settings && !@connections && !@scenes && @mail.scope != :home &&
                  @destination.action not in [:youtube, :youtube_video] && !@editor &&
                  @workspace_options != []
              }
              id="new-workspace"
              type="button"
              class="workspace-action workspace-action-primary"
              phx-click="new_workspace"
              disabled={@loading || @workspaces_error}
            >
              New workspace
            </button>
            <WorkspaceComponents.workspace_menu
              :if={@selected && !@connections && !@editor}
              workspace={@selected}
              current
            />
          </div>
          <p :if={@onboarding_pending} class="mail-muted">
            <.link
              id="finish-onboarding"
              href="/onboarding"
              class="workspace-action workspace-action-link"
            >
              Continue setup
            </.link>
          </p>

          <LovelaceWeb.ModalComponents.modal
            :if={@editor}
            id="workspace-modal"
            title={if @editor == :new, do: "New workspace", else: "Rename workspace"}
            on_cancel="cancel_workspace"
            initial_focus="#workspace-name"
            return_focus={
              if @editor == :new,
                do: "#new-workspace",
                else: "#workspace-menu-#{@form.source.data.id} summary"
            }
          >
            <.form
              for={@form}
              id="workspace-form"
              class="workspace-modal-form"
              phx-change="validate_workspace"
              phx-submit="save_workspace"
            >
              <.input
                field={@form[:name]}
                id="workspace-name"
                label="Name"
                class="workspace-name-input"
                maxlength="64"
                required
                autocomplete="off"
                aria-invalid={if @form[:name].errors != [], do: "true", else: "false"}
                aria-describedby="workspace-name-hint workspace-form-feedback"
              />
              <p id="workspace-name-hint" class="workspace-form-hint">
                Use a name of 1–64 characters.
              </p>
              <p id="workspace-form-feedback" class="workspace-form-feedback" role="alert">
                {if @form_failed,
                  do: "The workspace couldn’t be saved. Check the name and try again."}
              </p>
              <div class="workspace-editor-actions">
                <button
                  type="submit"
                  class="workspace-action workspace-action-primary"
                  phx-disable-with="Saving…"
                >
                  {if @editor == :new, do: "Create workspace", else: "Save name"}
                </button>
                <button type="button" class="workspace-action" phx-click="cancel_workspace">Cancel</button>
              </div>
            </.form>
          </LovelaceWeb.ModalComponents.modal>

          <div
            :if={
              !@home && !@settings && !@selected && !@connections && !@scenes && @mail.scope != :home &&
                @destination.action not in [:youtube, :youtube_video]
            }
            class="workspace-list"
            id="workspace-list"
            phx-update="stream"
          >
            <WorkspaceComponents.card
              :for={{dom_id, workspace} <- @streams.workspaces}
              id={dom_id}
              workspace={workspace}
              health={Map.get(@workspace_health, workspace.id)}
            />
          </div>

          <div
            :if={
              !@home && !@settings && !@selected && !@connections && !@scenes &&
                @mail.scope != :home && @destination.action not in [:youtube, :youtube_video] &&
                !@loading && !@workspaces_error && @workspace_options == []
            }
            id="workspaces-empty"
            class="empty-state"
          >
            <.icon name="hero-squares-2x2" class="empty-state-mark size-6" />
            <div class="empty-state-body">
              <h3 class="empty-state-title">No workspaces yet</h3>
              <p class="empty-state-copy">
                Name a space for an area of life. Add connections whenever you’re ready.
              </p>
              <button
                id="new-workspace"
                type="button"
                class="workspace-action workspace-action-primary"
                phx-click="new_workspace"
              >
                New workspace
              </button>
            </div>
          </div>

          <div :if={@home} id="home-readouts" class="home-readouts">
            <HomeComponents.overview
              accounts={@home_accounts}
              loading={@loading}
              error={@home_error}
            />

            <CalendarComponents.agenda
              home
              accounts={Enum.filter(@calendar_accounts, & &1.calendar_enabled)}
              window={@calendar_window}
              refresh={@calendar_revision}
            />
            <GitHubComponents.dashboard
              organizations={@github_organizations}
              memberships={@github_memberships}
              workspace_options={@workspace_options}
              error={@github_error}
              now={@github_now}
            />
          </div>

          <div
            :if={!@home && !@connections && @mail.scope == :home}
            id="home-inbox"
            class="workspace-landing"
          >
            <MailComponents.panel mail={@mail} />
          </div>

          <p
            :if={@loading && !@home && !@settings && !@scenes}
            id="workspaces-loading"
            class="workspace-notice"
            role="status"
          >
            <.status_signal
              id="workspaces-loading-signal"
              state={:active}
              label="Opening your spaces…"
            />
          </p>
          <div
            :if={@workspaces_error && !@home && !@settings && !@scenes}
            id="workspaces-error"
            class="workspace-notice"
            role="alert"
          >
            <p>Your workspaces couldn’t be loaded. Your saved spaces have not been changed.</p>
            <button type="button" class="workspace-action" phx-click="retry_workspaces">Try again</button>
          </div>

          <HomeComponents.settings :if={@settings} />

          <SceneComponents.gallery
            :if={@scenes}
            gemini_status={@gemini_status}
            data={@scene_data}
            loading={@scene_loading}
            error={@scene_error}
            pending={@scene_request_pending}
            notice={@scene_notice}
            confirmation={@scene_confirmation}
            confirmation_prompt={@scene_confirmation_prompt}
            direction={@scene_direction}
            settings={@scene_settings}
            preparing={@scene_preparing}
            prepared={@scene_prepared}
            acknowledgement={@scene_acknowledgement}
          />

          <LovelaceWeb.ConnectionComponents.overview :if={@connections && @connection_view == :index} />

          <GoogleComponents.connection
            :if={@connections && @connection_view == :google}
            status={@google_status}
          />

          <GeminiComponents.connection
            :if={@connections && @connection_view == :gemini}
            status={@gemini_status}
          />

          <MailComponents.connections
            :if={@connections && @connection_view == :gmail}
            mail={@mail}
            google_status={@google_status}
            workspace_options={@workspace_options}
          />

          <CalendarComponents.connections
            :if={@connections && @connection_view == :calendar}
            accounts={@calendar_accounts}
            google_status={@google_status}
            workspace_options={@workspace_options}
            window={@calendar_window}
            refresh={@calendar_revision}
          />

          <YouTubeComponents.connections
            :if={@connections && @connection_view == :youtube}
            readouts={@youtube_readouts}
            google_status={@google_status}
            workspace_options={@workspace_options}
            stopped={@youtube_observation_stopped}
            error={@youtube_error}
          />

          <YouTubeComponents.feed
            :if={
              @destination.action in [:youtube, :youtube_video] && @youtube_account &&
                @youtube_snapshot
            }
            account={@youtube_account}
            snapshot={@youtube_snapshot}
            video={@youtube_video}
            video_route={@destination.action == :youtube_video}
            stopped={@youtube_observation_stopped}
          />
          <p
            :if={@destination.action in [:youtube, :youtube_video] && is_nil(@youtube_snapshot)}
            role="status"
            class="calendar-warning"
          >
            Local YouTube state is unavailable or this account was removed. <.link
              patch="/connections/youtube"
              class="workspace-action-link"
            >Check YouTube connections</.link>.
          </p>

          <GitHubComponents.connections
            :if={@connections && @connection_view == :github}
            organizations={@github_organizations}
            connections={@github_connections}
            auth={@github_auth}
            authorization_error={@github_authorization_error}
            configured={@github_configured}
            installation_url={@github_installation_url}
            callback_url={@github_callback_url}
            configuration_status={@github_configuration_status}
            memberships={@github_memberships}
            workspace_options={@workspace_options}
            error={@github_error}
            now={@github_now}
          />

          <div
            :if={@selected && !@connections && !@editor}
            id="workspace-landing"
            class="workspace-landing"
          >
            <MailComponents.panel mail={@mail} workspace={@selected} />
            <CalendarComponents.agenda
              :if={!@mail.account_id && !@mail.adding}
              accounts={
                Enum.filter(@calendar_accounts, &(&1.calendar_enabled && &1.id in @mail.memberships))
              }
              window={@calendar_window}
              refresh={@calendar_revision}
            />
            <GitHubComponents.workspace
              :if={!@mail.account_id}
              organizations={@github_organizations}
              connections={@github_connections}
              memberships={@github_memberships}
              workspace={@selected}
              error={@github_error}
              adding={@mail.adding}
              now={@github_now}
            />
          </div>
        </section>
      </div>
      <div id="workspace-controls" class="workspace-controls" inert>
        <.form for={%{}} action="/lock" method="post" id="owner-lock-form">
          <button type="submit" class="workspace-action">Lock</button>
        </.form>
        <footer class="workspace-footer">
          <span><kbd>esc</kbd> Landscape</span>
        </footer>
      </div>
    </Layouts.app>
    """
  end
end
