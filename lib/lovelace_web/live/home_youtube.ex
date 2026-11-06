defmodule LovelaceWeb.HomeYouTube do
  @moduledoc "Account-scoped local YouTube observations; durable work belongs to the domain."
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, put_flash: 3]
  @owner %{role: :local_owner}

  def init(socket) do
    assign(socket,
      youtube_accounts: [],
      youtube_readouts: [],
      youtube_account: nil,
      youtube_snapshot: nil,
      youtube_video: nil,
      youtube_subscriptions: [],
      youtube_observer: nil,
      youtube_observation_stopped: false,
      youtube_error: false,
      youtube_accounts_error: false
    )
  end

  def reload_accounts(socket) do
    case Lovelace.Mail.list_accounts(actor: @owner) do
      {:ok, accounts} ->
        assign(socket,
          youtube_accounts: Enum.reject(accounts, &(&1.status == :disconnected)),
          youtube_accounts_error: false
        )

      _ ->
        assign(socket, youtube_accounts: [], youtube_accounts_error: true)
    end
  end

  def connections(socket) do
    socket = reload_accounts(socket)
    socket = subscribe(socket, Enum.map(socket.assigns.youtube_accounts, & &1.id))

    Enum.each(socket.assigns.youtube_accounts, fn account ->
      if account.youtube_enabled, do: Lovelace.YouTube.prepare(account.id, actor: @owner)
    end)

    socket |> observe() |> schedule(0)
  end

  def navigate(socket, destination) do
    socket = socket |> leave() |> reload_accounts()
    account = Enum.find(socket.assigns.youtube_accounts, &(&1.id == destination.account_id))

    if account do
      if account.youtube_enabled, do: Lovelace.YouTube.prepare(account.id, actor: @owner)
      socket = socket |> assign(:youtube_account, account) |> subscribe([account.id]) |> observe()

      video =
        if snapshot = socket.assigns.youtube_snapshot,
          do: Enum.find(snapshot.videos, &(&1["id"] == destination.video_id))

      if destination.action == :youtube_video && is_nil(video) do
        {:error, socket}
      else
        {:ok, socket |> assign(:youtube_video, video) |> schedule(0)}
      end
    else
      {:error, socket}
    end
  end

  def sync(socket) do
    if active?(socket), do: socket, else: leave(socket)
  end

  def leave(socket) do
    cancel(socket.assigns.youtube_observer)

    socket
    |> subscribe([])
    |> assign(
      youtube_account: nil,
      youtube_snapshot: nil,
      youtube_video: nil,
      youtube_readouts: [],
      youtube_observer: nil,
      youtube_observation_stopped: false
    )
  end

  def handle_info({:youtube_changed, id}, socket) do
    if id in socket.assigns.youtube_subscriptions, do: observe(socket), else: socket
  end

  def handle_info({:google_changed, id}, socket) do
    if id in socket.assigns.youtube_subscriptions, do: observe(socket), else: socket
  end

  def handle_info({:youtube_observe, token, attempt}, socket) do
    case socket.assigns.youtube_observer do
      {_timer, ^token} ->
        socket |> assign(:youtube_observer, nil) |> observe() |> schedule(attempt)

      _ ->
        socket
    end
  end

  def handle_event("youtube:check", _params, socket) do
    {:noreply, if(active?(socket), do: observe(socket), else: socket)}
  end

  def handle_event(event, %{"account_id" => id} = params, socket)
      when event in ["youtube:refresh", "youtube:select"] do
    if active?(socket) && id in socket.assigns.youtube_subscriptions do
      # A previously loaded player must stop even when saving the same selection.
      socket = Phoenix.LiveView.push_event(socket, "youtube:stop", %{})

      result = mutate(event, id, params)

      socket =
        case result do
          {:ok, _} ->
            socket

          _ ->
            put_flash(
              socket,
              :error,
              "YouTube could not be updated. Check your selection, cooldown and connection."
            )
        end

      {:noreply, socket |> observe() |> schedule(0)}
    else
      {:noreply, socket}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp mutate("youtube:refresh", id, _params),
    do: Lovelace.YouTube.refresh(id, actor: @owner)

  defp mutate("youtube:select", id, params) do
    ids = Map.get(params, "channel_ids", [])
    ids = if is_list(ids), do: Enum.reject(ids, &(&1 == "")), else: ids

    Lovelace.YouTube.select_channels(id, ids, params["generation"], params["revision"],
      actor: @owner
    )
  end

  defp active?(socket) do
    socket.assigns.destination.action in [:youtube, :youtube_video] ||
      (socket.assigns.connections && socket.assigns.connection_view == :youtube)
  end

  defp observe(socket) do
    socket = reload_accounts(socket)

    readouts =
      for account <- socket.assigns.youtube_accounts,
          account.id in socket.assigns.youtube_subscriptions,
          {:ok, snapshot} <- [Lovelace.YouTube.snapshot(account.id, actor: @owner)],
          do: {account, snapshot}

    expected =
      Enum.count(
        socket.assigns.youtube_accounts,
        &(&1.id in socket.assigns.youtube_subscriptions)
      )

    socket =
      assign(socket,
        youtube_readouts: readouts,
        youtube_error: socket.assigns.youtube_accounts_error || length(readouts) != expected
      )

    if account = socket.assigns.youtube_account do
      case Enum.find(readouts, fn {row, _} -> row.id == account.id end) do
        {current, snapshot} ->
          video_id = socket.assigns.destination[:video_id]
          video = Enum.find(snapshot.videos, &(&1["id"] == video_id))

          assign(socket,
            youtube_account: current,
            youtube_snapshot: snapshot,
            youtube_video: video
          )

        nil ->
          socket
          |> Phoenix.LiveView.push_event("youtube:stop", %{})
          |> assign(youtube_snapshot: nil, youtube_video: nil)
      end
    else
      socket
    end
  end

  defp schedule(socket, attempt) do
    cancel(socket.assigns.youtube_observer)

    cond do
      !connected?(socket) ||
          !Enum.any?(socket.assigns.youtube_readouts, fn {_, s} -> s.loading end) ->
        assign(socket, youtube_observer: nil, youtube_observation_stopped: false)

      attempt >= 20 ->
        assign(socket, youtube_observer: nil, youtube_observation_stopped: true)

      true ->
        token = make_ref()
        timer = Process.send_after(self(), {:youtube_observe, token, attempt + 1}, 3_000)
        assign(socket, youtube_observer: {timer, token}, youtube_observation_stopped: false)
    end
  end

  defp cancel({timer, _}), do: Process.cancel_timer(timer)
  defp cancel(nil), do: :ok

  defp subscribe(socket, ids) do
    if connected?(socket) do
      Enum.each(socket.assigns.youtube_subscriptions -- ids, fn id ->
        Phoenix.PubSub.unsubscribe(Lovelace.PubSub, "youtube:#{id}")
        Phoenix.PubSub.unsubscribe(Lovelace.PubSub, "google:#{id}")
      end)

      Enum.each(ids -- socket.assigns.youtube_subscriptions, fn id ->
        Phoenix.PubSub.subscribe(Lovelace.PubSub, "youtube:#{id}")
        Phoenix.PubSub.subscribe(Lovelace.PubSub, "google:#{id}")
      end)
    end

    assign(socket, :youtube_subscriptions, ids)
  end
end
