defmodule Lovelace.YouTube.Payload do
  @moduledoc false

  def channel_id?(id), do: match_id?(id, ~r/\AUC[A-Za-z0-9_-]{22}\z/)
  def video_id?(id), do: match_id?(id, ~r/\A[A-Za-z0-9_-]{11}\z/)
  def playlist_id?(id), do: match_id?(id, ~r/\A[A-Za-z0-9_-]{2,100}\z/)
  def page_token?(nil), do: true
  def page_token?(value), do: text?(value, 4096) and byte_size(value) > 0

  def channels(%{channels: channels, next_page: next})
      when is_list(channels) and length(channels) <= 50 do
    if page_token?(next) && Enum.all?(channels, &channel?/1),
      do: {:ok, Enum.uniq_by(channels, & &1["id"]), next},
      else: {:error, :invalid_response}
  end

  def channels(_), do: {:error, :invalid_response}

  def playlists(playlists, selected) when is_map(playlists) and map_size(playlists) <= 10 do
    if Enum.all?(playlists, fn {id, playlist} -> id in selected && playlist_id?(playlist) end),
      do: {:ok, playlists},
      else: {:error, :invalid_response}
  end

  def playlists(_, _), do: {:error, :invalid_response}

  def videos(%{videos: videos, truncated: truncated}, channel)
      when is_list(videos) and length(videos) <= 10 and is_boolean(truncated) do
    if Enum.all?(videos, &video?(&1, channel["id"])) do
      rows =
        Enum.map(videos, fn row ->
          {:ok, at, _} = DateTime.from_iso8601(row["published_at"])

          row
          |> Map.take(["id", "title", "channel_id"])
          |> Map.merge(%{
            "published_at" => DateTime.to_iso8601(at),
            "channel_title" => channel["title"]
          })
        end)

      {:ok, rows, truncated}
    else
      {:error, :invalid_response}
    end
  end

  def videos(_, _), do: {:error, :invalid_response}

  def bounded(videos) do
    videos
    |> Enum.uniq_by(& &1["id"])
    |> Enum.map(fn video ->
      {:ok, published_at, _} = DateTime.from_iso8601(video["published_at"])
      {video, published_at}
    end)
    |> Enum.sort(fn {first, a}, {second, b} ->
      case DateTime.compare(a, b) do
        :eq -> first["id"] <= second["id"]
        order -> order == :gt
      end
    end)
    |> Enum.take(100)
    |> Enum.map(&elem(&1, 0))
  end

  def text?(text, max),
    do:
      is_binary(text) && String.valid?(text) && byte_size(text) <= max &&
        not Regex.match?(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, text)

  defp channel?(%{"id" => id, "title" => title} = row),
    do: channel_id?(id) && text?(title, 1024) && map_size(row) == 2

  defp channel?(_), do: false

  defp video?(
         %{"id" => id, "title" => title, "channel_id" => channel, "published_at" => at},
         expected
       ),
       do: video_id?(id) && text?(title, 4096) && channel == expected && timestamp?(at)

  defp video?(_, _), do: false

  defp timestamp?(at) do
    text?(at, 64) && match?({:ok, _, _}, DateTime.from_iso8601(at))
  end

  defp match_id?(id, regex), do: is_binary(id) && byte_size(id) <= 100 && Regex.match?(regex, id)
end
