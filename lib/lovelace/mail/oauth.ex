defmodule Lovelace.Mail.OAuth do
  @moduledoc "Bounded protected OAuth secrets; jobs own execution, this process only admits/claims/fences."
  use GenServer
  alias Lovelace.Mail.{Account, ConnectionDiagnostics, OAuthExchange}
  alias Lovelace.Security.{Secret, Vault}
  @ttl 600_000
  @owner %{role: :local_owner}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def client_change(fun) do
    if Process.whereis(__MODULE__) do
      with {:ok, ticket} <- call({:client_changing, self()}) do
        try do
          fun.()
        after
          call({:client_changed, ticket})
        end
      end
    else
      fun.()
    end
  end

  def begin(
        workspace,
        session,
        expected \\ nil,
        capability \\ :gmail,
        generation \\ nil,
        origin \\ :connections
      ) do
    with {:ok, state, verifier, _capabilities} <-
           begin_attempt(workspace, session, expected, capability, generation, origin) do
      {:ok, state, verifier}
    end
  end

  defp begin_attempt(workspace, session, expected, capability, generation, origin) do
    if capability in [:gmail, :calendar, :youtube] and origin in [:connections, :onboarding] and
         not (capability == :youtube and origin == :onboarding) and
         valid_optional_binding?(capability, expected, generation) do
      with {:ok, snapshot} <- connection_snapshot(expected),
           {:ok, capabilities} <- requested_capabilities(expected, capability, generation) do
        call(
          {:begin, workspace, digest(session), expected, capability, generation, origin, snapshot,
           capabilities}
        )
      end
    else
      {:error, :invalid_request}
    end
  end

  defp valid_optional_binding?(:gmail, _, _), do: true

  defp valid_optional_binding?(_, expected, generation),
    do: is_binary(expected) and expected != "" and is_binary(generation) and generation != ""

  def authorization_url(workspace, session, expected, capability, generation, origin) do
    with {:ok, state, verifier, capabilities} <-
           begin_attempt(workspace, session, expected, capability, generation, origin) do
      Lovelace.Google.Access.provider().authorization_url(%{
        state: state,
        verifier: verifier,
        redirect_uri: callback_url(),
        capability: capability,
        capabilities: capabilities
      })
    end
  end

  def cancel(state, session), do: call({:cancel, digest(state), digest(session)})

  def complete(state, session, params) do
    with {:ok, %{id: id}} <- admit(state, session, params),
         do: Lovelace.OAuth.await(id, __MODULE__)
  end

  def admit(state, session, params) do
    with {:ok, _} <- Lovelace.Owner.verify_session(session),
         {:ok, id} <- call({:prepare, digest(state), %Secret{value: {session, params}}}),
         {:ok, reference} <- enqueue(id) do
      {:ok, reference}
    else
      {:error, {_, _}} = error -> error
      _ -> ConnectionDiagnostics.failure(:state, :invalid_state)
    end
  end

  defp enqueue(id) do
    case Lovelace.OAuth.exchange(id, :google, actor: @owner) do
      {:ok, _} = accepted ->
        accepted

      _ ->
        call({:settle, id, {:error, {:connection, :unavailable}}})
        {:error, :unavailable}
    end
  end

  def result(id), do: call({:result, id})
  def commit(id, fun), do: call({:commit, id, %Secret{value: fun}})

  def execute(id) do
    result =
      case call({:claim, id}) do
        {:ok, %Secret{value: attempt}} ->
          OAuthExchange.execute(attempt, attempt.params, attempt.session)

        _ ->
          ConnectionDiagnostics.failure(:state, :reconnect)
      end

    call({:settle, id, result})
    result
  rescue
    _ -> ConnectionDiagnostics.failure(:callback, :unexpected)
  catch
    _, _ -> ConnectionDiagnostics.failure(:state, :reconnect)
  end

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:client_changing, owner}, _, attempts) do
    if changing?() do
      {:reply, {:error, :unavailable}, attempts}
    else
      ticket = make_ref()
      Process.put(:client_change, {ticket, Process.monitor(owner)})
      {:reply, {:ok, ticket}, %{}}
    end
  end

  def handle_call({:client_changed, ticket}, _, attempts) do
    case Process.get(:client_change) do
      {^ticket, monitor} ->
        Process.demonitor(monitor, [:flush])
        Process.delete(:client_change)

      _ ->
        :ok
    end

    {:reply, :ok, attempts}
  end

  def handle_call(
        {:begin, workspace, session, expected, capability, generation, origin, snapshot,
         capabilities},
        _,
        attempts
      ) do
    attempts = live(attempts)

    if changing?() or map_size(attempts) >= 100 do
      {:reply, {:error, :busy}, attempts}
    else
      state = random()
      verifier = random()

      attempt = %{
        id: Ash.UUID.generate(),
        workspace_id: workspace,
        session_digest: session,
        expected_account_id: expected,
        capability: capability,
        requested_capabilities: capabilities,
        expected_generation: generation,
        origin: origin,
        verifier: %Secret{value: verifier},
        connection_snapshot: snapshot,
        callback_url: callback_url(),
        status: :pending,
        expires: now() + @ttl
      }

      {:reply, {:ok, state, verifier, capabilities}, Map.put(attempts, digest(state), attempt)}
    end
  end

  def handle_call({:cancel, state, session}, _, attempts) do
    case live(attempts)[state] do
      %{status: :connected} ->
        {:reply, {:error, :already_authorized}, attempts}

      %{status: :settled} ->
        {:reply, {:error, :invalid_state}, Map.delete(attempts, state)}

      attempt ->
        reply =
          if attempt && attempt.session_digest == session,
            do: {:ok, public(attempt)},
            else: {:error, :invalid_state}

        {:reply, reply, Map.delete(attempts, state)}
    end
  end

  def handle_call({:prepare, state, %Secret{value: {session, params}}}, _, attempts) do
    case live(attempts)[state] do
      %{status: :pending, session_digest: bound} = attempt ->
        if bound == digest(session) do
          prepared =
            Map.merge(attempt, %{
              status: :queued,
              session: %Secret{value: session},
              params: %Secret{value: params}
            })

          {:reply, {:ok, attempt.id}, Map.put(attempts, state, prepared)}
        else
          {:reply, {:error, :invalid_state}, Map.delete(attempts, state)}
        end

      _ ->
        {:reply, {:error, :invalid_state}, attempts}
    end
  end

  def handle_call({:claim, id}, _, attempts) do
    case find(live(attempts), id) do
      {key, %{status: :queued} = attempt} ->
        if current?(attempt) do
          secret =
            attempt
            |> Map.merge(%{
              verifier: attempt.verifier.value,
              session: attempt.session.value,
              params: attempt.params.value
            })

          claimed = Map.drop(attempt, [:verifier, :params]) |> Map.put(:status, :exchanging)
          {:reply, {:ok, %Secret{value: secret}}, Map.put(attempts, key, claimed)}
        else
          {:reply, {:error, :expired}, Map.delete(attempts, key)}
        end

      _ ->
        {:reply, {:error, :expired}, attempts}
    end
  end

  def handle_call({:commit, id, %Secret{value: fun}}, _, attempts) do
    case find(attempts, id) do
      {key, %{status: :exchanging} = attempt} ->
        result = if current?(attempt), do: Vault.with_access(fun), else: {:error, :reconnect}
        status = if match?({:ok, _}, result), do: :connected, else: :failed
        {:reply, result, Map.put(attempts, key, Map.put(attempt, :status, status))}

      _ ->
        {:reply, {:error, :expired}, attempts}
    end
  end

  def handle_call({:settle, id, result}, _, attempts) do
    case find(attempts, id) do
      {key, attempt} ->
        settled =
          public(attempt)
          |> Map.merge(%{
            id: id,
            session_digest: attempt.session_digest,
            status: :settled,
            result: safe_result(result, attempt),
            expires: now() + @ttl
          })

        {:reply, :ok, Map.put(attempts, key, settled)}

      _ ->
        {:reply, :ok, attempts}
    end
  end

  def handle_call({:result, id}, _, attempts) do
    result =
      case find(live(attempts), id) do
        {_, %{result: result}} -> result
        {_, _} -> :pending
        _ -> {:error, {:state, :reconnect}}
      end

    {:reply, result, live(attempts)}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _owner, _reason}, attempts) do
    case Process.get(:client_change) do
      {_, ^monitor} -> Process.delete(:client_change)
      _ -> :ok
    end

    {:noreply, attempts}
  end

  @impl true
  def format_status(_), do: %{state: :redacted, message: :redacted, reason: :redacted}

  defp safe_result({:ok, _}, attempt), do: {:ok, public(attempt)}
  defp safe_result({:error, failure, _}, attempt), do: {:error, failure, public(attempt)}
  defp safe_result({:error, failure}, attempt), do: {:error, failure, public(attempt)}
  defp safe_result(_, attempt), do: {:error, {:callback, :unavailable}, public(attempt)}

  defp public(attempt),
    do:
      Map.take(attempt, [
        :workspace_id,
        :capability,
        :origin,
        :expected_account_id,
        :expected_generation
      ])

  defp current?(attempt),
    do:
      attempt.expires > now() and callback_url() == attempt.callback_url and
        match?({:ok, _}, Lovelace.Owner.verify_session(attempt.session.value))

  defp changing?, do: not is_nil(Process.get(:client_change))

  defp callback_url,
    do:
      Application.get_env(:lovelace, :gmail, [])
      |> Keyword.get(:redirect_uri, "http://localhost:4000/oauth/google/callback")

  defp live(attempts), do: Map.filter(attempts, fn {_, a} -> a.expires > now() end)
  defp find(attempts, id), do: Enum.find(attempts, fn {_, a} -> a.id == id end)
  defp now, do: System.monotonic_time(:millisecond)
  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp digest(value) when is_binary(value), do: :crypto.hash(:sha256, value)
  defp digest(_), do: :crypto.hash(:sha256, "invalid")

  defp requested_capabilities(_, :gmail, _), do: {:ok, []}

  defp requested_capabilities(id, capability, generation) do
    case Lovelace.Mail.get_account(id, actor: @owner) do
      {:ok, %{generation: ^generation, status: status} = account} when status != :disconnected ->
        capabilities =
          [:calendar, :youtube]
          |> Enum.filter(fn optional ->
            optional == capability or Map.get(account, enabled_attribute(optional)) == true
          end)

        {:ok, capabilities}

      _ ->
        {:error, :invalid_request}
    end
  end

  defp enabled_attribute(:calendar), do: :calendar_enabled
  defp enabled_attribute(:youtube), do: :youtube_enabled

  defp connection_snapshot(expected) when expected in [nil, ""] do
    case Account
         |> Ash.Query.select([:id, :subject, :generation])
         |> Ash.Query.limit(101)
         |> Ash.read(actor: @owner) do
      {:ok, accounts} when length(accounts) <= 100 ->
        snapshot =
          Map.new(accounts, fn account ->
            {digest(account.subject), %{id: account.id, generation: account.generation}}
          end)

        {:ok, %Secret{value: snapshot}}

      _ ->
        {:error, :unavailable}
    end
  end

  defp connection_snapshot(_expected), do: {:ok, %Secret{value: nil}}

  defp call(message) do
    GenServer.call(__MODULE__, message, 30_000)
  catch
    :exit, _ -> {:error, :unavailable}
  end
end
