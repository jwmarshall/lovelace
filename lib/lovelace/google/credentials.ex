defmodule Lovelace.Google.Credentials do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  alias Lovelace.Integrations.Google.ClientCredentials
  alias Lovelace.Mail.OAuth

  @impl true
  def run(input, opts, _context) do
    case opts[:operation] do
      :status ->
        {:ok, ClientCredentials.status()}

      :save ->
        result = save(input.arguments.client_id, input.arguments.client_secret)

        case result do
          :ok ->
            {:ok, true}

          {:error, reason} when reason in [:invalid_configuration, :locked, :unavailable] ->
            {:error, reason}

          _ ->
            {:error, :unavailable}
        end
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp save(client_id, client_secret) do
    Lovelace.ConnectionDiagnostics.serial(:google, fn ->
      persist_client(client_id, client_secret)
    end)
  end

  defp persist_client(client_id, client_secret) do
    with :ok <- ClientCredentials.validate(client_id, client_secret),
         :ok <- Lovelace.ConnectionDiagnostics.invalidate(:google) do
      OAuth.client_change(fn -> replace_client(client_id, client_secret) end)
    end
  end

  defp replace_client(client_id, client_secret) do
    case ClientCredentials.read() do
      {:ok, %{client_id: ^client_id, client_secret: ^client_secret}} ->
        ClientCredentials.save(client_id, client_secret)

      {:error, :invalid_configuration} ->
        fence_and_save_client(client_id, client_secret)

      {:ok, _} ->
        fence_and_save_client(client_id, client_secret)

      error ->
        error
    end
  end

  defp fence_and_save_client(client_id, client_secret) do
    with :ok <- Lovelace.Google.Access.client_changed() do
      ClientCredentials.save(client_id, client_secret)
    end
  end
end
