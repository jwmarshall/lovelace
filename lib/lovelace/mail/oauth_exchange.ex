defmodule Lovelace.Mail.OAuthExchange do
  @moduledoc "Google consent exchange executed exclusively by the admitted OAuth worker."
  alias Lovelace.Google.Access
  alias Lovelace.Integrations.Google
  alias Lovelace.Mail
  alias Lovelace.Mail.{ConnectionDiagnostics, OAuth}
  @owner %{role: :local_owner}

  def execute(attempt, params, session) do
    with :ok <- step(:consent, fn -> consent(params) end),
         :ok <- step(:account_binding, fn -> current_onboarding(attempt) end),
         {:ok, code} <- step(:code, fn -> required(params, "code", 4096) end),
         {:ok, tokens} <- exchange_tokens(attempt, code, session),
         :ok <- step(:consent, fn -> requested_scopes(attempt, tokens) end),
         {:ok, identity} <-
           step(:identity, fn -> Access.provider().identity(tokens.access_token) end),
         :ok <-
           step(:account_binding, fn ->
             same_account(attempt, identity.subject)
           end),
         {:ok, refresh} <- step(:refresh_token, fn -> refresh_token(tokens, identity.subject) end),
         {:ok, _} <- step(:session, fn -> Lovelace.Owner.verify_session(session) end),
         :ok <- step(:account_binding, fn -> current_onboarding(attempt) end),
         {:ok, _} <-
           step(:connection, fn ->
             commit(attempt, identity, refresh, granted_capabilities(attempt, tokens))
           end) do
      {:ok, public(attempt)}
    else
      {:error, failure} -> {:error, failure, public(attempt)}
    end
  rescue
    _ -> attempt_failure(attempt)
  catch
    _, _ -> attempt_failure(attempt)
  end

  # Hold only the account serializer across the irreversible exchange. Release
  # it before identity lookup/publication: commit runs in the secret holder and
  # Access.accept acquires subject then account locks in that other process.
  defp exchange_tokens(%{expected_account_id: id} = attempt, code, session)
       when is_binary(id) and id != "" do
    Access.serial(id, fn -> locked_exchange(attempt, code, session) end)
  end

  defp exchange_tokens(attempt, code, _session), do: exchange_code(attempt, code)

  defp locked_exchange(attempt, code, session) do
    with :ok <- step(:account_binding, fn -> current_connection(attempt) end),
         :ok <- step(:account_binding, fn -> current_onboarding(attempt) end),
         {:ok, _} <- step(:session, fn -> Lovelace.Owner.verify_session(session) end) do
      exchange_code(attempt, code)
    end
  end

  defp commit(attempt, identity, refresh, grants) do
    OAuth.commit(attempt.id, fn -> publish(attempt, identity, refresh, grants) end)
  end

  defp publish(attempt, identity, refresh, grants) do
    with :ok <- same_account(attempt, identity.subject),
         :ok <- current_onboarding(attempt),
         {:ok, account} <- accept(attempt, identity, refresh, grants),
         :ok <- continue_onboarding(attempt) do
      {:ok, account}
    end
  end

  defp exchange_code(attempt, code) do
    step(:token_exchange, fn ->
      Access.provider().exchange_code(code, attempt.verifier, attempt.callback_url)
    end)
  end

  defp current_connection(attempt) do
    case Mail.get_account(attempt.expected_account_id, actor: @owner) do
      {:ok, %{generation: generation, status: status}}
      when is_binary(attempt.expected_generation) and generation == attempt.expected_generation ->
        if attempt.capability in [:calendar, :youtube] and status == :disconnected,
          do: {:error, :wrong_account},
          else: :ok

      _ ->
        {:error, :wrong_account}
    end
  end

  defp attempt_failure(attempt) do
    {:error, failure} = ConnectionDiagnostics.failure(:callback, :unexpected)
    {:error, failure, public(attempt)}
  end

  defp continue_onboarding(%{origin: :onboarding} = attempt) do
    case Ash.transact(Lovelace.Onboarding.State, fn -> advance_onboarding(attempt) end) do
      {:ok, result} -> result
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp continue_onboarding(_), do: :ok

  defp advance_onboarding(attempt) do
    with :ok <- onboarding_workspace(attempt),
         {:ok, _} <- Lovelace.Onboarding.continue(:connect, actor: @owner) do
      :ok
    end
  end

  defp current_onboarding(%{origin: :onboarding, capability: :calendar} = attempt) do
    with :ok <- onboarding_workspace(attempt),
         {:ok, %{id: id, generation: generation}} <-
           Lovelace.Onboarding.connection(actor: @owner),
         true <- id == attempt.expected_account_id and generation == attempt.expected_generation do
      :ok
    else
      _ -> {:error, :wrong_account}
    end
  end

  defp current_onboarding(%{origin: :onboarding} = attempt), do: onboarding_workspace(attempt)
  defp current_onboarding(_), do: :ok

  defp onboarding_workspace(%{workspace_id: workspace_id}) do
    case Lovelace.Onboarding.progress(actor: @owner) do
      {:ok, %{workspace_id: ^workspace_id}} -> :ok
      _ -> {:error, :wrong_account}
    end
  end

  # An optional opt-in requests every already-enabled optional capability too.
  # Reject a partial grant before credentials or dependent snapshots can be replaced.
  defp requested_scopes(attempt, tokens) do
    if Enum.all?(attempt.requested_capabilities, &(capability_scopes(&1, tokens) == :ok)),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp capability_scopes(:calendar, tokens),
    do: if(Google.calendar_authorized?(tokens), do: :ok, else: {:error, :forbidden})

  defp capability_scopes(:youtube, tokens),
    do: if(Google.youtube_authorized?(tokens), do: :ok, else: {:error, :forbidden})

  defp granted_capabilities(attempt, tokens) do
    %{
      calendar_enabled:
        :calendar in attempt.requested_capabilities and Google.calendar_authorized?(tokens),
      youtube_enabled:
        :youtube in attempt.requested_capabilities and Google.youtube_authorized?(tokens)
    }
  end

  defp accept(attempt, identity, refresh, grants) do
    Access.accept(
      attempt.workspace_id,
      identity,
      refresh,
      attempt.capability,
      attempt.expected_generation,
      publication_fence(attempt, identity.subject),
      grants
    )
  end

  defp publication_fence(%{expected_account_id: expected} = attempt, subject)
       when expected in [nil, ""] do
    Map.get(attempt.connection_snapshot.value, :crypto.hash(:sha256, subject), :absent)
  end

  defp publication_fence(attempt, _subject),
    do: %{id: attempt.expected_account_id, generation: attempt.expected_generation}

  defp step(stage, fun), do: ConnectionDiagnostics.step(stage, fun)

  defp consent(params), do: if(is_nil(params["error"]), do: :ok, else: {:error, :denied})

  defp required(params, key, max) do
    case params[key] do
      value when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= max ->
        {:ok, value}

      _ ->
        {:error, :invalid_callback}
    end
  end

  defp same_account(%{capability: capability} = attempt, subject)
       when capability in [:calendar, :youtube] do
    case Mail.get_account(attempt.expected_account_id, actor: @owner) do
      {:ok, %{subject: ^subject, generation: generation, status: status}}
      when generation == attempt.expected_generation and status != :disconnected ->
        :ok

      _ ->
        {:error, :wrong_account}
    end
  end

  defp same_account(%{expected_account_id: expected}, _) when expected in [nil, ""], do: :ok

  defp same_account(%{expected_account_id: id, expected_generation: expected}, subject) do
    case Mail.get_account(id, actor: @owner) do
      {:ok, %{subject: ^subject, generation: generation}}
      when is_nil(expected) or expected == generation ->
        :ok

      _ ->
        {:error, :wrong_account}
    end
  end

  defp refresh_token(%{refresh_token: token}, _) when is_binary(token) and byte_size(token) > 0,
    do: {:ok, token}

  defp refresh_token(_, subject) do
    case Mail.find_account(subject, actor: @owner) do
      {:ok, %{id: _}} -> {:ok, :reuse_existing}
      _ -> {:error, :reconnect}
    end
  end

  defp public(attempt),
    do:
      Map.take(attempt, [
        :workspace_id,
        :capability,
        :origin,
        :expected_account_id,
        :expected_generation
      ])
end
