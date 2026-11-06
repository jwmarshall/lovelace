defmodule Lovelace.Integrations.YouTubeTest.Transport do
  @behaviour Lovelace.Integrations.Google.Transport
  @impl true
  def request(request, _) do
    Agent.get_and_update(__MODULE__, fn %{responses: [response | rest], requests: requests} ->
      {response, %{responses: rest, requests: [request | requests]}}
    end)
  end
end

defmodule Lovelace.Integrations.YouTubeTest do
  use ExUnit.Case, async: false
  alias Lovelace.Integrations.Google.{Transport, YouTube}
  alias Lovelace.Integrations.YouTubeTest.Transport, as: Fake
  @channel "UCaaaaaaaaaaaaaaaaaaaaaa"
  @playlist "UUaaaaaaaaaaaaaaaaaaaaaa"

  setup do
    previous = Application.get_env(:lovelace, :gmail)
    Application.put_env(:lovelace, :gmail, transport: Fake, timeout_ms: 30_000)
    {:ok, _} = Agent.start_link(fn -> %{requests: [], responses: []} end, name: Fake)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lovelace, :gmail, previous),
        else: Application.delete_env(:lovelace, :gmail)
    end)

    :ok
  end

  defp respond(data, status \\ 200) do
    response =
      {:ok,
       %{
         status: status,
         headers: [{"content-type", "application/json"}],
         body: Jason.encode!(data)
       }}

    Agent.update(Fake, &%{&1 | responses: &1.responses ++ [response]})
  end

  defp requests, do: Agent.get(Fake, &Enum.reverse(&1.requests))

  test "only exact allowlisted read endpoints pass the shared private transport" do
    request = %{
      method: "GET",
      host: "www.googleapis.com",
      path: "/youtube/v3/subscriptions?mine=true",
      timeout_ms: 5000,
      body: "",
      headers: [{"accept", "application/json"}]
    }

    for endpoint <- ["subscriptions", "channels", "playlistItems"] do
      assert :ok = Transport.validate(%{request | path: "/youtube/v3/" <> endpoint})
    end

    for path <- [
          "/youtube/v3/search",
          "/youtube/v3/videos",
          "/youtube/v3/comments",
          "/youtube/v3/subscriptions/extra",
          "/youtube/v3/../subscriptions",
          "/youtube/v3/%73ubscriptions",
          "/youtube/v3/subscriptions#fragment",
          "/youtube/v3/subscriptions\n"
        ] do
      assert {:error, :invalid_request} = Transport.validate(%{request | path: path})
    end

    for method <- ["POST", "DELETE", "PUT"] do
      assert {:error, :invalid_request} = Transport.validate(%{request | method: method})
    end

    assert {:error, :invalid_request} = Transport.validate(%{request | host: "youtube.com"})

    assert {:error, :invalid_request} =
             Transport.validate(%{request | host: "www.googleapis.com.attacker.invalid"})
  end

  test "subscriptions request only minimal mine pages and normalize safe text" do
    respond(%{
      "items" => [
        %{
          "snippet" => %{
            "title" => "Untrusted <script>",
            "resourceId" => %{"channelId" => @channel},
            "thumbnails" => %{"url" => "https://attacker.invalid"}
          }
        }
      ],
      "nextPageToken" => "opaque-next"
    })

    assert {:ok,
            %{
              channels: [%{"id" => @channel, "title" => "Untrusted <script>"}],
              next_page: "opaque-next"
            }} = YouTube.subscriptions("synthetic", nil)

    [request] = requests()
    assert request.method == "GET" && request.host == "www.googleapis.com"
    assert request.timeout_ms == 5000
    uri = URI.parse(request.path)
    query = URI.decode_query(uri.query)

    assert uri.path == "/youtube/v3/subscriptions" && query["mine"] == "true" &&
             query["maxResults"] == "50"

    refute Map.has_key?(query, "pageToken")
    refute String.contains?(query["fields"], "thumbnails")
    respond(%{"items" => []})

    assert {:ok, %{channels: [], next_page: nil}} =
             YouTube.subscriptions("synthetic", "opaque-next")

    assert URI.decode_query(URI.parse(List.last(requests()).path).query)["pageToken"] ==
             "opaque-next"
  end

  test "selected channels resolve only uploads playlists and actual video publication timestamps" do
    respond(%{
      "items" => [
        %{
          "id" => @channel,
          "contentDetails" => %{"relatedPlaylists" => %{"uploads" => @playlist}}
        }
      ]
    })

    assert {:ok, %{@channel => @playlist}} = YouTube.uploads_playlists("synthetic", [@channel])
    query = URI.decode_query(URI.parse(hd(requests()).path).query)
    assert query["id"] == @channel

    respond(%{
      "items" => [
        %{
          "snippet" => %{
            "title" => "Synthetic",
            "channelId" => @channel,
            "publishedAt" => "2026-11-06T12:00:00Z",
            "resourceId" => %{"videoId" => "video000001"}
          },
          "contentDetails" => %{"videoPublishedAt" => "2026-11-01T12:00:00Z"}
        }
      ],
      "nextPageToken" => "ignored"
    })

    assert {:ok,
            %{
              videos: [
                %{
                  "published_at" => "2026-11-01T12:00:00Z",
                  "channel_id" => @channel,
                  "id" => "video000001"
                }
              ],
              truncated: true
            }} = YouTube.uploads("synthetic", @playlist)

    query = URI.decode_query(URI.parse(List.last(requests()).path).query)
    assert query["playlistId"] == @playlist && query["maxResults"] == "10"
    refute Enum.any?(requests(), &String.contains?(&1.path, "/videos"))
  end

  test "private/deleted unavailable entries are omitted with honest partial warning" do
    respond(%{
      "items" => [
        %{"snippet" => %{"title" => "Private video"}},
        %{"snippet" => %{"title" => "Deleted video"}}
      ]
    })

    assert {:ok, %{videos: [], truncated: true}} = YouTube.uploads("synthetic", @playlist)
  end

  test "invalid IDs, excessive pages and wrong selected-channel payloads fail closed" do
    assert {:error, :invalid_request} = YouTube.uploads("synthetic", "../../search")

    assert {:error, :invalid_request} =
             YouTube.uploads_playlists("synthetic", ["https://attacker.invalid"])

    assert requests() == []
    respond(%{"items" => List.duplicate(%{}, 51)})
    assert {:error, :invalid_response} = YouTube.subscriptions("synthetic", nil)

    respond(%{
      "items" => [
        %{
          "id" => "UCbbbbbbbbbbbbbbbbbbbbbb",
          "contentDetails" => %{"relatedPlaylists" => %{"uploads" => @playlist}}
        }
      ]
    })

    assert {:error, :invalid_response} = YouTube.uploads_playlists("synthetic", [@channel])
  end

  test "quota and credential failures escape only as finite atoms" do
    respond(
      %{
        "error" => %{
          "errors" => [%{"reason" => "quotaExceeded", "message" => "private provider text"}]
        }
      },
      403
    )

    assert {:error, :rate_limited} = YouTube.subscriptions("synthetic", nil)
    respond(%{"private" => "never return"}, 401)
    assert {:error, :reconnect} = YouTube.subscriptions("synthetic", nil)
    respond(%{"private" => "never return"}, 500)
    assert {:error, :provider} = YouTube.subscriptions("synthetic", nil)
  end

  test "redirects, encoded responses and oversized bodies are never accepted" do
    for response <- [
          %{status: 302, headers: [{"location", "https://attacker.invalid"}], body: ""},
          %{
            status: 200,
            headers: [{"content-type", "application/json"}, {"content-encoding", "gzip"}],
            body: "{}"
          },
          %{status: 200, headers: [{"content-type", "text/html"}], body: "{}"},
          %{
            status: 200,
            headers: [{"content-type", "application/json"}],
            body: String.duplicate("x", 512 * 1024 + 1)
          }
        ] do
      Agent.update(Fake, &%{&1 | responses: [{:ok, response}]})
      assert {:error, reason} = YouTube.subscriptions("synthetic", nil)
      assert reason in [:provider, :invalid_response]
    end
  end

  test "unsafe bearer tokens and page cursors fail before the transport sees credentials" do
    for token <- [
          "synthetic\r\nx-injected: secret",
          "synthetic\0secret",
          nil,
          ["synthetic"],
          String.duplicate("x", 16_385)
        ] do
      assert {:error, :invalid_request} = YouTube.subscriptions(token, nil)
    end

    for page <- [%{"private" => "cursor"}, "cursor\0injected", String.duplicate("x", 4097)] do
      assert {:error, :invalid_request} = YouTube.subscriptions("synthetic", page)
    end

    assert requests() == []
  end

  test "ambiguous JSON headers and excessive header bytes cannot publish a page" do
    responses = [
      %{
        status: 200,
        headers: [{"content-type", "application/json"}, {"Content-Type", "application/json"}],
        body: ~s({"items":[]})
      },
      %{
        status: 200,
        headers: [
          {"content-type", "application/json"},
          {"content-encoding", "identity"},
          {"Content-Encoding", "identity"}
        ],
        body: ~s({"items":[]})
      },
      %{
        status: 200,
        headers: [
          {"content-type", "application/json"},
          {"x-private-provider-header", String.duplicate("x", 64 * 1024)}
        ],
        body: ~s({"items":[]})
      }
    ]

    Agent.update(Fake, &%{&1 | responses: Enum.map(responses, fn row -> {:ok, row} end)})

    for _ <- responses do
      assert {:error, :invalid_response} = YouTube.subscriptions("synthetic", nil)
    end

    assert length(requests()) == length(responses)
  end

  test "malformed transport header shapes return only a safe provider failure" do
    for headers <- [[{"content-type", %{private: "provider secret"}}], ["malformed header"]] do
      Agent.update(
        Fake,
        &%{&1 | responses: [{:ok, %{status: 200, headers: headers, body: ~s({"items":[]})}}]}
      )

      assert {:error, :provider} = YouTube.subscriptions("synthetic", nil)
    end
  end

  test "invalid JSON, non-object JSON and an unusable next cursor are not empty catalogs" do
    for body <- [
          ~s({"items":),
          ~s([{"items":[]}]),
          ~s({"items":[],"nextPageToken":{"private":"cursor"}})
        ] do
      Agent.update(
        Fake,
        &%{
          &1
          | responses: [
              {:ok, %{status: 200, headers: [{"content-type", "application/json"}], body: body}}
            ]
        }
      )

      assert {:error, :invalid_response} = YouTube.subscriptions("synthetic", nil)
    end
  end

  test "subscription duplicates keep the first title without losing the next-page cursor" do
    respond(%{
      "items" =>
        Enum.map(["First title", "Later conflicting title"], fn title ->
          %{"snippet" => %{"title" => title, "resourceId" => %{"channelId" => @channel}}}
        end),
      "nextPageToken" => "next-page"
    })

    assert {:ok,
            %{
              channels: [%{"id" => @channel, "title" => "First title"}],
              next_page: "next-page"
            }} = YouTube.subscriptions("synthetic", nil)
  end

  test "duplicate playlist mappings and unexpected channel pagination fail closed" do
    playlist = %{
      "id" => @channel,
      "contentDetails" => %{"relatedPlaylists" => %{"uploads" => @playlist}}
    }

    respond(%{"items" => [playlist, playlist]})
    assert {:error, :invalid_response} = YouTube.uploads_playlists("synthetic", [@channel])
    respond(%{"items" => [playlist], "nextPageToken" => "unexpected-extra-channels"})
    assert {:error, :invalid_response} = YouTube.uploads_playlists("synthetic", [@channel])
    assert length(requests()) == 2
  end

  test "a visible video without its publication metadata fails the whole page" do
    snippet = %{
      "title" => "Visible upload",
      "channelId" => @channel,
      "resourceId" => %{"videoId" => "video000001"}
    }

    respond(%{
      "items" => [
        %{
          "snippet" => snippet,
          "contentDetails" => %{"videoPublishedAt" => "2026-11-06T12:00:00Z"}
        },
        %{"snippet" => %{snippet | "resourceId" => %{"videoId" => "video000002"}}}
      ]
    })

    assert {:error, :invalid_response} = YouTube.uploads("synthetic", @playlist)
  end

  test "permission, mixed quota, throttling and network failures expose no private payload" do
    respond(
      %{
        "error" => %{
          "errors" => [%{"reason" => "insufficientPermissions", "message" => "secret"}]
        }
      },
      403
    )

    assert {:error, :reconnect} = YouTube.subscriptions("synthetic", nil)

    respond(
      %{
        "error" => %{
          "errors" => [
            "private malformed row",
            %{"reason" => "dailyLimitExceeded", "message" => "private quota details"}
          ]
        }
      },
      403
    )

    assert {:error, :rate_limited} = YouTube.subscriptions("synthetic", nil)
    respond(%{"private" => "throttled response"}, 429)
    assert {:error, :rate_limited} = YouTube.subscriptions("synthetic", nil)

    Agent.update(
      Fake,
      &%{&1 | responses: [{:error, %{reason: :closed, private: "transport secret"}}]}
    )

    assert {:error, :provider} = YouTube.subscriptions("synthetic", nil)
    assert length(requests()) == 4
  end

  test "missing subscription and playlist identity metadata invalidates the entire page" do
    valid_subscription = %{
      "snippet" => %{"title" => "Safe", "resourceId" => %{"channelId" => @channel}}
    }

    valid_playlist = %{
      "id" => @channel,
      "contentDetails" => %{"relatedPlaylists" => %{"uploads" => @playlist}}
    }

    respond(%{"items" => [valid_subscription, %{"snippet" => %{"title" => "No identity"}}]})
    assert {:error, :invalid_response} = YouTube.subscriptions("synthetic", nil)
    respond(%{"items" => [valid_playlist, %{"id" => @channel}]})
    assert {:error, :invalid_response} = YouTube.uploads_playlists("synthetic", [@channel])
  end

  test "an invalid transport envelope is not an empty feed and opaque permission denial reconnects" do
    Agent.update(Fake, &%{&1 | responses: [{:ok, %{private: "invalid response"}}]})
    assert {:error, :invalid_response} = YouTube.subscriptions("synthetic", nil)
    respond(%{"private" => "permission denied"}, 403)
    assert {:error, :reconnect} = YouTube.subscriptions("synthetic", nil)
  end
end
