defmodule Lovelace.Mail.Disconnects do
  @moduledoc false
  alias Lovelace.Google.Access
  alias Lovelace.Mail
  alias Lovelace.Mail.{Account, CacheEntry, Disconnection, DisconnectWorker, WorkspaceAccount}
  alias Lovelace.Security.Vault
  @owner %{role: :local_owner}

  def accept(id, actor) do
    Access.serial(id, fn -> accept_serial(id, actor) end)
  end

  defp accept_serial(id, actor) do
    with {:ok, account} <- Mail.get_account(id, actor: actor) do
      Ash.transact([Account, CacheEntry, WorkspaceAccount, Disconnection], fn ->
        resume_or_accept(account, actor)
      end)
      |> accepted(id)
    end
  end

  defp resume_or_accept(account, actor) do
    case latest(account.id) do
      %{generation: generation} = operation when generation == account.generation ->
        resume(operation)

      _ ->
        fence_and_accept(account, actor)
    end
  end

  defp accepted({:ok, operation}, id) do
    Access.reset(id)
    notify(id)
    {:ok, public(operation)}
  end

  defp accepted(_, _id), do: {:error, :unavailable}

  def observe(id, actor) do
    with {:ok, _} <- Mail.get_account(id, actor: actor) do
      {:ok,
       case latest(id) do
         nil -> %{state: :unavailable}
         operation -> public(operation)
       end}
    end
  end

  def perform(operation_id) do
    Vault.with_access(fn -> perform_serial(operation_id) end)
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp perform_serial(operation_id) do
    case Ash.get(Disconnection, operation_id, actor: @owner, not_found_error?: false) do
      {:ok, nil} ->
        :ok

      {:ok, operation} ->
        Access.serial(operation.account_id, fn -> execute(operation_id) end)

      _ ->
        {:error, :unavailable}
    end
  end

  defp fence_and_accept(account, actor) do
    generation = Ash.UUID.generate()

    attrs = %{
      expected_generation: account.generation,
      generation: generation,
      status: :disconnected,
      calendar_enabled: false,
      youtube_enabled: false,
      inbox_unread_count: nil,
      inbox_unread_recent_count: nil,
      inbox_unread_at: nil,
      inbox_unread_error: nil,
      last_error: :keychain
    }

    Mail.update_account!(account, attrs, actor: actor)

    for entry <-
          Ash.read!(
            Ash.Query.for_read(CacheEntry, :read, %{account_id: account.id}, actor: actor)
          ) do
      entry |> Ash.Changeset.for_destroy(:evict, %{}, actor: actor) |> Ash.destroy!()
    end

    for membership <-
          Ash.read!(
            Ash.Query.for_read(WorkspaceAccount, :for_account, %{account_id: account.id},
              actor: actor
            )
          ) do
      Mail.detach_account!(membership, actor: actor)
    end

    Disconnection
    |> Ash.Changeset.for_create(:accept, %{account_id: account.id, generation: generation},
      actor: actor
    )
    |> Ash.create!()
    |> enqueue()
  end

  defp resume(%{state: :complete, credentials: :removed} = operation), do: operation
  defp resume(operation), do: enqueue(operation)

  defp enqueue(operation) do
    job = Oban.insert!(DisconnectWorker.new(%{operation_id: operation.id}))
    update(operation, %{job_id: job.id, state: :pending})
  end

  defp execute(id) do
    operation = Ash.get!(Disconnection, id, actor: @owner)
    account = Mail.get_account!(operation.account_id, actor: @owner)

    cond do
      operation.state in [:complete, :superseded] ->
        :ok

      account.generation != operation.generation or account.status != :disconnected ->
        update(operation, %{
          state: :superseded,
          credentials: :superseded,
          remote: if(operation.remote == :claimed, do: :uncertain, else: :unavailable)
        })

        notify(account.id)
        :ok

      true ->
        Access.reset(account.id)
        operation = revoke(operation)
        credentials = if remove_credential(account.id), do: :removed, else: :failed

        {:ok, _} =
          Ash.transact([Account, Disconnection], fn ->
            update(operation, %{credentials: credentials, state: :complete})

            attrs = %{
              expected_generation: account.generation,
              last_error: if(credentials == :removed, do: nil, else: :keychain)
            }

            Mail.update_account!(account, attrs, actor: @owner)
          end)

        notify(account.id)
        :ok
    end
  end

  # Persist claim BEFORE crossing the provider boundary. Rescue can clean up the
  # old credential but can never repeat an exchange with an unknown remote outcome.
  defp revoke(%{remote: :pending} = operation) do
    case safe_credential(operation.account_id) do
      {:ok, token} ->
        claimed = update(operation, %{remote: :claimed})

        outcome =
          try do
            if Access.provider().revoke(token) == :ok, do: :revoked, else: :uncertain
          rescue
            _ -> :uncertain
          catch
            _, _ -> :uncertain
          end

        update(claimed, %{remote: outcome})

      _ ->
        update(operation, %{remote: :unavailable})
    end
  end

  defp revoke(%{remote: :claimed} = operation), do: update(operation, %{remote: :uncertain})
  defp revoke(operation), do: operation

  defp safe_credential(id) do
    Access.vault().get(id)
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp remove_credential(id) do
    Access.vault().delete(id) == :ok
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp latest(id) do
    Disconnection
    |> Ash.Query.for_read(:for_account, %{account_id: id}, actor: @owner)
    |> Ash.read!()
    |> List.first()
  end

  defp update(operation, attrs),
    do: operation |> Ash.Changeset.for_update(:outcome, attrs, actor: @owner) |> Ash.update!()

  defp public(operation),
    do: %{
      operation_id: operation.id,
      job_id: operation.job_id,
      state: operation.state,
      local_removed: operation.local_removed,
      credentials_removed: operation.credentials == :removed,
      credentials: operation.credentials,
      remote: operation.remote,
      revoked: operation.remote == :revoked
    }

  defp notify(id),
    do: Phoenix.PubSub.broadcast(Lovelace.PubSub, "mail:#{id}", {:mail_changed, id})
end
