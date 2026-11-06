defmodule Lovelace.Google.Access do
  @moduledoc """
  Shared Google identity, credential and grant coordination for Gmail, Calendar and YouTube.

  One account/subject serializer owns grant replacement, refresh-token rotation,
  disconnect fencing and synchronous dependent-state reset. Tokens remain in the dedicated
  credential adapter or the admitted caller's memory, never Ash inputs, SQL or jobs.
  Account resources remain exposed through Mail's supported resource actions.
  """
  alias Lovelace.Mail
  alias Lovelace.Mail.{Account, PollWorker, WorkspaceAccount}
  require Ash.Query
  @owner %{role: :local_owner}

  @doc "Serializes shared connection work; nested calls by the same process are supported."
  def serial(id, fun), do: :global.trans({{__MODULE__, id}, self()}, fun, [node()])

  def accept(workspace_id, identity, refresh_token),
    do: accept(workspace_id, identity, refresh_token, :gmail)

  def accept(workspace_id, identity, refresh_token, capability),
    do: accept(workspace_id, identity, refresh_token, capability, nil)

  def accept(workspace_id, identity, refresh_token, capability, expected_generation),
    do: accept(workspace_id, identity, refresh_token, capability, expected_generation, :any)

  @doc "Publishes a grant only if its captured subject connection still matches under both locks."
  def accept(
        workspace_id,
        identity,
        refresh_token,
        capability,
        expected_generation,
        expected_connection
      ),
      do:
        accept(
          workspace_id,
          identity,
          refresh_token,
          capability,
          expected_generation,
          expected_connection,
          %{
            calendar_enabled: capability == :calendar,
            youtube_enabled: capability == :youtube
          }
        )

  def accept(
        workspace_id,
        %{subject: subject, email: email},
        refresh_token,
        capability,
        expected_generation,
        expected_connection,
        grants
      )
      when (refresh_token == :reuse_existing or
              (is_binary(refresh_token) and byte_size(refresh_token) > 0)) and
             capability in [:gmail, :calendar, :youtube] and is_map(grants) do
    case Lovelace.Workspaces.get_workspace(workspace_id, actor: @owner) do
      {:ok, _} ->
        serial({:subject, :crypto.hash(:sha256, subject)}, fn ->
          accept_identity(
            workspace_id,
            subject,
            email,
            refresh_token,
            capability,
            expected_generation,
            expected_connection,
            grants
          )
        end)

      _ ->
        {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def accept(_, _, _, _, _, _, _), do: {:error, :reconnect}

  defp accept_identity(
         workspace_id,
         subject,
         email,
         token,
         capability,
         expected_generation,
         expected_connection,
         grants
       ) do
    with {:ok, previous} <- Mail.find_account(subject, actor: @owner) do
      id = if previous, do: previous.id, else: Ash.UUID.generate()

      serial(id, fn ->
        commit(
          workspace_id,
          id,
          {subject, email},
          token,
          capability,
          expected_generation,
          expected_connection,
          grants
        )
      end)
    end
  end

  defp commit(
         workspace_id,
         id,
         {subject, email},
         token,
         capability,
         expected_generation,
         expected_connection,
         grants
       ) do
    with :ok <- expected_connection(subject, id, expected_connection),
         :ok <- current_grant(id, capability, expected_generation),
         {:ok, prior} <- read_prior(id),
         :ok <- persist_token(id, token, prior) do
      case persist_connection(workspace_id, id, subject, email, grants) do
        {:ok, account} ->
          reset(id)
          PollWorker.enqueue(account)
          broadcast(id)
          {:ok, account}

        _ ->
          restore_failure(id, prior)
      end
    end
  end

  defp expected_connection(_, _, :any), do: :ok

  defp expected_connection(subject, _, :absent) do
    case Mail.find_account(subject, actor: @owner) do
      {:ok, nil} -> :ok
      _ -> {:error, :reconnect}
    end
  end

  defp expected_connection(subject, id, %{id: expected_id, generation: generation})
       when id == expected_id do
    case Mail.find_account(subject, actor: @owner) do
      {:ok, %{id: ^id, generation: ^generation}} -> :ok
      _ -> {:error, :reconnect}
    end
  end

  defp expected_connection(_, _, _), do: {:error, :reconnect}

  # Optional consent cannot resurrect a disconnected or replaced generation.
  defp current_grant(id, capability, expected)
       when capability in [:calendar, :youtube] and not is_nil(expected) do
    if current?(id, expected), do: :ok, else: {:error, :reconnect}
  end

  # A deliberately disconnected account may reconnect, but an old callback may
  # never replace a generation installed after its admission.
  defp current_grant(id, :gmail, expected) when not is_nil(expected) do
    case Mail.get_account(id, actor: @owner) do
      {:ok, %{generation: ^expected}} -> :ok
      _ -> {:error, :reconnect}
    end
  end

  defp current_grant(_, _, _), do: :ok

  @doc "Checks the immutable shared generation without accessing credentials."
  def current?(id, generation) do
    case Mail.get_account(id, actor: @owner) do
      {:ok, %{generation: ^generation, status: status}} when status != :disconnected -> true
      _ -> false
    end
  end

  @doc """
  Publishes shared Google connection health to Gmail and optional-capability observers.

  Call after persisting connection or health changes so each subscriber can re-read
  the authoritative account without sharing ownership of another integration's topic.
  """
  def broadcast(id) do
    Phoenix.PubSub.broadcast(Lovelace.PubSub, "mail:#{id}", {:mail_changed, id})
    broadcast_health(id)
  end

  @doc "Invalidates dependent health projections without initiating a Gmail view refresh."
  def broadcast_health(id) do
    Phoenix.PubSub.broadcast(Lovelace.PubSub, "google:#{id}", {:google_changed, id})
  end

  @doc "Resets dependent integration state synchronously; caller holds serial/2."
  def reset(id) do
    Lovelace.Calendar.clear(id)
    Lovelace.YouTube.clear(id)
  end

  @doc "Fences existing grants before replacing the shared Desktop client; OAuth admission is paused."
  def client_changed do
    fence_client_page(nil)
  rescue
    _ -> {:error, :unavailable}
  end

  defp fence_client_page(after_id) do
    query =
      Account
      |> Ash.Query.for_read(:read, %{}, actor: @owner)
      |> Ash.Query.select([:id])
      |> Ash.Query.unset(:sort)
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(100)

    query = if after_id, do: Ash.Query.filter(query, id > ^after_id), else: query

    with {:ok, accounts} <- Ash.read(query),
         :ok <- fence_client_accounts(accounts) do
      if length(accounts) == 100,
        do: fence_client_page(List.last(accounts).id),
        else: :ok
    else
      _ -> {:error, :unavailable}
    end
  end

  defp fence_client_accounts(accounts) do
    Enum.reduce_while(accounts, :ok, fn account, :ok ->
      case serial(account.id, fn -> fence_client(account.id) end) do
        :ok -> {:cont, :ok}
        _ -> {:halt, {:error, :unavailable}}
      end
    end)
  end

  defp fence_client(id) do
    case Mail.get_account(id, actor: @owner) do
      {:ok, %{status: :disconnected}} ->
        # Keep the generation owned by any admitted credential cleanup.
        reset(id)
        :ok

      {:ok, account} ->
        fence_client_account(account)

      _ ->
        {:error, :unavailable}
    end
  end

  defp fence_client_account(account) do
    with {:ok, _} <-
           Mail.update_account(
             account,
             %{
               expected_generation: account.generation,
               generation: Ash.UUID.generate(),
               status: :reconnect,
               calendar_enabled: false,
               youtube_enabled: false,
               last_error: :reconnect,
               inbox_unread_count: nil,
               inbox_unread_recent_count: nil,
               inbox_unread_at: nil,
               inbox_unread_error: nil
             },
             actor: @owner
           ) do
      reset(account.id)
      broadcast(account.id)
      :ok
    end
  end

  defp restore_failure(id, prior) do
    case restore(id, prior) do
      :ok -> {:error, :unavailable}
      _ -> {:error, {:keychain, :rollback_failed}}
    end
  end

  defp persist_connection(workspace_id, id, subject, email, grants) do
    Ash.transact([Account, WorkspaceAccount], fn ->
      account =
        Mail.save_connection!(
          %{
            id: id,
            subject: subject,
            email: email,
            generation: Ash.UUID.generate(),
            calendar_enabled: Map.get(grants, :calendar_enabled, false) == true,
            youtube_enabled: Map.get(grants, :youtube_enabled, false) == true
          },
          actor: @owner
        )

      Mail.attach_account!(%{workspace_id: workspace_id, account_id: account.id}, actor: @owner)
      account
    end)
  rescue
    _ -> {:error, :unavailable}
  end

  defp read_prior(id) do
    case vault().get(id) do
      {:ok, value} -> {:ok, {:present, value}}
      {:error, :not_found} -> {:ok, :absent}
      {:error, reason} -> {:error, {:keychain, reason}}
      _ -> {:error, {:keychain, :unavailable}}
    end
  end

  # Resolve reuse under the shared account lock, never from an earlier callback snapshot.
  defp persist_token(_, :reuse_existing, {:present, token})
       when is_binary(token) and byte_size(token) > 0, do: :ok

  defp persist_token(_, :reuse_existing, _), do: {:error, :reconnect}
  defp persist_token(id, token, _), do: write_token(id, token)

  defp write_token(id, token) do
    case vault().put(id, token) do
      :ok -> :ok
      {:error, reason} -> {:error, {:keychain, reason}}
      _ -> {:error, {:keychain, :unavailable}}
    end
  end

  defp restore(id, {:present, value}), do: vault().put(id, value)
  defp restore(id, :absent), do: vault().delete(id)

  @doc "Reports only safe local credential status; does not refresh or probe Google."
  def check_credentials(id, generation) do
    if current?(id, generation) do
      status = credential_status(id)
      if current?(id, generation), do: status, else: :changed
    else
      :changed
    end
  end

  defp credential_status(id) do
    case vault().get(id) do
      {:ok, token} when is_binary(token) and byte_size(token) > 0 ->
        :accessible

      {:error, reason}
      when reason in [
             :not_found,
             :locked,
             :timeout,
             :unavailable,
             :invalid_account,
             :invalid_value
           ] ->
        reason

      _ ->
        :unavailable
    end
  rescue
    _ -> :unavailable
  catch
    _, _ -> :unavailable
  end

  @doc "Refreshes the shared credential only for the current ready, admitted generation."
  def access_token(account) do
    serial(account.id, fn ->
      actor = %{role: :mail_service, account_id: account.id}

      with {:ok, current} <-
             Account
             |> Ash.Query.for_read(:scoped, %{account_id: account.id}, actor: actor)
             |> Ash.read_one(),
           true <- current && current.status == :ready && current.generation == account.generation,
           false <- cooldown?(current),
           {:ok, refresh_token} <- credential(account.id),
           {:ok, tokens} <- provider().refresh(refresh_token),
           :ok <- rotate(account.id, tokens) do
        {:ok, tokens.access_token}
      else
        true -> {:error, :cooldown}
        false -> {:error, :unavailable}
        nil -> {:error, :unavailable}
        {:error, :not_found} -> {:error, :reconnect}
        {:error, reason} -> {:error, reason}
        _ -> {:error, :keychain}
      end
    end)
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Shared credential admission gate; Calendar retains its own provider cooldown separately."
  def cooldown?(%{last_error: :rate_limited, next_poll_at: %DateTime{} = deadline}),
    do: DateTime.compare(deadline, DateTime.utc_now()) == :gt

  def cooldown?(_), do: false

  defp credential(id) do
    case vault().get(id) do
      {:ok, token} -> {:ok, token}
      {:error, :not_found} -> {:error, :not_found}
      _ -> {:error, :keychain}
    end
  end

  defp rotate(id, %{refresh_token: token}) when is_binary(token) and byte_size(token) > 0 do
    if vault().put(id, token) == :ok, do: :ok, else: {:error, :keychain}
  end

  defp rotate(_, _), do: :ok

  @doc false
  def provider, do: Application.get_env(:lovelace, :gmail_provider, Lovelace.Integrations.Google)

  @doc false
  def vault,
    do: Application.get_env(:lovelace, :gmail_vault, Lovelace.Integrations.Google.Keychain)
end
