defmodule LovelaceWeb.Plugs.GoogleOAuthCallback do
  @moduledoc "Consumes OAuth before Phoenix instrumentation; the documented stock Bandit exception remains."
  import Plug.Conn
  alias Lovelace.Mail.{ConnectionDiagnostics, OAuth}
  alias Lovelace.Security.Vault
  alias LovelaceWeb.Plugs.SensitivePath

  def init(opts), do: opts

  def call(conn, _) do
    if SensitivePath.matches?(conn, ["oauth", "google", "callback"]),
      do: callback(conn),
      else: conn
  end

  defp callback(conn) do
    result =
      case Vault.with_access(fn -> complete(conn) end) do
        {:error, :locked} -> ConnectionDiagnostics.failure(:session, :locked)
        other -> other
      end

    conn = %{conn | query_string: "", params: %{}, query_params: %{}}

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("content-security-policy", "default-src 'none'; frame-ancestors 'none'")
    |> put_resp_header("location", destination(result))
    |> send_resp(303, "")
    |> halt()
  end

  defp destination({:ok, %{capability: :gmail, origin: :onboarding}}),
    do: "/onboarding/calendar"

  defp destination({:ok, %{capability: :calendar, origin: :onboarding}}),
    do: "/onboarding/calendar"

  defp destination({:ok, %{capability: :calendar}}),
    do: "/connections/calendar?calendar=connected"

  defp destination({:ok, %{capability: :youtube}}),
    do: "/connections/youtube?youtube=connected"

  defp destination({:ok, %{capability: :gmail, workspace_id: workspace}}),
    do: "/workspaces/" <> workspace <> "?gmail=connected"

  defp destination({:error, _failure, %{capability: :gmail, origin: :onboarding}}),
    do: "/onboarding/connect?notice=connection_failed"

  defp destination({:error, _failure, %{capability: :calendar, origin: :onboarding}}),
    do: "/onboarding/calendar?notice=calendar_failed"

  defp destination({:error, _failure, %{capability: :youtube}}),
    do: "/connections/youtube?youtube=failed"

  defp destination({:error, failure, _attempt}), do: destination({:error, failure})
  defp destination({:error, failure}), do: ConnectionDiagnostics.failure_path(failure)

  defp complete(%{method: "GET", query_string: query} = conn) when byte_size(query) <= 8192 do
    conn = fetch_session(conn)
    session = get_session(conn, :owner_session_token)
    params = URI.decode_query(query)

    with {:ok, _} <- step(:session, fn -> Lovelace.Owner.verify_session(session) end),
         {:ok, state} <- step(:state, fn -> required(params, "state", 128) end) do
      OAuth.complete(state, session, params)
    end
  rescue
    _ -> ConnectionDiagnostics.failure(:callback, :unexpected)
  catch
    _, _ -> ConnectionDiagnostics.failure(:callback, :unexpected)
  end

  defp complete(_), do: ConnectionDiagnostics.failure(:callback, :invalid_callback)

  defp step(stage, fun), do: ConnectionDiagnostics.step(stage, fun)

  defp required(params, key, max) do
    case params[key] do
      value when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= max ->
        {:ok, value}

      _ ->
        {:error, :invalid_callback}
    end
  end
end
