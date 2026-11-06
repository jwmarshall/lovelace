defmodule LovelaceWeb.HomeNavigation do
  @moduledoc "Local, account-scoped destinations shared by links and LiveView navigation."

  def workspace_path(id), do: "/workspaces/" <> segment(id)
  def account_path(id), do: "/accounts/" <> segment(id) <> "/mail"
  def youtube_path(id), do: "/accounts/" <> segment(id) <> "/youtube"
  def youtube_path(id, video), do: youtube_path(id) <> "/videos/" <> segment(video)

  def connections_path(provider \\ :index)
  def connections_path(:index), do: "/connections"
  def connections_path(provider), do: "/connections/#{provider}"

  def mail_path(mail, changes \\ %{}) do
    mail = Map.merge(mail, changes)

    base =
      if mail.scope == :home,
        do: account_path(mail.account_id),
        else:
          workspace_path(mail.workspace_id) <> "/accounts/" <> segment(mail.account_id) <> "/mail"

    base = if mail.thread_id, do: base <> "/threads/" <> segment(mail.thread_id), else: base
    query(base, q: mail.query, page_token: mail.page_token)
  end

  def current(%{assigns: %{destination: destination}}), do: path(destination)

  def path(%{action: :index}), do: "/"
  def path(%{action: :workspaces}), do: "/workspaces"
  def path(%{action: :settings}), do: "/settings"
  def path(%{action: :connections}), do: connections_path()
  def path(%{action: :connection, provider: provider}), do: connections_path(provider)

  def path(%{action: :youtube, account_id: id}), do: youtube_path(id)

  def path(%{action: :youtube_video, account_id: id, video_id: video}),
    do: youtube_path(id, video)

  def path(%{action: :scenes, page: page, attempt_page: attempt_page}) do
    query("/scenes",
      page: if(page > 1, do: page),
      attempt_page: if(attempt_page > 1, do: attempt_page)
    )
  end

  def path(%{action: :workspace, workspace_id: id}), do: workspace_path(id)

  def path(%{action: :integration_add, workspace_id: id}),
    do: workspace_path(id) <> "/integrations"

  def path(%{action: action} = destination)
      when action in [:inbox, :thread, :workspace_inbox, :workspace_thread] do
    destination
    |> Map.put(:scope, if(action in [:inbox, :thread], do: :home, else: :workspace))
    |> mail_path()
  end

  @doc "Projects compatibility flags from the one authoritative parsed destination."
  def put(socket, action, params) when is_atom(action) do
    {:ok, destination} = destination(action, params)
    put(socket, destination)
  end

  def put(socket, action) when is_atom(action), do: put(socket, action, %{})

  def put(socket, %{action: action} = destination) do
    Phoenix.Component.assign(socket,
      destination: destination,
      home: action == :index,
      settings: action == :settings,
      scenes: action == :scenes,
      connections: action in [:connections, :connection],
      connection_view: if(action == :connection, do: destination.provider, else: :index)
    )
  end

  def directory?(%{action: action}), do: action in [:index, :workspaces]

  @doc "Parses accepted mail navigation context; invalid context fails without changing destination."
  def from_mail(socket) do
    mail = socket.assigns.mail

    action = mail_action(mail, socket.assigns.destination.action)

    if action in [
         :workspace,
         :integration_add,
         :inbox,
         :thread,
         :workspace_inbox,
         :workspace_thread
       ] do
      params = %{
        "workspace_id" => mail.workspace_id,
        "account_id" => mail.account_id,
        "thread_id" => mail.thread_id,
        "q" => mail.query,
        "page_token" => mail.page_token
      }

      case destination(action, params) do
        {:ok, destination} -> {:ok, put(socket, destination)}
        _ -> :error
      end
    else
      {:ok, socket}
    end
  end

  defp mail_action(%{account_id: id, scope: :home, thread_id: nil}, _fallback)
       when not is_nil(id),
       do: :inbox

  defp mail_action(%{account_id: id, scope: :home}, _fallback) when not is_nil(id),
    do: :thread

  defp mail_action(%{account_id: id, thread_id: nil}, _fallback) when not is_nil(id),
    do: :workspace_inbox

  defp mail_action(%{account_id: id}, _fallback) when not is_nil(id),
    do: :workspace_thread

  defp mail_action(%{adding: true, workspace_id: id}, _fallback) when not is_nil(id),
    do: :integration_add

  defp mail_action(%{workspace_id: id}, _fallback) when not is_nil(id), do: :workspace
  defp mail_action(_mail, fallback), do: fallback

  # Accept old bookmarks, but never generate query-string navigation again.
  def destination(:index, %{"connections" => provider})
      when provider in ["gmail", "calendar", "gemini", "github", "youtube"],
      do: destination(:connection, %{"provider" => provider})

  def destination(:index, %{"calendar" => _}),
    do: destination(:connection, %{"provider" => "calendar"})

  def destination(:index, %{"workspace" => id}),
    do: destination(:workspace, %{"workspace_id" => id})

  def destination(:index, %{"gmail" => _}),
    do: destination(:connection, %{"provider" => "gmail"})

  def destination(action, params) do
    params = Map.take(params, keys(action))

    with {:ok, provider} <- provider(params),
         {:ok, page} <- page(params),
         {:ok, attempt_page} <- attempt_page(params),
         {:ok, query} <- text(params["q"], 1024),
         {:ok, token} <- text(params["page_token"], 2048),
         {:ok, thread} <- thread(params["thread_id"]),
         {:ok, video} <- video(params["video_id"]),
         {:ok, workspace} <- uuid(params["workspace_id"]),
         {:ok, account} <- uuid(params["account_id"]) do
      {:ok,
       %{
         action: action,
         provider: if(action == :connections, do: :index, else: provider),
         page: page,
         attempt_page: attempt_page,
         workspace_id: workspace,
         account_id: account,
         query: query,
         page_token: token,
         thread_id: thread,
         video_id: video
       }}
    end
  end

  defp keys(:connection), do: ["provider"]
  defp keys(:scenes), do: ["page", "attempt_page"]
  defp keys(action) when action in [:workspace, :integration_add], do: ["workspace_id"]
  defp keys(:inbox), do: ["account_id", "q", "page_token"]
  defp keys(:thread), do: ["account_id", "thread_id", "q", "page_token"]
  defp keys(:workspace_inbox), do: ["workspace_id", "account_id", "q", "page_token"]
  defp keys(:workspace_thread), do: ["workspace_id", "account_id", "thread_id", "q", "page_token"]
  defp keys(:youtube), do: ["account_id"]
  defp keys(:youtube_video), do: ["account_id", "video_id"]
  defp keys(_action), do: []

  defp provider(%{"provider" => provider})
       when provider in ["google", "gmail", "gemini", "calendar", "github", "youtube"],
       do:
         {:ok,
          Map.fetch!(
            %{
              "google" => :google,
              "gmail" => :gmail,
              "gemini" => :gemini,
              "calendar" => :calendar,
              "github" => :github,
              "youtube" => :youtube
            },
            provider
          )}

  defp provider(%{"provider" => _}), do: :error
  defp provider(_), do: {:ok, :gmail}

  defp page(%{"page" => page}) when is_binary(page) and byte_size(page) <= 8 do
    case Integer.parse(page) do
      {number, ""} when number > 0 and number <= 1_000_000 -> {:ok, number}
      _ -> :error
    end
  end

  defp page(%{"page" => _}), do: :error
  defp page(_), do: {:ok, 1}

  defp attempt_page(%{"attempt_page" => value}), do: page(%{"page" => value})
  defp attempt_page(_), do: {:ok, 1}

  defp video(nil), do: {:ok, nil}

  defp video(value) when is_binary(value) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]{11}\z/, value), do: {:ok, value}, else: :error
  end

  defp video(_), do: :error

  defp thread(nil), do: {:ok, nil}

  defp thread(value) when is_binary(value) do
    if byte_size(value) <= 128 && Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, value),
      do: {:ok, value},
      else: :error
  end

  defp thread(_), do: :error

  defp text(nil, _max), do: {:ok, nil}

  defp text(value, max) when is_binary(value) and byte_size(value) <= max * 4 do
    if String.valid?(value) && String.length(value) <= max &&
         !String.contains?(value, ["\u0000", "\r", "\n"]),
       do: {:ok, if(value == "", do: nil, else: value)},
       else: :error
  end

  defp text(_, _), do: :error
  defp uuid(nil), do: {:ok, nil}
  defp uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp uuid(_), do: :error

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp query(path, values) do
    case Enum.reject(values, fn {_key, value} -> is_nil(value) end) do
      [] -> path
      values -> path <> "?" <> URI.encode_query(values)
    end
  end
end
