defmodule Lovelace.YouTube.Operations do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  alias Lovelace.Google.Access
  alias Lovelace.{Mail, Security.Vault}
  alias Lovelace.YouTube.{Payload, PollWorker, Snapshot, State}
  @owner %{role: :local_owner}
  @fields [
    :account_id,
    :generation,
    :revision,
    :channels,
    :selected_ids,
    :videos,
    :catalog_at,
    :fetched_at,
    :error,
    :next_poll_at,
    :cooldown_until,
    :loading,
    :truncated,
    :catalog_truncated,
    :job_id,
    :requested_at,
    :started_at
  ]

  @impl true
  def run(input, _, context) do
    Vault.with_access(fn -> execute(input.action.name, input.arguments, context.actor) end)
  rescue
    _ -> failure(input.action.name)
  catch
    _, _ -> failure(input.action.name)
  end

  defp failure(:snapshot), do: {:ok, Snapshot.build(nil, nil, :unavailable)}
  defp failure(_), do: {:error, :unavailable}

  defp execute(:snapshot, args, _) do
    Access.serial(args.account_id, fn ->
      account = account(args.account_id)
      {:ok, Snapshot.build(account, state(args.account_id))}
    end)
  end

  defp execute(action, args, _) when action in [:prepare, :refresh, :select_channels] do
    Access.serial(args.account_id, fn ->
      result = Ash.transact(State, fn -> mutate(action, args) end)
      if match?({:ok, _}, result), do: broadcast(args.account_id)
      result
    end)
  end

  defp execute(:poll, args, actor) do
    if permitted?(actor, args.account_id) do
      case claim(args) do
        {:ok, account, current} ->
          deadline = System.monotonic_time(:millisecond) + 120_000
          publish(args, fetch(account, current, Map.put(args, :deadline, deadline)))

        _ ->
          {:ok, %{skipped: true}}
      end
    else
      {:error, :forbidden}
    end
  end

  defp execute(:sweep, _, _) do
    results =
      Enum.map(read_states(:expired), &prune/1) ++ Enum.map(read_states(:due), &sweep_due/1)

    if Enum.all?(results, &match?({:ok, _}, &1)),
      do: {:ok, %{swept: true}},
      else: {:error, :unavailable}
  end

  defp sweep_due(prior) do
    Access.serial(prior.account_id, fn ->
      Ash.transact(State, fn -> queue_due(prior.account_id) end)
    end)
  end

  defp queue_due(id) do
    account = account(id)
    current = state(id)
    if Snapshot.current?(account, current) && due?(current), do: queue(account, current)
  end

  defp mutate(action, args) do
    account = account(args.account_id)

    if Snapshot.enabled?(account) do
      mutate_enabled(action, args, account)
    else
      if action == :select_channels, do: Ash.DataLayer.rollback(State, :changed)
      Snapshot.build(account, nil)
    end
  end

  defp mutate_enabled(action, args, account) do
    prior = state(account.id)
    check_selection(action, args, account, prior)
    current = if Snapshot.current?(account, prior), do: prior, else: store!(defaults(account))
    current = current |> prune_current() |> mutate_state(action, args, account)
    Snapshot.build(account, current)
  end

  defp check_selection(:select_channels, args, account, prior) do
    if !Snapshot.current?(account, prior) || account.generation != args.generation ||
         prior.revision != args.revision,
       do: Ash.DataLayer.rollback(State, :changed)
  end

  defp check_selection(_, _, _, _), do: :ok

  defp mutate_state(state, :select_channels, args, account), do: select(account, state, args.ids)
  defp mutate_state(state, :refresh, _, account), do: queue(account, state)

  defp mutate_state(state, :prepare, _, account),
    do: if(due?(state), do: queue(account, state), else: state)

  defp select(account, state, ids) do
    ids = Enum.uniq(ids)
    known = Enum.map(state.channels, & &1["id"])
    known = if state.catalog_truncated, do: known ++ state.selected_ids, else: known

    if Snapshot.recent?(state.catalog_at) && length(ids) <= 10 &&
         Enum.all?(ids, &(Payload.channel_id?(&1) && &1 in known)) do
      change_selection(account, state, ids)
    else
      Ash.DataLayer.rollback(State, :invalid_selection)
    end
  end

  defp change_selection(_, %{selected_ids: ids} = state, ids), do: state

  defp change_selection(account, state, ids) do
    cancel(state)

    current =
      put!(state, %{
        selected_ids: ids,
        videos: [],
        fetched_at: nil,
        loading: false,
        job_id: nil,
        revision: Ash.UUID.generate(),
        error: if(cooldown?(state), do: state.error),
        truncated: false
      })

    if ids == [] do
      put!(current, %{fetched_at: DateTime.utc_now(), next_poll_at: next_poll()})
    else
      queue(account, current)
    end
  end

  defp queue(account, state) do
    cond do
      cooldown?(state) or Access.cooldown?(account) ->
        state

      active_job?(state) ->
        state

      true ->
        cancel(state)
        now = DateTime.utc_now()

        current =
          put!(state, %{
            revision: Ash.UUID.generate(),
            loading: true,
            requested_at: now,
            started_at: nil,
            next_poll_at: DateTime.add(now, 900),
            error: nil
          })

        args = Map.take(current, [:account_id, :generation, :revision])

        case PollWorker.new(args) |> Oban.insert() do
          {:ok, job} -> put!(current, %{job_id: job.id})
          _ -> Ash.DataLayer.rollback(State, :unavailable)
        end
    end
  end

  defp active_job?(%{loading: true} = state), do: Snapshot.pending?(state)
  defp active_job?(_), do: false
  defp cancel(%{job_id: id}) when is_integer(id), do: Oban.cancel_job(id)
  defp cancel(_), do: :ok

  defp fetch(account, state, args) do
    with :ok <- admission(args),
         {:ok, token} <- Access.access_token(account),
         :ok <- admission(args) do
      fetch_current(token, state, args)
    end
  rescue
    _ -> {:error, :provider}
  catch
    _, _ -> {:error, :provider}
  end

  defp fetch_current(token, state, args) do
    # Catalog and feed clocks are independent. A catalog observed successfully remains
    # useful even when a later channel fails; old videos keep their original timestamp.
    # Thirteen five-second reads plus the shared thirty-second credential refresh
    # fit inside the finite two-minute whole-snapshot deadline.
    catalog = fetch_catalog(token, args)

    with {:ok, channels, truncated, catalog_at} <- catalog do
      changes =
        if catalog_at,
          do: %{channels: channels, catalog_truncated: truncated, catalog_at: catalog_at},
          else: %{}

      selected = Enum.map(state.selected_ids, &channel(channels, &1))

      case fetch_feed(token, selected, channels, truncated, args) do
        {:ok, videos, partial} ->
          {:ok,
           Map.merge(changes, %{
             videos: videos,
             fetched_at: DateTime.utc_now(),
             truncated: partial
           }), nil}

        {:error, reason} ->
          {:ok, changes, safe_error(reason)}
      end
    end
  end

  defp fetch_catalog(token, args) do
    with :ok <- admission(args),
         {:ok, response} <- provider().subscriptions(token, nil),
         {:ok, first, next} <- Payload.channels(response) do
      finish_catalog(token, args, first, next)
    end
  end

  defp finish_catalog(_, _, first, nil), do: {:ok, first, false, DateTime.utc_now()}

  defp finish_catalog(token, args, first, next) do
    with :ok <- admission(args),
         {:ok, response} <- provider().subscriptions(token, next),
         {:ok, second, last} <- Payload.channels(response) do
      {:ok, Enum.uniq_by(first ++ second, & &1["id"]), last != nil, DateTime.utc_now()}
    end
  end

  defp fetch_feed(_, [], _, _, _), do: {:ok, [], false}

  defp fetch_feed(token, selected, channels, truncated, args) do
    # Bounded catalogs are not proof that an older explicit subscription disappeared.
    # A complete catalog is authoritative: never read a channel no longer subscribed.
    known = MapSet.new(channels, & &1["id"])

    if not truncated && Enum.any?(selected, &(not MapSet.member?(known, &1["id"]))) do
      {:error, :provider}
    else
      fetch_selected(token, selected, args)
    end
  end

  defp fetch_selected(token, selected, args) do
    ids = Enum.map(selected, & &1["id"])

    with :ok <- admission(args),
         {:ok, response} <- provider().uploads_playlists(token, ids),
         {:ok, playlists} <- Payload.playlists(response, ids),
         true <- map_size(playlists) == length(ids) do
      fetch_uploads(token, selected, playlists, args)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :provider}
    end
  end

  defp fetch_uploads(token, selected, playlists, args) do
    Enum.reduce_while(selected, {:ok, [], false}, fn channel, {:ok, videos, partial} ->
      with :ok <- admission(args),
           {:ok, response} <- provider().uploads(token, playlists[channel["id"]]),
           {:ok, rows, limited} <- Payload.videos(response, channel) do
        {:cont, {:ok, rows ++ videos, partial || limited}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, videos, partial} -> {:ok, Payload.bounded(videos), partial}
      error -> error
    end
  end

  defp channel(channels, id),
    do: Enum.find(channels, &(&1["id"] == id)) || %{"id" => id, "title" => id}

  defp claim(args) do
    result = Access.serial(args.account_id, fn -> claim_transaction(args) end)

    case result do
      {:ok, {account, current}} -> {:ok, account, current}
      _ -> {:error, :changed}
    end
  end

  defp claim_transaction(args), do: Ash.transact(State, fn -> claim_current(args) end)

  defp claim_current(args) do
    with {:ok, account, current} <- current_request(args),
         true <- is_nil(current.started_at),
         false <- cooldown?(current),
         false <- Access.cooldown?(account) do
      {account, put!(current, %{started_at: DateTime.utc_now()})}
    else
      _ -> Ash.DataLayer.rollback(State, :changed)
    end
  end

  defp admit(args) do
    Access.serial(args.account_id, fn ->
      with {:ok, account, current} <- current(args),
           false <- cooldown?(current),
           false <- Access.cooldown?(account) do
        {:ok, account, current}
      else
        _ -> {:error, :changed}
      end
    end)
  end

  defp admission(args) do
    if System.monotonic_time(:millisecond) < args.deadline do
      case admit(args) do
        {:ok, _, _} -> :ok
        error -> error
      end
    else
      {:error, :provider}
    end
  end

  defp current(args) do
    with {:ok, account, current} <- current_request(args),
         true <- Snapshot.executing?(current) do
      {:ok, account, current}
    else
      _ -> {:error, :changed}
    end
  end

  defp current_request(args) do
    account = account(args.account_id)
    current = state(args.account_id)

    if Snapshot.current?(account, current) && account.generation == args.generation &&
         current.revision == args.revision && current.loading,
       do: {:ok, account, current},
       else: {:error, :changed}
  end

  defp publish(args, result) do
    Access.serial(args.account_id, fn ->
      Ash.transact(State, fn -> publish_current(args, result) end)
    end)
  end

  defp publish_current(args, result) do
    account = account(args.account_id)
    state = state(args.account_id)

    reason = result_error(result)

    # A quota response remains valid for this connection even if selection changed.
    if reason == :rate_limited && Snapshot.current?(account, state) &&
         account.generation == args.generation do
      publish_rate_limited(args, result, account, state)
    else
      publish_result(args, result)
    end
  end

  defp result_error({:error, reason}), do: safe_error(reason)
  defp result_error({:ok, _, reason}), do: reason

  defp publish_rate_limited(args, result, account, state) do
    deadline = DateTime.add(DateTime.utc_now(), 300)
    deadline = if cooldown?(state), do: max_time(state.cooldown_until, deadline), else: deadline

    changes =
      case {current(args), result} do
        {{:ok, _, _}, {:ok, changes, :rate_limited}} -> changes
        _ -> %{}
      end

    state =
      put!(
        state,
        Map.merge(changes, %{
          error: :rate_limited,
          loading: false,
          cooldown_until: deadline,
          next_poll_at: max_time(state.next_poll_at, deadline)
        })
      )

    broadcast(args.account_id)
    Snapshot.build(account, state)
  end

  defp publish_result(args, result) do
    case current(args) do
      {:ok, account, state} -> publish_current_result(account, state, result)
      _ -> %{skipped: true}
    end
  end

  defp publish_current_result(account, state, result) do
    if cooldown?(state) do
      Snapshot.build(account, state)
    else
      state =
        put!(
          state,
          Map.merge(result_changes(result), %{loading: false, next_poll_at: next_poll()})
        )

      broadcast(account.id)
      Snapshot.build(account, state)
    end
  end

  defp result_changes({:ok, changes, error}), do: Map.put(changes, :error, error)
  defp result_changes({:error, reason}), do: %{error: safe_error(reason)}

  def clear(id) do
    case state(id) do
      nil ->
        :ok

      current ->
        cancel(current)
        result = Ash.destroy(current, action: :clear, actor: @owner)
        broadcast(id)
        result
    end
  end

  defp prune(prior) do
    Access.serial(prior.account_id, fn ->
      result = Ash.transact(State, fn -> prune_account(prior.account_id) end)

      if match?({:ok, _}, result), do: broadcast(prior.account_id)
      result
    end)
  end

  defp prune_account(id) do
    if current = state(id), do: prune_current(current)
  end

  defp prune_current(state) do
    changes =
      if state.fetched_at && not Snapshot.recent?(state.fetched_at),
        do: %{videos: [], fetched_at: nil},
        else: %{}

    changes =
      if state.catalog_at && not Snapshot.recent?(state.catalog_at),
        do: Map.merge(changes, %{channels: [], catalog_at: nil, catalog_truncated: false}),
        else: changes

    if map_size(changes) > 0, do: put!(state, changes), else: state
  end

  defp defaults(account),
    do: %{
      account_id: account.id,
      generation: account.generation,
      revision: Ash.UUID.generate(),
      channels: [],
      selected_ids: [],
      videos: [],
      catalog_at: nil,
      fetched_at: nil,
      error: nil,
      next_poll_at: DateTime.utc_now(),
      cooldown_until: nil,
      loading: false,
      truncated: false,
      catalog_truncated: false,
      job_id: nil,
      requested_at: nil,
      started_at: nil
    }

  defp account(id) do
    case Mail.get_account(id, actor: @owner) do
      {:ok, account} -> account
      _ -> nil
    end
  end

  defp state(id),
    do: State |> Ash.Query.for_read(:read, %{account_id: id}, actor: @owner) |> Ash.read_one!()

  defp read_states(action),
    do: State |> Ash.Query.for_read(action, %{}, actor: @owner) |> Ash.read!()

  defp store!(attrs),
    do: State |> Ash.Changeset.for_create(:store, attrs, actor: @owner) |> Ash.create!()

  defp put!(state, changes), do: state |> Map.take(@fields) |> Map.merge(changes) |> store!()
  defp next_poll, do: DateTime.add(DateTime.utc_now(), 900)

  defp due?(state) do
    DateTime.compare(state.next_poll_at, DateTime.utc_now()) != :gt ||
      (state.loading && !active_job?(state))
  end

  defp max_time(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

  defp cooldown?(%{cooldown_until: %DateTime{} = at}),
    do: DateTime.compare(at, DateTime.utc_now()) == :gt

  defp cooldown?(_), do: false
  defp permitted?(%{role: :local_owner}, _), do: true
  defp permitted?(%{role: :mail_service, account_id: id}, id), do: true
  defp permitted?(_, _), do: false

  defp safe_error(reason) when reason in [:rate_limited, :reconnect, :keychain, :unavailable],
    do: reason

  defp safe_error(reason)
       when reason in [:invalid_grant, :unauthorized, :forbidden, :insufficient_permissions],
       do: :reconnect

  defp safe_error(:cooldown), do: :rate_limited
  defp safe_error(_), do: :provider

  defp provider,
    do: Application.get_env(:lovelace, :youtube_provider, Lovelace.Integrations.Google.YouTube)

  defp broadcast(id),
    do: Phoenix.PubSub.broadcast(Lovelace.PubSub, "youtube:" <> id, {:youtube_changed, id})
end
