defmodule Lovelace.Integrations.Google do
  @moduledoc """
  Concrete Google adapter for `Lovelace.Mail.Provider` and
  `Lovelace.Google.OAuthProvider`; no persistence or account policy.

  `Application.get_env(:lovelace, :gmail, [])` accepts a keyword list or map:
  * `:redirect_uri` — default `http://localhost:4000/oauth/google/callback`;
    must exactly match the browser's loopback origin (localhost/127.0.0.1/[::1]),
    with an explicit port and the fixed callback path, without query/fragment.
  * `:timeout_ms` — whole-operation deadline, default 15_000, range 1..30_000.
  * `:transport` / `:transport_options` — trusted private fake implementing
    `Google.Transport.request/2`; default is the private passive Mint transport.

  Client credentials are read from the dedicated local vault through
  `Google.ClientCredentials`. Never persist/log/inspect token results, authorization codes,
  request maps, transport options or exceptions. Returned message text is plain
  text, NOT HTML-safe; render with normal HEEx escaping, never `raw/1`.
  Subject (`sub`), not email, is Google's stable identity. Identity association,
  OAuth state consumption and refresh coordination belong to the caller.

  Exchange/refresh return token maps (expiry is seconds); an omitted refresh token
  is absent, not nil. Preserve a vault token only after matching the same subject.
  A returned scope list must include Gmail readonly and no unrelated scopes.
  Calendar and YouTube are explicit opt-ins; returned `:scopes` supplies consent evidence.
  Lists return at most 20 metadata summaries and an optional next-page token.
  Full threads are capped at 100 messages; MIME is capped at depth 10, 100 parts,
  256 KiB decoded text and 2 MiB encoded text per message. Attachment metadata is
  retained; bytes are fetched only by an explicit, bounded request.
  """

  alias Lovelace.Google.OAuthProvider
  alias Lovelace.Integrations.Google.{Message, Transport}
  alias Lovelace.Mail.Provider
  alias Lovelace.Security.Vault

  @behaviour Provider
  @behaviour OAuthProvider

  @scope "openid email https://www.googleapis.com/auth/gmail.readonly"
  @calendar_scopes [
    "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
    "https://www.googleapis.com/auth/calendar.events.readonly"
  ]
  @youtube_scope "https://www.googleapis.com/auth/youtube.readonly"
  @callback_path "/oauth/google/callback"
  @max_body 10 * 1024 * 1024
  @max_attachment 5 * 1024 * 1024
  @unread_page_size 500
  @unread_max_pages 10
  @safe_errors [
    :timeout,
    :response_too_large,
    :transport_error,
    :invalid_configuration,
    :invalid_request,
    :invalid_response,
    :invalid_grant,
    :unauthorized,
    :forbidden,
    :not_found,
    :rate_limited,
    :provider_error
  ]

  @impl OAuthProvider
  @spec authorization_url(OAuthProvider.authorization()) ::
          {:ok, binary()} | OAuthProvider.failure()
  def authorization_url(params) do
    safe(fn ->
      with {:ok, config} <- configuration(),
           {:ok, %{client_id: client_id}} <- credentials(),
           %{state: state, verifier: verifier, redirect_uri: redirect} <- params,
           true <- valid_state?(state) and valid_verifier?(verifier),
           {:ok, scope} <-
             authorization_scope(
               Map.get(params, :capability, :gmail),
               Map.get(params, :capabilities)
             ),
           :ok <- validate_redirect(redirect, config.redirect_uri) do
        query =
          URI.encode_query(%{
            client_id: client_id,
            redirect_uri: redirect,
            response_type: "code",
            scope: scope,
            state: state,
            code_challenge: :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false),
            code_challenge_method: "S256",
            access_type: "offline",
            prompt: "consent select_account"
          })

        {:ok, "https://accounts.google.com/o/oauth2/v2/auth?" <> query}
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_request}
      end
    end)
  end

  defp authorization_scope(:gmail, capabilities) when capabilities in [nil, []], do: {:ok, @scope}

  defp authorization_scope(capability, capabilities) when capability in [:calendar, :youtube] do
    capabilities = if is_nil(capabilities), do: [capability], else: capabilities

    if is_list(capabilities) and length(capabilities) <= 2 and capability in capabilities and
         Enum.all?(capabilities, &(&1 in [:calendar, :youtube])) do
      calendar = if :calendar in capabilities, do: @calendar_scopes, else: []
      youtube = if :youtube in capabilities, do: [@youtube_scope], else: []
      scopes = [@scope] ++ calendar ++ youtube

      {:ok, Enum.join(scopes, " ")}
    else
      {:error, :invalid_request}
    end
  end

  defp authorization_scope(_, _), do: {:error, :invalid_request}

  @doc false
  def calendar_authorized?(%{scopes: scopes}) when is_list(scopes),
    do:
      Enum.all?(
        ["https://www.googleapis.com/auth/gmail.readonly" | @calendar_scopes],
        &(&1 in scopes)
      )

  def calendar_authorized?(_), do: false

  @doc false
  def youtube_authorized?(%{scopes: scopes}) when is_list(scopes),
    do: "https://www.googleapis.com/auth/gmail.readonly" in scopes and @youtube_scope in scopes

  def youtube_authorized?(_), do: false

  @impl OAuthProvider
  @spec exchange_code(binary(), binary(), binary()) ::
          {:ok, OAuthProvider.tokens()} | OAuthProvider.failure()
  def exchange_code(code, verifier, redirect_uri) do
    bounded(fn config ->
      with true <- bounded_string?(code, 8192) and valid_verifier?(verifier),
           :ok <- validate_redirect(redirect_uri, config.redirect_uri),
           {:ok, credentials} <- credentials(),
           {:ok, data} <-
             form(
               config,
               "/token",
               Map.merge(credentials, %{
                 grant_type: "authorization_code",
                 code: code,
                 code_verifier: verifier,
                 redirect_uri: redirect_uri
               })
             ) do
        tokens(data)
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_request}
      end
    end)
  end

  @impl OAuthProvider
  @spec refresh(binary()) :: {:ok, OAuthProvider.tokens()} | OAuthProvider.failure()
  def refresh(refresh_token) do
    bounded(fn config ->
      with true <- valid_token?(refresh_token),
           {:ok, credentials} <- credentials(),
           {:ok, data} <-
             form(
               config,
               "/token",
               Map.merge(credentials, %{
                 grant_type: "refresh_token",
                 refresh_token: refresh_token
               })
             ) do
        tokens(data)
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_request}
      end
    end)
  end

  @impl OAuthProvider
  @spec identity(binary()) :: {:ok, OAuthProvider.identity()} | OAuthProvider.failure()
  def identity(access_token) do
    bounded(fn config ->
      with {:ok, data} <-
             get(config, "openidconnect.googleapis.com", "/v1/userinfo", access_token),
           %{"sub" => subject, "email" => email, "email_verified" => true} <- data,
           true <- bounded_string?(subject, 255) and bounded_string?(email, 320) do
        {:ok, %{subject: subject, email: email}}
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_response}
      end
    end)
  end

  @impl Provider
  @spec inbox(binary(), Provider.page_token()) :: {:ok, Provider.page()} | Provider.failure()
  def inbox(access_token, page_token \\ nil), do: list(access_token, nil, page_token)

  @doc """
  Paired unread inbox conversation counts, independent of cached pages.

  The total is the INBOX label's `threadsUnread`. Recent conversations match
  Gmail's received-time search within a fixed UTC, second-resolution 24-hour
  window established before either read. Only fully paged thread IDs are counted;
  estimates, metadata and message counts are never used. The whole observation
  shares one deadline and at most ten pages of 500 IDs.
  """
  @impl Provider
  @spec inbox_unread(binary()) :: {:ok, Provider.unread()} | Provider.failure()
  def inbox_unread(access_token) do
    bounded(fn config ->
      until = DateTime.utc_now() |> DateTime.to_unix()
      query = "after:#{until - 86_400} before:#{until}"

      with {:ok, data} <-
             get(config, "gmail.googleapis.com", "/gmail/v1/users/me/labels/INBOX", access_token),
           %{"id" => "INBOX", "threadsUnread" => count} when is_integer(count) and count >= 0 <-
             data,
           {:ok, recent} <-
             unread_ids(config, access_token, query, nil, MapSet.new(), MapSet.new(), 0) do
        {:ok, %{total: count, recent: recent}}
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_response}
      end
    end)
  end

  defp unread_ids(config, token, query, page, ids, pages, page_count) do
    params = [
      {"maxResults", Integer.to_string(@unread_page_size)},
      {"labelIds", "INBOX"},
      {"labelIds", "UNREAD"},
      {"q", query},
      {"fields", "threads/id,nextPageToken"}
    ]

    params = if page, do: params ++ [{"pageToken", page}], else: params

    with {:ok, data} <- gmail_get(config, token, "", params),
         {:ok, found, next} <- unread_page(data) do
      ids = Enum.reduce(found, ids, &MapSet.put(&2, &1["id"]))

      cond do
        is_nil(next) ->
          {:ok, MapSet.size(ids)}

        MapSet.member?(pages, next) ->
          {:error, :invalid_response}

        page_count + 1 >= @unread_max_pages ->
          {:error, :response_too_large}

        true ->
          unread_ids(config, token, query, next, ids, MapSet.put(pages, next), page_count + 1)
      end
    end
  end

  defp unread_page(data) when is_map(data) do
    threads = Map.get(data, "threads", [])
    next = Map.get(data, "nextPageToken")

    if is_list(threads) and length(threads) <= @unread_page_size and
         Enum.all?(threads, &(is_map(&1) and valid_id?(&1["id"]))) and
         (is_nil(next) or bounded_string?(next, 4096)) do
      {:ok, threads, next}
    else
      {:error, :invalid_response}
    end
  end

  @impl Provider
  @spec search(binary(), binary(), Provider.page_token()) ::
          {:ok, Provider.page()} | Provider.failure()
  def search(access_token, query, page_token \\ nil) do
    if bounded_string?(query, 4096),
      do: list(access_token, query, page_token),
      else: {:error, :invalid_request}
  end

  @impl Provider
  @spec thread(binary(), binary()) :: {:ok, Provider.thread()} | Provider.failure()
  def thread(access_token, id) do
    bounded(fn config ->
      with true <- valid_id?(id),
           {:ok, data} <- gmail_get(config, access_token, "/" <> id, [{"format", "full"}]) do
        Message.thread(data, id)
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_request}
      end
    end)
  end

  @impl Provider
  @spec attachment(binary(), binary(), binary()) :: {:ok, binary()} | Provider.failure()
  def attachment(access_token, message_id, attachment_id) do
    if valid_id?(message_id) and valid_attachment_id?(attachment_id),
      do: fetch_attachment(access_token, message_id, attachment_id),
      else: {:error, :invalid_request}
  end

  defp fetch_attachment(access_token, message_id, attachment_id) do
    bounded(fn config ->
      fetch_attachment_data(config, access_token, message_id, attachment_id)
    end)
  end

  defp fetch_attachment_data(config, access_token, message_id, attachment_id) do
    path = "/gmail/v1/users/me/messages/#{message_id}/attachments/#{attachment_id}"

    with {:ok, data} <- get(config, "gmail.googleapis.com", path, access_token),
         encoded when is_binary(encoded) <- data["data"],
         true <- byte_size(encoded) <= div(@max_attachment * 4, 3) + 8,
         {:ok, bytes} <- Base.url_decode64(encoded, padding: rem(byte_size(encoded), 4) == 0),
         true <- byte_size(bytes) <= @max_attachment do
      {:ok, bytes}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_response}
    end
  end

  @impl OAuthProvider
  @spec revoke(binary()) :: :ok | OAuthProvider.failure()
  def revoke(refresh_token) do
    if valid_token?(refresh_token) do
      bounded(fn config ->
        revocation_result(form(config, "/revoke", %{token: refresh_token}, :empty))
      end)
    else
      {:error, :invalid_request}
    end
  end

  defp revocation_result({:ok, _}), do: :ok
  defp revocation_result(error), do: error

  defp list(token, query, page) do
    if optional_string?(query) and optional_string?(page) do
      bounded(fn config -> fetch_list(config, token, query, page) end)
    else
      {:error, :invalid_request}
    end
  end

  defp fetch_list(config, token, query, page) do
    params = [{"maxResults", "20"}]
    params = if query, do: params ++ [{"q", query}], else: params ++ [{"labelIds", "INBOX"}]
    params = if page, do: params ++ [{"pageToken", page}], else: params

    with {:ok, data} <- gmail_get(config, token, "", params),
         {:ok, ids, next} <- list_ids(data),
         {:ok, threads} <- metadata(config, token, ids) do
      {:ok, %{threads: threads, next_page_token: next}}
    end
  end

  defp optional_string?(nil), do: true
  defp optional_string?(value), do: bounded_string?(value, 4096)

  defp list_ids(data) when is_map(data) do
    threads = Map.get(data, "threads", [])
    next = Map.get(data, "nextPageToken")

    if is_list(threads) and length(threads) <= 20 and
         Enum.all?(threads, &match?(%{"id" => _}, &1)) and
         Enum.all?(threads, &valid_id?(&1["id"])) and
         (is_nil(next) or bounded_string?(next, 4096)) do
      {:ok, Enum.map(threads, & &1["id"]), next}
    else
      {:error, :invalid_response}
    end
  end

  defp metadata(config, token, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      params =
        [{"format", "metadata"}] ++
          Enum.map(["Subject", "From", "Date"], &{"metadataHeaders", &1})

      with {:ok, data} <- gmail_get(config, token, "/" <> id, params),
           {:ok, summary} <- Message.summary(data, id) do
        {:cont, {:ok, [summary | acc]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp gmail_get(config, token, suffix, params),
    do:
      get(
        config,
        "gmail.googleapis.com",
        "/gmail/v1/users/me/threads" <> suffix <> "?" <> URI.encode_query(params),
        token
      )

  @doc false
  def calendar_get(token, path, query) do
    bounded(fn config ->
      if is_binary(path) and byte_size(path) <= 4096 and
           Regex.match?(
             ~r"\A/(?:users/me/calendarList|calendars/[A-Za-z0-9._~%+-]+/events)\z",
             path
           ) and
           not String.contains?(path, ["/../", "/./"]) and is_list(query) do
        get(
          config,
          "www.googleapis.com",
          "/calendar/v3" <> path <> "?" <> URI.encode_query(query),
          token
        )
      else
        {:error, :invalid_request}
      end
    end)
  end

  defp get(config, host, path, token) do
    if valid_token?(token) do
      request(config, "GET", host, path, [{"authorization", "Bearer " <> token}], "", :json)
    else
      {:error, :invalid_request}
    end
  end

  defp form(config, path, params, type \\ :json),
    do:
      request(
        config,
        "POST",
        "oauth2.googleapis.com",
        path,
        [{"content-type", "application/x-www-form-urlencoded"}],
        URI.encode_query(params),
        type
      )

  defp request(config, method, host, path, headers, body, type) do
    remaining = config.deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      req = %{
        method: method,
        host: host,
        path: path,
        body: body,
        headers: [{"accept", "application/json"}, {"accept-encoding", "identity"} | headers],
        timeout_ms: remaining
      }

      with :ok <- Transport.validate(req),
           {:ok, response} <- config.transport.request(req, config.transport_options) do
        parse_response(response, type)
      else
        {:error, reason} when reason in @safe_errors -> {:error, reason}
        _ -> {:error, :transport_error}
      end
    else
      {:error, :timeout}
    end
  end

  defp parse_response(%{status: status, headers: headers, body: body}, type)
       when is_integer(status) and is_list(headers) and is_binary(body) do
    header_size = Enum.reduce(headers, 0, fn {k, v}, n -> n + byte_size(k) + byte_size(v) end)
    encoding = header(headers, "content-encoding")

    cond do
      byte_size(body) > @max_body or header_size > 64 * 1024 ->
        {:error, :response_too_large}

      status != 200 ->
        http_error(status, body)

      encoding not in [[], ["identity"]] ->
        {:error, :invalid_response}

      true ->
        parse_success(headers, body, type)
    end
  end

  defp parse_response(_, _), do: {:error, :invalid_response}

  defp parse_success(_headers, _body, :empty), do: {:ok, %{}}

  defp parse_success(headers, body, :json) do
    case header(headers, "content-type") do
      [type] ->
        if type |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase() ==
             "application/json", do: decode_json(body), else: {:error, :invalid_response}

      _ ->
        {:error, :invalid_response}
    end
  end

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, data} when is_map(data) -> {:ok, data}
      _ -> {:error, :invalid_response}
    end
  end

  defp http_error(400, body) do
    case Jason.decode(body) do
      {:ok, %{"error" => "invalid_grant"}} -> {:error, :invalid_grant}
      _ -> {:error, :provider_error}
    end
  end

  defp http_error(401, _), do: {:error, :unauthorized}
  defp http_error(403, _), do: {:error, :forbidden}
  defp http_error(404, _), do: {:error, :not_found}
  defp http_error(429, _), do: {:error, :rate_limited}
  defp http_error(_, _), do: {:error, :provider_error}

  defp header(headers, name),
    do: for({key, value} <- headers, String.downcase(key) == name, do: value)

  defp tokens(data) do
    access = data["access_token"]
    refresh = data["refresh_token"]
    expires = data["expires_in"]

    if valid_token?(access) and is_integer(expires) and expires in 1..86_400 and
         data["token_type"] in ["Bearer", "bearer"] and scope_allowed?(data["scope"]) and
         valid_refresh?(refresh) do
      result = %{access_token: access, expires_in: expires}
      result = if refresh, do: Map.put(result, :refresh_token, refresh), else: result

      result =
        if is_binary(data["scope"]),
          do: Map.put(result, :scopes, String.split(data["scope"])),
          else: result

      {:ok, result}
    else
      {:error, :invalid_response}
    end
  end

  defp valid_refresh?(nil), do: true
  defp valid_refresh?(value), do: valid_token?(value)

  defp scope_allowed?(nil), do: true

  defp scope_allowed?(scope) when is_binary(scope) do
    allowed =
      String.split(@scope) ++
        @calendar_scopes ++ [@youtube_scope, "https://www.googleapis.com/auth/userinfo.email"]

    scopes = String.split(scope)

    "https://www.googleapis.com/auth/gmail.readonly" in scopes and
      Enum.all?(scopes, &(&1 in allowed))
  end

  defp scope_allowed?(_), do: false

  defp credentials do
    adapter =
      Application.get_env(
        :lovelace,
        :google_client_credentials,
        Lovelace.Integrations.Google.ClientCredentials
      )

    adapter.read()
  end

  defp configuration do
    raw = Application.get_env(:lovelace, :gmail, [])
    config = if keyword?(raw), do: Map.new(raw), else: raw
    configuration_fields(config)
  end

  defp configuration_fields(config) when is_map(config) do
    redirect = Map.get(config, :redirect_uri, "http://localhost:4000" <> @callback_path)
    timeout = Map.get(config, :timeout_ms, 15_000)
    transport = Map.get(config, :transport, Transport)
    options = Map.get(config, :transport_options, [])

    if valid_redirect?(redirect) and is_integer(timeout) and timeout in 1..30_000 and
         is_atom(transport) and keyword?(options) do
      {:ok,
       %{
         redirect_uri: redirect,
         timeout_ms: timeout,
         transport: transport,
         transport_options: options
       }}
    else
      {:error, :invalid_configuration}
    end
  end

  defp configuration_fields(_), do: {:error, :invalid_configuration}
  defp keyword?(value), do: is_list(value) and Keyword.keyword?(value)

  defp validate_redirect(value, configured),
    do:
      if(value == configured and valid_redirect?(value),
        do: :ok,
        else: {:error, :invalid_request}
      )

  defp valid_redirect?(value) when is_binary(value) do
    uri = URI.parse(value)

    authority = if uri.host == "::1", do: "[::1]:#{uri.port}", else: "#{uri.host}:#{uri.port}"

    byte_size(value) <= 256 and valid_origin?(uri) and uri.authority == authority and
      uri.path == @callback_path and is_nil(uri.userinfo) and is_nil(uri.query) and
      is_nil(uri.fragment)
  end

  defp valid_redirect?(_), do: false

  defp valid_origin?(uri),
    do:
      uri.scheme == "http" and uri.host in ["localhost", "127.0.0.1", "::1"] and
        is_integer(uri.port) and uri.port in 1..65_535

  defp valid_state?(value), do: bounded_string?(value, 1024) and byte_size(value) >= 16

  defp valid_verifier?(value) when is_binary(value),
    do: Regex.match?(~r/\A[A-Za-z0-9._~-]{43,128}\z/, value)

  defp valid_verifier?(_), do: false

  defp valid_id?(value) when is_binary(value),
    do: Regex.match?(~r/\A[A-Za-z0-9_-]{1,256}\z/, value)

  defp valid_id?(_), do: false

  defp valid_attachment_id?(value) when is_binary(value),
    do: Regex.match?(~r/\A[-A-Za-z0-9_.+=~]{1,2048}\z/, value)

  defp valid_attachment_id?(_), do: false

  defp valid_token?(value),
    do:
      bounded_string?(value, 8192) and not String.contains?(value, ["\r", "\n", "\0", " ", "\t"])

  defp bounded_string?(value, max),
    do: is_binary(value) and byte_size(value) in 1..max and String.valid?(value)

  defp bounded(fun) do
    safe(fn ->
      with {:ok, config} <- configuration(), do: run_bounded(fun, config)
    end)
  end

  defp run_bounded(fun, config) do
    config = Map.put(config, :deadline, System.monotonic_time(:millisecond) + config.timeout_ms)
    # Catch within the worker: Task crash reports must never inspect secrets.
    task = Task.async(fn -> run_leased(fun, config) end)

    case Task.yield(task, config.timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end

  defp run_leased(fun, config),
    do: safe(fn -> Vault.with_access(fn -> fun.(config) end) end)

  defp safe(fun) do
    fun.()
  rescue
    _ -> {:error, :provider_error}
  catch
    _, _ -> {:error, :provider_error}
  end
end
