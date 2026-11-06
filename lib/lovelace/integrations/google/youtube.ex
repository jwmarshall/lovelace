defmodule Lovelace.Integrations.Google.YouTube do
  @moduledoc "Private bounded YouTube Data API reads; never scraping, assets, playback or writes."
  @behaviour Lovelace.YouTube.Provider
  alias Lovelace.Integrations.Google.Transport
  alias Lovelace.YouTube.Payload

  @impl true
  def subscriptions(token, page) do
    if Payload.page_token?(page) do
      query = [
        part: "snippet",
        mine: "true",
        maxResults: "50",
        fields: "items(snippet(title,resourceId/channelId)),nextPageToken"
      ]

      query = if page, do: query ++ [pageToken: page], else: query

      with {:ok, data} <- get(token, "subscriptions", query),
           {:ok, items, next} <- page(data, 50),
           {:ok, rows} <- parse(items, &subscription/1),
           {:ok, rows, next} <- Payload.channels(%{channels: rows, next_page: next}) do
        {:ok, %{channels: rows, next_page: next}}
      end
    else
      {:error, :invalid_request}
    end
  end

  @impl true
  def uploads_playlists(token, ids) do
    if is_list(ids) && length(ids) in 1..10 && Enum.all?(ids, &Payload.channel_id?/1) do
      query = [
        part: "contentDetails",
        id: Enum.join(ids, ","),
        maxResults: "10",
        fields: "items(id,contentDetails/relatedPlaylists/uploads)"
      ]

      with {:ok, data} <- get(token, "channels", query),
           {:ok, items, nil} <- page(data, 10),
           {:ok, rows} <- parse(items, &playlist/1),
           true <- length(Enum.uniq_by(rows, &elem(&1, 0))) == length(rows),
           {:ok, playlists} <- Payload.playlists(Map.new(rows), ids) do
        {:ok, playlists}
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_response}
      end
    else
      {:error, :invalid_request}
    end
  end

  @impl true
  def uploads(token, id) do
    if Payload.playlist_id?(id) do
      query = [
        part: "snippet,contentDetails",
        playlistId: id,
        maxResults: "10",
        fields:
          "items(snippet(title,channelId,resourceId/videoId),contentDetails/videoPublishedAt),nextPageToken"
      ]

      with {:ok, data} <- get(token, "playlistItems", query),
           {:ok, items, next} <- page(data, 10),
           {:ok, videos} <- parse(items, &video/1) do
        visible = Enum.reject(videos, &is_nil/1)
        {:ok, %{videos: visible, truncated: next != nil || length(visible) != length(videos)}}
      end
    else
      {:error, :invalid_request}
    end
  end

  defp get(token, endpoint, query) do
    config = Application.get_env(:lovelace, :gmail, []) |> Map.new()
    transport = Map.get(config, :transport, Transport)
    options = Map.get(config, :transport_options, [])
    timeout = Map.get(config, :timeout_ms, 5_000)

    valid =
      is_binary(token) && byte_size(token) in 1..16_384 &&
        not String.contains?(token, ["\r", "\n", "\0"]) &&
        is_integer(timeout) && timeout in 1..30_000 && is_atom(transport) &&
        Keyword.keyword?(options)

    if valid do
      request = %{
        method: "GET",
        host: "www.googleapis.com",
        path: "/youtube/v3/" <> endpoint <> "?" <> URI.encode_query(query),
        headers: [
          {"accept", "application/json"},
          {"accept-encoding", "identity"},
          {"authorization", "Bearer " <> token}
        ],
        body: "",
        timeout_ms: min(timeout, 5_000)
      }

      with :ok <- Transport.validate(request),
           {:ok, response} <- transport.request(request, options) do
        response(response)
      else
        _ -> {:error, :provider}
      end
    else
      {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :provider}
  catch
    _, _ -> {:error, :provider}
  end

  defp response(%{status: status, headers: headers, body: body})
       when is_integer(status) and is_list(headers) and is_binary(body) do
    types = header(headers, "content-type")
    encodings = header(headers, "content-encoding")

    bytes =
      Enum.reduce(headers, 0, fn {key, value}, size ->
        size + byte_size(key) + byte_size(value)
      end)

    if byte_size(body) > 512 * 1024 or bytes > 64 * 1024 do
      {:error, :invalid_response}
    else
      response_status(status, types, encodings, body)
    end
  end

  defp response(_), do: {:error, :invalid_response}

  defp response_status(429, _, _, _), do: {:error, :rate_limited}
  defp response_status(401, _, _, _), do: {:error, :reconnect}
  defp response_status(403, _, _, body), do: forbidden(body)

  defp response_status(200, types, encodings, body) do
    if json_headers?(types, encodings), do: decode(body), else: {:error, :invalid_response}
  end

  defp response_status(_, _, _, _), do: {:error, :provider}

  defp json_headers?([type], encodings) when encodings in [[], ["identity"]] do
    type |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase() ==
      "application/json"
  end

  defp json_headers?(_, _), do: false

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, data} when is_map(data) -> {:ok, data}
      _ -> {:error, :invalid_response}
    end
  end

  defp forbidden(body) do
    # Only finite classifications escape; provider text is never an error payload.
    case Jason.decode(body) do
      {:ok, %{"error" => %{"errors" => errors}}} when is_list(errors) ->
        if Enum.any?(errors, &quota_error?/1),
          do: {:error, :rate_limited},
          else: {:error, :reconnect}

      _ ->
        {:error, :reconnect}
    end
  end

  defp quota_error?(row) when is_map(row),
    do:
      row["reason"] in [
        "quotaExceeded",
        "dailyLimitExceeded",
        "rateLimitExceeded",
        "userRateLimitExceeded"
      ]

  defp quota_error?(_), do: false

  defp header(headers, name),
    do: for({key, value} <- headers, String.downcase(key) == name, do: String.downcase(value))

  defp page(%{"items" => items} = data, limit) when is_list(items) and length(items) <= limit do
    next = Map.get(data, "nextPageToken")
    if Payload.page_token?(next), do: {:ok, items, next}, else: {:error, :invalid_response}
  end

  defp page(_, _), do: {:error, :invalid_response}

  defp parse(items, parser) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, rows} ->
      case parser.(item) do
        {:ok, row} -> {:cont, {:ok, [row | rows]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp subscription(%{"snippet" => %{"title" => title, "resourceId" => %{"channelId" => id}}}),
    do: {:ok, %{"id" => id, "title" => title}}

  defp subscription(_), do: {:error, :invalid_response}

  defp playlist(%{
         "id" => id,
         "contentDetails" => %{"relatedPlaylists" => %{"uploads" => uploads}}
       }),
       do: {:ok, {id, uploads}}

  defp playlist(_), do: {:error, :invalid_response}

  defp video(%{
         "contentDetails" => %{"videoPublishedAt" => at},
         "snippet" => %{
           "title" => title,
           "channelId" => channel,
           "resourceId" => %{"videoId" => id}
         }
       }),
       do: {:ok, %{"id" => id, "title" => title, "channel_id" => channel, "published_at" => at}}

  defp video(%{"snippet" => %{"title" => title}})
       when title in ["Private video", "Deleted video"], do: {:ok, nil}

  defp video(_), do: {:error, :invalid_response}
end
