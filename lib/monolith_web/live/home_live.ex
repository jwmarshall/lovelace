defmodule MonolithWeb.HomeLive do
  @moduledoc "The local owner's daily orientation, workspaces and separate Gmail accounts."
  use MonolithWeb, :live_view

  alias Monolith.Mail.ConnectionDiagnostics
  alias Monolith.Workspaces
  alias Monolith.Workspaces.Workspace

  alias MonolithWeb.{
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
    MailComponents,
    SceneComponents,
    WorkspaceComponents
  }

  # Capability minted only behind the HTTP and LiveView owner-session boundaries.
  @owner %{role: :local_owner}

  @impl true
  def mount(params, session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Monolith.PubSub, "stage_designer")

    background =
      case Monolith.StageDesigner.background() do
        {:ok, background} -> background
        {:error, _reason} -> %{url: nil, status: :unavailable}
      end

    socket =
      socket
      |> assign(
        page_title: "Home",
        enter_on_return: session["workspace_return"] == true,
        enter_on_unlock: session["workspace_unlock"] == true,
        navigation_ready: false,
        navigation_path: nil,
        home_accounts: [],
        home_error: false,
        onboarding_pending: Monolith.Onboarding.pending?(),
        background: background,
        selected: nil,
        workspace_options: [],
        workspace_health: %{},
        directory_subscriptions: [],
        editor: nil,
        form: nil,
        workspace_draft: %{},
        startup_preference: nil,
        startup_error: false,
        startup_status: "",
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
    # Workspace readouts share the provider-free summary with Home, even though
    # HomeMail owns their account subscriptions after leaving the directory.
    socket =
      if id in socket.assigns.directory_subscriptions || id in socket.assigns.mail.subscriptions,
        do: load_workspaces(socket),
        else: HomeCalendar.reload(socket)

    reconcile_mail_navigation(socket, HomeMail.handle_info(message, socket))
  end

  def handle_info({:calendar_changed, id}, socket) do
    if id in socket.assigns.directory_subscriptions || id in socket.assigns.mail.subscriptions do
      {:noreply, HomeCalendar.changed(socket)}
    else
      {:noreply, socket}
    end
  end

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
    socket = accept_event_destination(socket, name)
    path = HomeNavigation.current(socket)

    {:noreply,
     if(path == socket.assigns.navigation_path, do: socket, else: push_patch(socket, to: path))}
  end

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
     |> load_startup_preference()
     |> focus_heading()}
  end

  defp event("settings:startup", %{"enabled" => enabled}, %{assigns: %{settings: true}} = socket)
       when enabled in ["true", "false"] do
    case Monolith.StageDesigner.save_startup_preference(%{enabled: enabled == "true"},
           actor: @owner
         ) do
      {:ok, preference} ->
        {:noreply,
         assign(socket,
           startup_preference: preference,
           startup_error: false,
           startup_status: "Startup choice saved. No generation was started."
         )}

      _ ->
        {:noreply, assign(socket, startup_error: true, startup_status: "")}
    end
  end

  defp event("settings:startup", _, socket), do: {:noreply, socket}

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
       do: {:noreply, socket |> HomeGemini.open() |> load_startup_preference()}

  defp event("gemini:check", _params, socket), do: {:noreply, socket}

  defp event(
         "select_connection",
         %{"provider" => provider},
         %{assigns: %{connections: true}} = socket
       )
       when provider in ["google", "gemini", "gmail", "calendar", "github"] do
    view =
      Map.fetch!(
        %{
          "google" => :google,
          "gemini" => :gemini,
          "gmail" => :gmail,
          "calendar" => :calendar,
          "github" => :github
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
          view when view in [:google, :gmail, :calendar] -> HomeGoogle.open(socket)
          :gemini -> socket |> HomeGemini.open() |> load_startup_preference()
          :github -> HomeGitHub.open(socket)
        end

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
      Map.get(socket.assigns.workspace_draft, :new) ||
        Workspace
        |> AshPhoenix.Form.for_create(:create, as: "workspace", actor: @owner)
        |> to_form()

    {:noreply, assign(socket, editor: :new, form: form, form_failed: false, save_status: "")}
  end

  defp event("rename_workspace", %{"id" => id}, socket) do
    case Workspaces.get_workspace(id, actor: @owner) do
      {:ok, %Workspace{} = workspace} ->
        form =
          Map.get(socket.assigns.workspace_draft, id) ||
            workspace
            |> AshPhoenix.Form.for_update(:rename, as: "workspace", actor: @owner)
            |> to_form()

        {:noreply,
         assign(socket, editor: :rename, form: form, form_failed: false, save_status: "")}

      _ ->
        {:noreply, put_flash(socket, :error, "This workspace is unavailable. Try again.")}
    end
  end

  defp event("cancel_workspace", _params, %{assigns: %{form: nil}} = socket),
    do: {:noreply, socket}

  defp event("cancel_workspace", _params, socket) do
    key = if socket.assigns.editor == :new, do: :new, else: socket.assigns.form.source.data.id
    drafts = Map.put(socket.assigns.workspace_draft, key, socket.assigns.form)
    {:noreply, assign(socket, editor: nil, form: nil, workspace_draft: drafts)}
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
         |> load_workspaces()
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
    socket = assign(socket, navigation_ready: true, navigation_path: canonical)
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
       when action in [
              :workspace,
              :integration_add,
              :workspace_inbox,
              :workspace_thread,
              :workspace_github
            ] do
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
    if destination.action == :workspace_github do
      case HomeGitHub.select_activity(socket, destination) do
        {:ok, socket} ->
          socket |> HomeNavigation.put(destination) |> focus_heading()

        :error ->
          unavailable_destination(socket, "This GitHub owner is unavailable in this workspace.")
      end
    else
      visit_workspace_mail(socket, destination)
    end
  end

  defp visit_workspace_mail(socket, destination) do
    leaving_activity = socket.assigns.github_activity

    socket =
      if socket.assigns.connections ||
           (socket.assigns.mail.account_id && is_nil(destination.account_id)),
         do: transition(socket, "open_workspace", %{"id" => destination.workspace_id}),
         else: socket

    if destination.account_id do
      visit_mail(socket, destination)
    else
      socket =
        cond do
          destination.action == :integration_add -> transition(socket, "mail:add")
          socket.assigns.mail.adding -> transition(socket, "mail:close_add")
          true -> socket
        end

      socket = HomeNavigation.put(socket, destination)
      if leaving_activity, do: focus_heading(socket), else: socket
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
        key = if socket.assigns.editor == :new, do: :new, else: workspace.id
        selected = socket.assigns.selected
        selected = if selected && selected.id == workspace.id, do: workspace, else: selected

        {:noreply,
         socket
         |> assign(
           selected: selected,
           editor: nil,
           form: nil,
           workspace_draft: Map.delete(socket.assigns.workspace_draft, key),
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

    socket = if directory?, do: load_workspaces(socket), else: socket

    socket =
      if socket.assigns.github_activity do
        case HomeGitHub.select_activity(socket, socket.assigns.destination) do
          {:ok, socket} ->
            socket

          :error ->
            socket =
              unavailable_destination(
                socket,
                "This GitHub owner is no longer available in this workspace."
              )

            push_patch(socket, to: HomeNavigation.current(socket), replace: true)
        end
      else
        socket
      end

    {:noreply, socket}
  end

  defp load_workspaces(socket) do
    case Monolith.Home.summary(actor: @owner) do
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
        |> HomeCalendar.reload()
        |> directory_subscriptions([])
    end
  end

  defp directory_subscriptions(socket, ids) do
    old = socket.assigns.directory_subscriptions

    if connected?(socket) do
      Enum.each(old -- ids, &Phoenix.PubSub.unsubscribe(Monolith.PubSub, "mail:#{&1}"))
      Enum.each(ids -- old, &Phoenix.PubSub.subscribe(Monolith.PubSub, "mail:#{&1}"))
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

  defp load_startup_preference(socket) do
    case Monolith.StageDesigner.startup_preference(actor: @owner) do
      {:ok, preference} ->
        assign(socket, startup_preference: preference, startup_error: false, startup_status: "")

      _ ->
        assign(socket, startup_preference: nil, startup_error: true, startup_status: "")
    end
  end

  defp view_heading(%{settings: true}), do: "Settings"
  defp view_heading(%{scenes: true}), do: "Scenes"
  defp view_heading(%{connections: true, connection_view: :index}), do: "Connections"

  defp view_heading(%{connections: true, connection_view: provider}) do
    Map.fetch!(
      %{
        google: "Google",
        gmail: "Gmail",
        calendar: "Calendar",
        gemini: "Gemini",
        github: "GitHub"
      },
      provider
    )
  end

  defp view_heading(%{mail: %{adding: true}}), do: "Use a connection again"
  defp view_heading(%{selected: %{name: name}}), do: name
  defp view_heading(%{mail: %{scope: :home}}), do: "Inbox"
  defp view_heading(_assigns), do: "Workspaces"

  defp view_register(assigns) do
    cond do
      assigns.settings ->
        "05 / Settings"

      assigns.scenes ->
        "04 / Scenes"

      assigns.connections ->
        "03 / " <> view_heading(assigns)

      assigns.mail.scope == :home ->
        "01 / Email"

      assigns.mail.adding ->
        "02 / Add integration"

      assigns.selected ->
        "02 / " <> assigns.selected.name

      true ->
        "02 / Workspaces"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      background={@background}
      enter_on_return={@enter_on_return}
      enter_on_unlock={@enter_on_unlock}
    >
      <p id="workspace-title" class="sr-only">MONOLITH</p>
      <Layouts.brand />

      <div id="workspace-content" class="workspace-content" inert>
        <div id="workspace-shell" class="workspace-shell" data-navigation="collapsed">
          <aside
            id="product-sidebar"
            class="product-sidebar"
            phx-hook="Sidebar"
            aria-label="Product navigation"
          >
            <div class="sidebar-top">
              <button
                id="sidebar-toggle"
                type="button"
                class="navigation-toggle"
                aria-label="Expand sidebar"
                aria-expanded="false"
                aria-controls="sidebar-content"
              >
                <Layouts.monogram id="sidebar-mark" treatment={:solid} />
              </button>
              <span class="brand-wordmark sidebar-wordmark" aria-hidden="true">MONOLITH</span>
            </div>
            <div id="sidebar-content" class="sidebar-content" hidden>
              <p class="sidebar-caption">Your workspace</p>
              <nav id="center-nav" aria-label="Main navigation">
                <.link
                  id="home-link"
                  patch="/"
                  aria-current={
                    if @home || (!@selected && @mail.scope == :home && !@connections), do: "page"
                  }
                ><span class="nav-index">01</span>Home</.link>
                <.link
                  id="show-workspaces"
                  patch="/workspaces"
                  aria-current={
                    if !@home && !@settings && !@connections && !@scenes &&
                         (@selected || @mail.scope != :home),
                       do: "page"
                  }
                ><span class="nav-index">02</span>Workspaces</.link>
                <.link
                  id="show-connections"
                  patch="/connections"
                  aria-current={if @connections, do: "page"}
                ><span class="nav-index">03</span>Connections</.link>
                <.link id="show-scenes" patch="/scenes" aria-current={if @scenes, do: "page"}><span class="nav-index">04</span>Scenes</.link>
                <.link id="show-settings" patch="/settings" aria-current={if @settings, do: "page"}><span class="nav-index">05</span>Settings</.link>
              </nav>
              <div class="sidebar-foot">
                <SceneComponents.activity background={@background} />
              </div>
            </div>
          </aside>
          <span id="calendar-context" phx-hook="CalendarDay" class="hidden" aria-hidden="true"></span>
          <p id="workspace-save-status" class="sr-only" role="status">{@save_status}</p>
          <section
            class={["workspace-directory", @home && "workspace-directory-home"]}
            aria-label="Current view"
          >
            <div
              :if={!@home && !@github_activity && !@mail.account_id}
              class="page-register-row page-header-row"
            >
              <p class="page-register">{view_register(assigns)}</p>
              <.link
                :if={@selected && !@connections}
                id={if @mail.adding, do: "close-add-integration", else: "back-to-workspaces"}
                patch={
                  if @mail.adding,
                    do: HomeNavigation.workspace_path(@selected.id),
                    else: "/workspaces"
                }
                class="workspace-action workspace-action-link"
              >{if @mail.adding, do: "Back to #{@selected.name}", else: "All workspaces"}</.link>
              <.link
                :if={@connections && @connection_view != :index}
                id="back-to-connections"
                patch="/connections"
                class="workspace-action workspace-action-link"
              >All connections</.link>
              <.lock_control />
            </div>
            <HomeComponents.daily_heading :if={@home} />
            <div
              :if={!@home && !@github_activity && !@mail.account_id}
              class="workspace-directory-heading"
            >
              <h1 id="directory-heading" tabindex="-1" data-workspace-heading>
                {view_heading(assigns)}
              </h1>
              <button
                :if={
                  !@selected && !@settings && !@connections && !@scenes && @mail.scope != :home &&
                    !@editor && @workspace_options != []
                }
                id="new-workspace"
                type="button"
                class="workspace-action workspace-action-primary"
                phx-click="new_workspace"
                disabled={@loading || @workspaces_error}
              >
                New workspace
              </button>
              <div
                :if={@selected && !@connections && !@editor && !@mail.adding}
                class="workspace-heading-actions"
              >
                <WorkspaceComponents.rename_button workspace={@selected} current />
                <.link
                  id="add-integration"
                  patch={HomeNavigation.workspace_path(@selected.id) <> "/integrations"}
                  class="workspace-action workspace-action-primary"
                >Add integration</.link>
              </div>
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

            <MonolithWeb.ModalComponents.modal
              :if={@editor}
              id="workspace-modal"
              title={if @editor == :new, do: "New workspace", else: "Rename workspace"}
              on_cancel="cancel_workspace"
              initial_focus="#workspace-name"
              return_focus={
                if @editor == :new,
                  do: "#new-workspace",
                  else:
                    if(@selected,
                      do: "#rename-current-workspace",
                      else: "#rename-#{@form.source.data.id}"
                    )
              }
            >
              <.form
                for={@form}
                id="workspace-form"
                class="workspace-modal-form"
                phx-change="validate_workspace"
                phx-submit="save_workspace"
              >
                <div class="workspace-field-group">
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
                    <span :if={@form_failed}>
                      The workspace couldn’t be saved. <a href="#workspace-name">Check the name</a>
                      and try again.
                    </span>
                  </p>
                </div>
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
            </MonolithWeb.ModalComponents.modal>

            <div
              :if={
                !@home && !@settings && !@selected && !@connections && !@scenes &&
                  @mail.scope != :home
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
                  @mail.scope != :home && !@loading && !@workspaces_error && @workspace_options == []
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
                accounts_state={@calendar_accounts_state}
                window={@calendar_window}
                refresh={@calendar_revision}
              />
            </div>
            <div :if={@home} class="github-plane">
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

            <HomeComponents.settings
              :if={@settings}
              startup_preference={@startup_preference}
              startup_error={@startup_error}
              startup_status={@startup_status}
            />

            <SceneComponents.gallery
              :if={@scenes}
              gemini_status={@gemini_status}
              background={@background}
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

            <MonolithWeb.ConnectionComponents.overview :if={
              @connections && @connection_view == :index
            } />

            <nav
              :if={@connections && @connection_view != :index}
              id="connections-subnav"
              class="connections-subnav"
              aria-label="Connection providers"
            >
              <.link
                :for={
                  {provider, name} <- [
                    google: "Google",
                    gmail: "Gmail",
                    calendar: "Calendar",
                    gemini: "Gemini",
                    github: "GitHub"
                  ]
                }
                id={"connections-#{provider}"}
                patch={HomeNavigation.connections_path(provider)}
                class="workspace-nav-link"
                aria-current={if @connection_view == provider, do: "page"}
              >{name}</.link>
            </nav>

            <div :if={@connections && @connection_view != :index} class="provider-layout">
              <div class="provider-main">
                <GoogleComponents.connection
                  :if={@connection_view == :google}
                  status={@google_status}
                />

                <GeminiComponents.connection
                  :if={@connection_view == :gemini}
                  status={@gemini_status}
                  startup_preference={@startup_preference}
                />

                <MailComponents.connections
                  :if={@connection_view == :gmail}
                  mail={@mail}
                  google_status={@google_status}
                  workspace_options={@workspace_options}
                  readouts={@home_accounts}
                />

                <CalendarComponents.connections
                  :if={@connection_view == :calendar}
                  accounts={@calendar_accounts}
                  accounts_state={@calendar_accounts_state}
                  google_status={@google_status}
                  workspace_options={@workspace_options}
                  window={@calendar_window}
                  refresh={@calendar_revision}
                />

                <GitHubComponents.connections
                  :if={@connection_view == :github}
                  organizations={@github_organizations}
                  connections={@github_connections}
                  auth={@github_auth}
                  authorization_error={@github_authorization_error}
                  configured={@github_configured}
                  installation_url={@github_installation_url}
                  configuration_status={@github_configuration_status}
                  memberships={@github_memberships}
                  workspace_options={@workspace_options}
                  error={@github_error}
                  now={@github_now}
                />
              </div>
              <MonolithWeb.ConnectionComponents.context
                provider={@connection_view}
                gmail_accounts_present={@mail.accounts != []}
              >
                <:github_help>
                  <GitHubComponents.setup_help
                    :if={@connection_view == :github}
                    configuration_status={@github_configuration_status}
                    callback_url={@github_callback_url}
                  />
                </:github_help>
              </MonolithWeb.ConnectionComponents.context>
            </div>

            <div
              :if={@selected && !@connections && !@editor && !@github_activity}
              id="workspace-landing"
              class={[
                "workspace-landing",
                !@mail.account_id && !@mail.adding && "workspace-detail-grid",
                @mail.adding && "workspace-add-plane"
              ]}
            >
              <MailComponents.panel mail={@mail} workspace={@selected} readouts={@home_accounts} />
              <CalendarComponents.agenda
                :if={!@mail.account_id && !@mail.adding}
                accounts={
                  Enum.filter(
                    @calendar_accounts,
                    &(&1.calendar_enabled && &1.id in @mail.memberships)
                  )
                }
                window={@calendar_window}
                accounts_state={@calendar_accounts_state}
                refresh={@calendar_revision}
              />
            </div>
            <div
              :if={@selected && !@connections && !@editor && !@github_activity && !@mail.account_id}
              class="github-plane"
            >
              <GitHubComponents.workspace
                organizations={@github_organizations}
                connections={@github_connections}
                memberships={@github_memberships}
                workspace={@selected}
                error={@github_error}
                adding={@mail.adding}
                now={@github_now}
              />
            </div>
            <GitHubComponents.activity
              :if={@github_activity && @selected}
              organizations={@github_organizations}
              memberships={@github_memberships}
              workspace={@selected}
              organization_id={@destination.organization_id}
              error={@github_error}
              now={@github_now}
            />
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
