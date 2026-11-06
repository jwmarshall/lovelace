defmodule LovelaceWeb.HomeConnectionDiagnostic do
  @moduledoc false
  import Phoenix.Component, only: [assign: 3, assign: 2]
  import Phoenix.LiveView, only: [connected?: 1]
  alias Lovelace.ConnectionDiagnostics
  @owner %{role: :local_owner}

  def init(socket, provider), do: assign(socket, key(provider), nil)

  def open(socket, provider) do
    cancel(socket.assigns[key(provider)])
    socket = render(socket, provider, %{status: :pending, app_slug: nil})

    if connected?(socket) do
      case ConnectionDiagnostics.request(provider, actor: @owner) do
        {:ok, %{id: id} = result} ->
          token = Ash.UUID.generate()

          socket
          |> assign(key(provider), %{id: id, token: token, timer: nil})
          |> render(provider, result)
          |> schedule(provider, token, result.status)

        _ ->
          render(socket, provider, %{status: :unavailable, app_slug: nil})
      end
    else
      socket
    end
  end

  def handle_info({:connection_diagnostic, provider, token}, socket) do
    case socket.assigns[key(provider)] do
      %{id: id, token: ^token} ->
        if active?(socket.assigns, provider) do
          result = observe(provider, id)

          {:noreply,
           socket |> render(provider, result) |> schedule(provider, token, result.status)}
        else
          {:noreply, assign(socket, key(provider), nil)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  defp observe(provider, id) do
    case ConnectionDiagnostics.observe(provider, id, actor: @owner) do
      {:ok, result} -> result
      _ -> %{status: :unavailable, app_slug: nil}
    end
  end

  defp schedule(socket, provider, token, status) do
    delay = if status == :pending, do: 250, else: 5_000
    timer = Process.send_after(self(), {:connection_diagnostic, provider, token}, delay)
    assign(socket, key(provider), %{socket.assigns[key(provider)] | timer: timer})
  end

  defp cancel(%{timer: timer}) when is_reference(timer), do: Process.cancel_timer(timer)
  defp cancel(_), do: :ok

  defp render(socket, :google, result), do: assign(socket, :google_status, status(result.status))

  defp render(socket, :gemini, result) do
    value =
      if result.status == :pending && socket.assigns.gemini_status in [:stored, :rechecking],
        do: :rechecking,
        else: status(result.status)

    assign(socket, :gemini_status, value)
  end

  defp render(socket, :github, result) do
    configured = result.status == :stored

    assign(socket,
      github_configured: configured,
      github_configuration_status: status(result.status),
      github_installation_url:
        if(configured && result.app_slug,
          do: "https://github.com/apps/#{result.app_slug}/installations/new"
        )
    )
  end

  defp status(:pending), do: :loading
  defp status(status), do: status
  defp key(:google), do: :google_diagnostic
  defp key(:gemini), do: :gemini_diagnostic
  defp key(:github), do: :github_diagnostic

  defp active?(assigns, :gemini),
    do: assigns.scenes || (assigns.connections && assigns.connection_view == :gemini)

  defp active?(assigns, :google),
    do: assigns.connections && assigns.connection_view in [:google, :gmail, :calendar, :youtube]

  defp active?(assigns, :github), do: assigns.connections && assigns.connection_view == :github
end
