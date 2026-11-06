defmodule LovelaceWeb.GoogleOAuthController do
  @moduledoc "Explicit, CSRF-protected connection intent; callback bypasses request instrumentation."
  use LovelaceWeb, :controller
  alias Lovelace.Mail
  alias Lovelace.Mail.OAuth

  def create(conn, _params) do
    workspace = conn.body_params["workspace_id"]
    expected = conn.body_params["expected_account_id"]
    session = get_session(conn, :owner_session_token)

    with {:ok, capability} <- capability(conn.body_params["capability"]),
         {:ok, origin} <- origin(conn.body_params["origin"]),
         {:ok, %{id: ^workspace}} <-
           Lovelace.Workspaces.get_workspace(workspace, actor: conn.assigns.current_actor),
         {:ok, generation} <- expected_account(expected, conn.assigns.current_actor, capability),
         {:ok, url} <-
           OAuth.authorization_url(workspace, session, expected, capability, generation, origin),
         %URI{scheme: "https", host: "accounts.google.com", userinfo: nil} <- URI.parse(url) do
      conn |> put_resp_header("location", url) |> send_resp(303, "")
    else
      _ ->
        conn
        |> put_flash(
          :error,
          "Google connection is unavailable. Complete the local Google setup first."
        )
        |> redirect(to: failure_path(conn.body_params))
    end
  end

  defp failure_path(params) do
    case {origin(params["origin"]), capability(params["capability"])} do
      {{:ok, :onboarding}, {:ok, :calendar}} ->
        "/onboarding/calendar?notice=calendar_failed"

      {{:ok, :onboarding}, {:ok, :gmail}} ->
        "/onboarding/connect?notice=connection_failed"

      _ ->
        case params["capability"] do
          "calendar" -> "/connections/calendar"
          "youtube" -> "/connections/youtube"
          _ -> "/connections/gmail"
        end
    end
  end

  defp capability(nil), do: {:ok, :gmail}
  defp capability("gmail"), do: {:ok, :gmail}
  defp capability("calendar"), do: {:ok, :calendar}
  defp capability("youtube"), do: {:ok, :youtube}
  defp capability(_), do: {:error, :invalid_request}

  defp origin(nil), do: {:ok, :connections}
  defp origin("onboarding"), do: {:ok, :onboarding}
  defp origin(_), do: {:error, :invalid_request}

  defp expected_account(value, _, :gmail) when value in [nil, ""], do: {:ok, nil}

  defp expected_account(value, _, capability)
       when value in [nil, ""] and capability in [:calendar, :youtube],
       do: {:error, :unavailable}

  defp expected_account(id, actor, capability) do
    case Mail.get_account(id, actor: actor) do
      {:ok, %{status: :disconnected}} when capability in [:calendar, :youtube] ->
        {:error, :unavailable}

      {:ok, %{generation: generation}} ->
        {:ok, generation}

      _ ->
        {:error, :unavailable}
    end
  end
end
