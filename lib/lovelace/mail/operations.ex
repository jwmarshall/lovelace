defmodule Lovelace.Mail.Operations do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  require Ash.Query

  alias Lovelace.Google.Access
  alias Lovelace.Mail
  alias Lovelace.Mail.{Account, CacheEntry, Disconnects, Reads}
  alias Lovelace.Security.Vault

  @max_entries 120
  @max_bytes 25 * 1024 * 1024
  @ttl 7 * 24 * 60 * 60

  @impl true
  def run(input, _, context) do
    Vault.with_access(fn ->
      execute(input.action.name, input.arguments, context.actor)
    end)
  rescue
    _ -> {:ok, failure(:unavailable)}
  catch
    _, _ -> {:ok, failure(:unavailable)}
  end

  defp execute(:link, args, actor) do
    with {:ok, _} <- Lovelace.Workspaces.get_workspace(args.workspace_id, actor: actor),
         {:ok, %{status: :ready}} <- Mail.get_account(args.account_id, actor: actor),
         {:ok, _} <-
           Mail.attach_account(Map.take(args, [:workspace_id, :account_id]), actor: actor) do
      {:ok, true}
    else
      _ -> {:ok, false}
    end
  end

  defp execute(:unlink, args, actor) do
    memberships(args.workspace_id, actor)
    |> Enum.filter(&(&1.account_id == args.account_id))
    |> Enum.each(&Mail.detach_account!(&1, actor: actor))

    broadcast(args.account_id)
    {:ok, true}
  end

  defp execute(:check_credentials, args, %{role: :local_owner}) do
    {:ok, %{status: Access.check_credentials(args.account_id, args.generation)}}
  end

  defp execute(:disconnect, args, actor), do: Disconnects.accept(args.account_id, actor)

  defp execute(:disconnect_status, args, actor), do: Disconnects.observe(args.account_id, actor)

  defp execute(:finish_disconnect, args, %{role: :mail_cleanup}),
    do: {:ok, Disconnects.perform(args.operation_id) == :ok}

  defp execute(:request_read, args, actor), do: Reads.request(args, actor)

  defp execute(:read_status, args, actor),
    do: Reads.observe(args.operation_id, actor)

  defp execute(:cancel_read, args, _actor),
    do: {:ok, Reads.cancel(args.operation_id)}

  defp execute(:perform_read, args, %{role: :mail_read}),
    do: {:ok, Reads.perform(args.operation_id) == :ok}

  defp execute(:poll, args, %{role: :mail_service, account_id: id} = actor)
       when id == args.account_id do
    case scoped_account(id, actor) do
      {:ok, %{status: :ready, generation: generation} = account}
      when generation == args.generation ->
        unread_error = fetch_unread(account, actor)

        result =
          account
          |> fetch(page_key(nil, nil), fn token -> provider().inbox(token, nil) end, true, actor)
          |> poll_result(unread_error)

        broadcast(id)
        {:ok, if(same_connection?(account, actor), do: result, else: failure(:unavailable))}

      _ ->
        {:ok, %{skipped: true}}
    end
  end

  defp execute(:poll, _, _), do: {:ok, failure(:unavailable)}

  defp execute(action, args, actor) when action in [:page, :thread] do
    with true <- member?(args.workspace_id, args.account_id, actor),
         {:ok, %{status: :ready} = account} <- Mail.get_account(args.account_id, actor: actor) do
      {key, request} = request(action, args)
      result = fetch(account, key, request, args.force, actor)

      # A detach/disconnect or reconnect while HTTP was running invalidates the result.
      if member?(args.workspace_id, args.account_id, actor) and same_connection?(account, actor) do
        {:ok, result}
      else
        {:ok, failure(:unavailable)}
      end
    else
      {:ok, %{status: :reconnect}} -> {:ok, failure(:reconnect)}
      _ -> {:ok, failure(:unavailable)}
    end
  end

  defp execute(:attachment, args, %{role: :local_owner} = actor) do
    with {:ok, %{status: :ready} = account} <- Mail.get_account(args.account_id, actor: actor),
         {:ok, metadata} <-
           attachment_metadata(
             account,
             args.thread_id,
             args.message_id,
             args.attachment_id,
             actor
           ),
         true <- metadata["size"] <= 5 * 1024 * 1024,
         :ok <- admit_request(account, actor),
         {:ok, token} <- Access.access_token(account),
         :ok <- admit_request(account, actor),
         {:ok, bytes} <- provider().attachment(token, args.message_id, args.attachment_id),
         true <- byte_size(bytes) <= 5 * 1024 * 1024,
         true <- metadata["size"] == 0 or metadata["size"] == byte_size(bytes),
         {:ok, _current} <- current_account(account, actor) do
      {:ok,
       %{
         attachment_id: metadata["attachment_id"],
         filename: metadata["filename"],
         mime_type: metadata["mime_type"],
         bytes: bytes,
         size: byte_size(bytes)
       }}
    else
      {:error, reason} -> {:ok, failure(safe_reason(reason))}
      false -> {:ok, failure(:unavailable)}
      _ -> {:ok, failure(:unavailable)}
    end
  end

  defp execute(action, args, %{role: :local_owner} = actor)
       when action in [:account_page, :account_thread] do
    case Mail.get_account(args.account_id, actor: actor) do
      {:ok, %{status: :ready} = account} ->
        kind = if action == :account_page, do: :page, else: :thread
        {key, request} = request(kind, args)
        result = fetch(account, key, request, args.force, actor)

        if same_connection?(account, actor), do: {:ok, result}, else: {:ok, failure(:unavailable)}

      {:ok, %{status: :reconnect}} ->
        {:ok, failure(:reconnect)}

      _ ->
        {:ok, failure(:unavailable)}
    end
  end

  defp attachment_metadata(account, thread_id, message_id, attachment_id, actor) do
    with %{payload: %{"messages" => messages}} <- cache(account, "thread:" <> thread_id, actor),
         message when is_map(message) <- Enum.find(messages, &(&1["id"] == message_id)),
         attachment when is_map(attachment) <-
           Enum.find(Map.get(message, "attachments", []), &(&1["attachment_id"] == attachment_id)) do
      {:ok, attachment}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp request(:page, args) do
    query = Map.get(args, :query)
    page = Map.get(args, :page_token)

    fun =
      if query in [nil, ""],
        do: fn token -> provider().inbox(token, page) end,
        else: fn token -> provider().search(token, query, page) end

    {page_key(query, page), fun}
  end

  defp request(:thread, args),
    do: {"thread:" <> args.thread_id, fn token -> provider().thread(token, args.thread_id) end}

  defp page_key(query, page),
    do:
      "page:" <> Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary({query || "", page})))

  defp fetch(account, key, request, force, actor) do
    prune(account.id, actor)
    cached = cache(account, key, actor)

    case current_account(account, actor) do
      {:ok, current} ->
        cond do
          cooldown?(current) ->
            cached_failure(cached, :rate_limited)

          cached && !force && !legacy_thread_cache?(key, cached) &&
              DateTime.diff(DateTime.utc_now(), cached.fetched_at) < 180 ->
            cached_result(cached, true, current)

          true ->
            fetch_remote(current, key, request, cached, actor)
        end

      _ ->
        failure(:unavailable)
    end
  end

  defp fetch_remote(account, key, request, cached, actor) do
    with {:ok, token} <- Access.access_token(account),
         :ok <- admit_request(account, actor),
         {:ok, payload} <- request.(token),
         {:ok, entry} <- publish(account, key, payload, actor),
         {:ok, current} <- current_account(account, actor) do
      cached_result(entry, false, current)
    else
      # Admission refusal is not a fresh provider 429. In particular, if its
      # deadline expires before this branch runs, do not create a new cooldown.
      {:error, :cooldown} -> cached_failure(cached, :rate_limited)
      {:error, reason} -> failed_fetch(account, cached, reason, actor)
      _ -> failed_fetch(account, cached, :unavailable, actor)
    end
  end

  # Count health belongs to this observation, not to whichever page/thread most
  # recently succeeded. HTTP and token access stay outside the short write transaction.
  defp fetch_unread(account, actor) do
    with :ok <- admit_request(account, actor),
         {:ok, token} <- Access.access_token(account),
         :ok <- admit_request(account, actor),
         {:ok, count} <- request_unread(token),
         {:ok, error} when error in [nil, :rate_limited] <- publish_unread(account, count, actor) do
      error
    else
      {:error, :cooldown} -> unread_failure(account, :rate_limited, actor, false)
      {:error, reason} -> unread_failure(account, reason, actor, true)
      _ -> unread_failure(account, :provider, actor, true)
    end
  end

  defp request_unread(token) do
    case provider().inbox_unread(token) do
      {:ok, %{total: total, recent: recent} = counts}
      when is_integer(total) and total >= 0 and is_integer(recent) and recent >= 0 ->
        {:ok, counts}

      {:error, reason} ->
        {:error, safe_reason(reason)}

      _ ->
        {:error, :provider}
    end
  rescue
    _ -> {:error, :provider}
  catch
    _, _ -> {:error, :provider}
  end

  defp publish_unread(account, count, actor) do
    result =
      Ash.transact(Account, fn -> publish_current_unread(account, count, actor) end)

    case result do
      {:ok, outcome} -> outcome
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp publish_current_unread(account, count, actor) do
    with {:ok, current} <- current_account(account, actor) do
      error = if cooldown?(current), do: :rate_limited

      case Mail.update_account(
             current,
             %{
               expected_generation: account.generation,
               inbox_unread_count: count.total,
               inbox_unread_recent_count: count.recent,
               inbox_unread_at: DateTime.utc_now(),
               inbox_unread_error: error
             },
             actor: actor
           ) do
        {:ok, _} -> {:ok, error}
        _ -> {:error, :unavailable}
      end
    end
  end

  defp unread_failure(account, reason, actor, persist?) do
    reason = safe_reason(reason)

    result =
      Ash.transact(Account, fn -> persist_unread_failure(account, reason, actor, persist?) end)

    case result do
      {:ok, {:ok, _}} -> reason
      _ -> :unavailable
    end
  end

  defp persist_unread_failure(account, reason, actor, persist?) do
    with {:ok, current} <- current_account(account, actor) do
      error = if cooldown?(current), do: :rate_limited, else: reason

      fields =
        if persist?,
          do: failure_fields(current, reason),
          else: %{expected_generation: account.generation}

      Mail.update_account(current, Map.put(fields, :inbox_unread_error, error), actor: actor)
    end
  end

  defp poll_result(result, nil), do: result

  defp poll_result(%{error: error} = result, unread_error) do
    # Rate limiting and reconnect remain terminal; other count failures use the
    # existing bounded worker retry path even when the inbox page succeeded.
    error =
      cond do
        error in [:rate_limited, :reconnect] -> error
        unread_error in [:rate_limited, :reconnect] -> unread_error
        true -> error || unread_error
      end

    Map.merge(result, %{error: error, stale: true})
  end

  defp admit_request(account, actor) do
    with {:ok, current} <- current_account(account, actor) do
      if cooldown?(current), do: {:error, :cooldown}, else: :ok
    end
  end

  defp cooldown?(account), do: Access.cooldown?(account)

  defp cached_result(entry, cached, %{last_error: error}) when not is_nil(error),
    do: Map.merge(result(entry, cached), %{error: error, stale: true})

  defp cached_result(entry, cached, _), do: result(entry, cached)

  defp cached_failure(nil, reason), do: failure(reason)

  defp cached_failure(entry, reason),
    do: Map.merge(result(entry, true), %{error: reason, stale: true})

  defp failed_fetch(account, cached, reason, actor) do
    reason = safe_reason(reason)

    # Keep the latest failure/cooldown read and its write in one short SQLite
    # transaction, so a concurrent failure cannot overwrite a newer rate limit.
    case Ash.transact(Account, fn -> persist_failure(account, reason, actor) end) do
      {:ok, {:ok, _}} -> Access.broadcast_health(account.id)
      _ -> :ok
    end

    cached_failure(cached, reason)
  end

  defp persist_failure(account, reason, actor) do
    case current_account(account, actor) do
      {:ok, current} ->
        Mail.update_account(current, failure_fields(current, reason), actor: actor)

      _ ->
        :ok
    end
  end

  defp failure_fields(current, reason) do
    # Reads already in flight must not shorten or extend a known cooldown.
    if cooldown?(current) do
      %{
        expected_generation: current.generation,
        last_error: :rate_limited,
        next_poll_at: current.next_poll_at
      }
    else
      fields = %{
        expected_generation: current.generation,
        last_error: reason,
        next_poll_at:
          DateTime.add(DateTime.utc_now(), if(reason == :rate_limited, do: 300, else: 180))
      }

      if reason == :reconnect, do: Map.put(fields, :status, :reconnect), else: fields
    end
  end

  defp publish(account, key, payload, actor) do
    json = Jason.encode!(payload)

    if byte_size(json) > 5 * 1024 * 1024 do
      {:error, :provider}
    else
      Ash.transact([Account, CacheEntry], fn -> publish_current(account, key, json, actor) end)
    end
  end

  defp publish_current(account, key, json, actor) do
    case current_account(account, actor) do
      {:ok, current} ->
        now = DateTime.utc_now()
        limited = cooldown?(current)

        entry =
          CacheEntry
          |> Ash.Changeset.for_create(
            :store,
            %{
              account_id: account.id,
              key: key,
              payload: Jason.decode!(json),
              bytes: byte_size(json),
              generation: account.generation,
              fetched_at: now,
              expires_at: DateTime.add(now, @ttl)
            },
            actor: actor
          )
          |> Ash.create!()

        Mail.update_account!(
          account,
          %{
            expected_generation: account.generation,
            last_success_at: now,
            last_error: if(limited, do: :rate_limited, else: nil),
            next_poll_at: if(limited, do: current.next_poll_at, else: DateTime.add(now, 180))
          },
          actor: actor
        )

        prune(account.id, actor)
        entry

      _ ->
        {:error, :unavailable}
    end
  end

  defp result(entry, cached),
    do: %{
      data: entry.payload,
      fetched_at: entry.fetched_at,
      cached: cached,
      stale: DateTime.diff(DateTime.utc_now(), entry.fetched_at) >= 180,
      error: nil
    }

  defp failure(reason), do: %{data: nil, error: reason, stale: true, fetched_at: nil}

  # Thread cache entries from before attachment metadata was introduced can still
  # contain readable bodies. Revalidate them rather than treating them as fresh,
  # while retaining the stale body if Gmail is temporarily unavailable.
  defp legacy_thread_cache?("thread:" <> _thread_id, %{payload: %{"messages" => messages}})
       when is_list(messages) and messages != [] do
    Enum.any?(messages, fn message ->
      not is_map(message) or not is_list(Map.get(message, "attachments"))
    end)
  end

  defp legacy_thread_cache?(_, _), do: false

  defp cache(account, key, actor) do
    CacheEntry
    |> Ash.Query.for_read(:read, %{account_id: account.id}, actor: actor)
    |> Ash.Query.filter(
      key == ^key and generation == ^account.generation and expires_at > ^DateTime.utc_now()
    )
    |> Ash.read_one!()
  end

  @doc false
  def prune(account_id, actor) do
    entries =
      CacheEntry
      |> Ash.Query.for_read(:read, %{account_id: account_id}, actor: actor)
      |> Ash.Query.sort(fetched_at: :desc, id: :desc)
      |> Ash.Query.select([:account_id, :bytes, :expires_at, :fetched_at])
      |> Ash.read!()

    _retained =
      Enum.reduce(entries, {0, 0}, fn entry, {count, bytes} = retained ->
        if DateTime.compare(entry.expires_at, DateTime.utc_now()) != :gt or
             count >= @max_entries or bytes + entry.bytes > @max_bytes do
          entry |> Ash.Changeset.for_destroy(:evict, %{}, actor: actor) |> Ash.destroy!()
          retained
        else
          {count + 1, bytes + entry.bytes}
        end
      end)

    :ok
  end

  @doc false
  def member?(workspace_id, account_id, actor),
    do: Enum.any?(memberships(workspace_id, actor), &(&1.account_id == account_id))

  defp memberships(workspace_id, actor), do: Mail.workspace_accounts!(workspace_id, actor: actor)

  defp scoped_account(id, %{role: :local_owner} = actor), do: Mail.get_account(id, actor: actor)

  defp scoped_account(id, actor) do
    Account |> Ash.Query.for_read(:scoped, %{account_id: id}, actor: actor) |> Ash.read_one()
  end

  defp same_connection?(account, actor) do
    case scoped_account(account.id, actor) do
      {:ok, %{status: status, generation: generation}} when status in [:ready, :reconnect] ->
        generation == account.generation

      _ ->
        false
    end
  end

  defp current_account(account, actor) do
    case scoped_account(account.id, actor) do
      {:ok, %{status: :ready, generation: generation} = current}
      when generation == account.generation ->
        {:ok, current}

      _ ->
        {:error, :unavailable}
    end
  end

  @doc false
  def broadcast(id), do: Access.broadcast(id)

  defp provider, do: Access.provider()

  defp safe_reason(reason) when reason in [:invalid_grant, :unauthorized, :reconnect],
    do: :reconnect

  defp safe_reason(reason) when reason in [:rate_limited, :keychain, :provider], do: reason
  defp safe_reason(_), do: :unavailable
end
