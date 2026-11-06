defmodule Lovelace.Integrations.Google.Transport do
  @moduledoc """
  Private Google wire boundary. No Req/Finch, pools, proxy, telemetry, logging,
  decompression, redirects or retries. Re-audit Mint's instrumentation on upgrades.

  A trusted fake implements `request/2` and is explicitly selected by :gmail's
  :transport setting. Neither requests nor responses may be logged/instrumented.
  Test builds categorically refuse the production connector.
  """

  @callback request(map(), keyword()) ::
              {:ok, %{status: integer(), headers: list(), body: binary()}} | {:error, atom()}

  @max_body 10 * 1024 * 1024
  @max_headers 64 * 1024

  def request(request, _options \\ []), do: guarded(request, &connect/2)

  if Mix.env() == :test do
    @doc false
    def request_on_loopback(request, port) when port in 1..65_535 do
      guarded(request, fn host, timeout ->
        Mint.HTTP.connect(:http, {127, 0, 0, 1}, port,
          hostname: host,
          protocols: [:http1],
          mode: :passive,
          log: false,
          max_header_list_size: @max_headers,
          transport_opts: [timeout: timeout, send_timeout: timeout, send_timeout_close: true]
        )
      end)
    end
  end

  defp guarded(request, connector) do
    with :ok <- validate(request),
         deadline = now() + request.timeout_ms,
         {:ok, conn} <- connector.(request.host, min(request.timeout_ms, 10_000)) do
      try do
        send_request(conn, request, deadline)
      after
        Mint.HTTP.close(conn)
      end
    else
      {:error, reason} -> normalize_error(reason)
      _ -> {:error, :transport_error}
    end
  rescue
    _ -> {:error, :transport_error}
  catch
    _, _ -> {:error, :transport_error}
  end

  @doc false
  def validate(request) do
    valid? =
      is_map(request) and request.method in ["GET", "POST"] and
        allowed_target?(request.method, request.host, request.path) and
        valid_timeout_and_body?(request) and valid_headers?(request.headers)

    if valid?, do: :ok, else: {:error, :invalid_request}
  rescue
    _ -> {:error, :invalid_request}
  end

  defp valid_timeout_and_body?(request),
    do:
      is_integer(request.timeout_ms) and request.timeout_ms in 1..30_000 and
        is_binary(request.body) and byte_size(request.body) <= 64 * 1024

  defp valid_headers?(headers) do
    is_list(headers) and header_bytes(headers) <= 16 * 1024 and
      Enum.all?(headers, fn {name, value} ->
        name in ["accept", "accept-encoding", "authorization", "content-type"] and
          is_binary(value) and not String.contains?(value, ["\r", "\n", "\0"])
      end)
  end

  defp allowed_target?("POST", "oauth2.googleapis.com", path),
    do: path in ["/token", "/revoke"]

  defp allowed_target?("GET", "openidconnect.googleapis.com", "/v1/userinfo"), do: true

  defp allowed_target?("GET", "gmail.googleapis.com", "/gmail/v1/users/me/labels/INBOX"),
    do: true

  defp allowed_target?("GET", "gmail.googleapis.com", path) when is_binary(path) do
    [base | _] = String.split(path, "?", parts: 2)

    byte_size(path) <= 24 * 1024 and not String.contains?(path, ["#", "\r", "\n", "\0"]) and
      (Regex.match?(~r"\A/gmail/v1/users/me/threads(?:/[a-zA-Z0-9_-]{1,256})?\z", base) or
         (path == base and
            Regex.match?(
              ~r"\A/gmail/v1/users/me/messages/[a-zA-Z0-9_-]{1,256}/attachments/[-a-zA-Z0-9_.+=~]{1,2048}\z",
              base
            )))
  end

  defp allowed_target?("GET", "www.googleapis.com", path) when is_binary(path) do
    [base | _] = String.split(path, "?", parts: 2)

    byte_size(path) <= 24 * 1024 and not String.contains?(path, ["#", "\r", "\n", "\0"]) and
      (base in ["/youtube/v3/subscriptions", "/youtube/v3/channels", "/youtube/v3/playlistItems"] or
         (Regex.match?(
            ~r"\A/calendar/v3/(?:users/me/calendarList|calendars/(?:[A-Za-z0-9._~-]|%[A-Fa-f0-9]{2})+/events)\z",
            base
          ) and not String.contains?(base, ["/../", "/./"])))
  end

  defp allowed_target?(_, _, _), do: false

  if Mix.env() == :test do
    defp connect(_host, _timeout), do: {:error, :test_network_disabled}
  else
    defp connect(host, timeout) do
      Mint.HTTP.connect(:https, host, 443,
        protocols: [:http1],
        mode: :passive,
        log: false,
        max_header_list_size: @max_headers,
        transport_opts: [
          timeout: timeout,
          send_timeout: timeout,
          send_timeout_close: true,
          verify: :verify_peer,
          server_name_indication: String.to_charlist(host),
          cacerts: :public_key.cacerts_get(),
          versions: [:"tlsv1.3", :"tlsv1.2"]
        ]
      )
    end
  end

  defp send_request(conn, request, deadline) do
    case Mint.HTTP.request(conn, request.method, request.path, request.headers, request.body) do
      {:ok, conn, ref} -> receive_response(conn, ref, {nil, [], [], 0, 0}, deadline)
      {:error, _conn, reason} -> normalize_error(reason)
    end
  end

  defp receive_response(conn, ref, acc, deadline) do
    remaining = deadline - now()

    if remaining <= 0 do
      {:error, :timeout}
    else
      case Mint.HTTP.recv(conn, 0, remaining) do
        {:ok, conn, events} -> consume(events, conn, ref, acc, deadline)
        {:error, _conn, reason, _events} -> normalize_error(reason)
      end
    end
  end

  defp consume([], conn, ref, acc, deadline),
    do: receive_response(conn, ref, acc, deadline)

  defp consume([{:status, ref, status} | rest], conn, ref, {_, _, chunks, bytes, hs}, deadline),
    do: consume(rest, conn, ref, {status, [], chunks, bytes, hs}, deadline)

  defp consume(
         [{:headers, ref, headers} | rest],
         conn,
         ref,
         {status, old, chunks, bytes, hs},
         deadline
       ) do
    hs = hs + header_bytes(headers)

    if hs > @max_headers do
      {:error, :response_too_large}
    else
      consume(rest, conn, ref, {status, old ++ headers, chunks, bytes, hs}, deadline)
    end
  end

  defp consume(
         [{:data, ref, chunk} | rest],
         conn,
         ref,
         {status, headers, chunks, bytes, hs},
         deadline
       ) do
    bytes = bytes + byte_size(chunk)

    if bytes > @max_body do
      {:error, :response_too_large}
    else
      consume(rest, conn, ref, {status, headers, [chunk | chunks], bytes, hs}, deadline)
    end
  end

  defp consume([{:done, ref} | _], _conn, ref, {status, headers, chunks, _, _}, _deadline),
    do:
      {:ok,
       %{
         status: status,
         headers: headers,
         body: chunks |> Enum.reverse() |> IO.iodata_to_binary()
       }}

  defp consume(_, _conn, _ref, _acc, _deadline), do: {:error, :transport_error}

  defp normalize_error(%Mint.TransportError{reason: reason}), do: normalize_error(reason)

  defp normalize_error(%Mint.HTTPError{reason: {kind, _, _}})
       when kind in [:max_header_list_size_exceeded, :response_line_too_long],
       do: {:error, :response_too_large}

  defp normalize_error(:timeout), do: {:error, :timeout}
  defp normalize_error(_), do: {:error, :transport_error}

  defp header_bytes(headers),
    do: Enum.reduce(headers, 0, fn {key, value}, n -> n + byte_size(key) + byte_size(value) end)

  defp now, do: System.monotonic_time(:millisecond)
end
