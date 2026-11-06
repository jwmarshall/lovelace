defmodule Lovelace.Integrations.GoogleTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Lovelace.Integrations.Google

  defmodule FakeTransport do
    @behaviour Google.Transport
    @impl true
    def request(request, options), do: Keyword.fetch!(options, :handler).(request)
  end

  defmodule FakeCredentials do
    def read, do: {:ok, %{client_id: "fake-client", client_secret: "fake-client-secret"}}
  end

  defmodule MissingCredentials do
    def read, do: {:error, :invalid_configuration}
  end

  @redirect "http://localhost:4000/oauth/google/callback"
  @verifier String.duplicate("v", 43)
  @access "fake-access-secret"
  @refresh "fake-refresh-secret"

  setup do
    previous = Application.get_env(:lovelace, :gmail)
    previous_credentials = Application.fetch_env(:lovelace, :google_client_credentials)
    Application.put_env(:lovelace, :google_client_credentials, FakeCredentials)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lovelace, :gmail, previous),
        else: Application.delete_env(:lovelace, :gmail)

      case previous_credentials do
        {:ok, adapter} -> Application.put_env(:lovelace, :google_client_credentials, adapter)
        :error -> Application.delete_env(:lovelace, :google_client_credentials)
      end
    end)

    configure(fn _ -> flunk("unexpected protocol request") end)
    :ok
  end

  test "missing vaulted client credentials fail before protocol requests" do
    Application.put_env(:lovelace, :google_client_credentials, MissingCredentials)

    assert {:error, :invalid_configuration} =
             Google.authorization_url(%{
               state: "state-state-state",
               verifier: @verifier,
               redirect_uri: @redirect
             })

    assert {:error, :invalid_configuration} =
             Google.exchange_code("fake-code", @verifier, @redirect)
  end

  test "authorization is readonly, offline consent, account selection and PKCE S256" do
    assert {:ok, url} =
             Google.authorization_url(%{
               state: "state-state-state",
               verifier: @verifier,
               redirect_uri: @redirect
             })

    uri = URI.parse(url)

    assert {uri.scheme, uri.host, uri.path} ==
             {"https", "accounts.google.com", "/o/oauth2/v2/auth"}

    params = URI.decode_query(uri.query)
    assert params["scope"] == "openid email https://www.googleapis.com/auth/gmail.readonly"
    assert params["prompt"] == "consent select_account"
    assert params["access_type"] == "offline"
    assert params["code_challenge_method"] == "S256"

    assert params["code_challenge"] ==
             Base.url_encode64(:crypto.hash(:sha256, @verifier), padding: false)

    assert params["redirect_uri"] == @redirect
    refute Map.has_key?(params, "code_verifier")
    refute Map.has_key?(params, "client_secret")
  end

  test "Calendar consent is explicit and adds only the two readonly Calendar scopes" do
    params = %{state: "state-state-state", verifier: @verifier, redirect_uri: @redirect}
    assert {:ok, url} = Google.authorization_url(Map.put(params, :capability, :calendar))
    scopes = URI.decode_query(URI.parse(url).query)["scope"] |> String.split()

    assert scopes == [
             "openid",
             "email",
             "https://www.googleapis.com/auth/gmail.readonly",
             "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
             "https://www.googleapis.com/auth/calendar.events.readonly"
           ]

    assert {:error, :invalid_request} =
             Google.authorization_url(Map.put(params, :capability, :unknown))
  end

  test "YouTube requests only readonly scope and composes previously explicit optional grants" do
    params = %{state: "state-state-state", verifier: @verifier, redirect_uri: @redirect}
    youtube = "https://www.googleapis.com/auth/youtube.readonly"

    calendar = [
      "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
      "https://www.googleapis.com/auth/calendar.events.readonly"
    ]

    base = ["openid", "email", "https://www.googleapis.com/auth/gmail.readonly"]

    assert {:ok, url} = Google.authorization_url(Map.put(params, :capability, :youtube))
    assert String.split(URI.decode_query(URI.parse(url).query)["scope"]) == base ++ [youtube]

    for capability <- [:calendar, :youtube] do
      assert {:ok, url} =
               Google.authorization_url(
                 Map.merge(params, %{capability: capability, capabilities: [:calendar, :youtube]})
               )

      assert String.split(URI.decode_query(URI.parse(url).query)["scope"]) ==
               base ++ calendar ++ [youtube]
    end

    for invalid <- [
          %{capability: :gmail, capabilities: [:youtube]},
          %{capability: :youtube, capabilities: [:calendar]},
          %{capability: :youtube, capabilities: [:youtube, :unknown]},
          %{capability: :youtube, capabilities: "youtube"}
        ] do
      assert {:error, :invalid_request} = Google.authorization_url(Map.merge(params, invalid))
    end
  end

  test "YouTube scope evidence survives tokens; broader YouTube grants are rejected" do
    gmail = "https://www.googleapis.com/auth/gmail.readonly"
    youtube = "https://www.googleapis.com/auth/youtube.readonly"
    scope = "openid email " <> gmail <> " " <> youtube

    configure(fn _ ->
      json(%{access_token: @access, expires_in: 3600, token_type: "Bearer", scope: scope})
    end)

    assert {:ok, tokens} = Google.exchange_code("fake-code", @verifier, @redirect)
    assert Google.youtube_authorized?(tokens)
    assert {:ok, refreshed} = Google.refresh(@refresh)
    assert refreshed.scopes == String.split(scope)
    refute Google.youtube_authorized?(%{})
    refute Google.youtube_authorized?(%{scopes: [gmail]})
    refute Google.youtube_authorized?(%{scopes: [youtube]})
    refute Google.calendar_authorized?(tokens)

    for extra <- [
          "https://www.googleapis.com/auth/youtube",
          "https://www.googleapis.com/auth/youtube.force-ssl",
          "https://www.googleapis.com/auth/youtube.upload"
        ] do
      configure(fn _ ->
        json(%{
          access_token: @access,
          expires_in: 3600,
          token_type: "Bearer",
          scope: scope <> " " <> extra
        })
      end)

      assert {:error, :invalid_response} = Google.refresh(@refresh)
    end
  end

  test "token scope evidence survives exchange and refresh without accepting wider Calendar grants" do
    scope =
      "openid email https://www.googleapis.com/auth/gmail.readonly " <>
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly " <>
        "https://www.googleapis.com/auth/calendar.events.readonly"

    configure(fn _ ->
      json(%{access_token: @access, expires_in: 3600, token_type: "Bearer", scope: scope})
    end)

    assert {:ok, tokens} = Google.exchange_code("fake-code", @verifier, @redirect)
    assert Google.calendar_authorized?(tokens)
    assert {:ok, refreshed} = Google.refresh(@refresh)
    assert refreshed.scopes == String.split(scope)
    refute Google.calendar_authorized?(%{})
    refute Google.calendar_authorized?(%{scopes: tl(tl(tl(String.split(scope))))})

    for extra <- [
          "https://www.googleapis.com/auth/calendar",
          "https://www.googleapis.com/auth/calendar.events"
        ] do
      configure(fn _ ->
        json(%{
          access_token: @access,
          expires_in: 3600,
          token_type: "Bearer",
          scope: scope <> " " <> extra
        })
      end)

      assert {:error, :invalid_response} = Google.refresh(@refresh)
    end
  end

  test "redirect validation is exact, loopback only, explicit port and fixed path" do
    for redirect <- [
          "https://evil.test/oauth/google/callback",
          "http://localhost/oauth/google/callback",
          "http://localhost:4000/oauth/google/callback?x=1",
          "http://localhost:4000/oauth/google/callback#x",
          "http://user@localhost:4000/oauth/google/callback",
          "http://localhost:4000/wrong",
          "http://127.0.0.1:4000/oauth/google/callback"
        ] do
      assert {:error, _} =
               Google.authorization_url(%{
                 state: "state-state-state",
                 verifier: @verifier,
                 redirect_uri: redirect
               })
    end

    for redirect <- [
          "http://127.0.0.1:4567/oauth/google/callback",
          "http://[::1]:4567/oauth/google/callback"
        ] do
      Application.put_env(:lovelace, :gmail, %{redirect_uri: redirect})

      assert {:ok, _} =
               Google.authorization_url(%{
                 state: "state-state-state",
                 verifier: @verifier,
                 redirect_uri: redirect
               })
    end
  end

  test "exchange sends credentials only in a form body and permits omitted refresh token" do
    owner = self()

    configure(fn req ->
      send(owner, {:request, req})

      json(%{
        access_token: @access,
        refresh_token: @refresh,
        expires_in: 3600,
        token_type: "Bearer"
      })
    end)

    assert {:ok, %{access_token: @access, refresh_token: @refresh, expires_in: 3600}} =
             Google.exchange_code("fake-code", @verifier, @redirect)

    assert_receive {:request, req}
    assert {req.method, req.host, req.path} == {"POST", "oauth2.googleapis.com", "/token"}

    assert URI.decode_query(req.body) == %{
             "grant_type" => "authorization_code",
             "client_id" => "fake-client",
             "client_secret" => "fake-client-secret",
             "code" => "fake-code",
             "code_verifier" => @verifier,
             "redirect_uri" => @redirect
           }

    refute inspect(req.headers) =~ "fake-client-secret"
    configure(fn _ -> json(%{access_token: @access, expires_in: 3600, token_type: "Bearer"}) end)

    assert {:ok, %{access_token: @access, expires_in: 3600}} =
             Google.exchange_code("fake-code", @verifier, @redirect)
  end

  test "refresh permits omitted rotated refresh token and rejects excess scopes" do
    configure(fn req ->
      assert URI.decode_query(req.body)["refresh_token"] == @refresh

      json(%{
        access_token: @access,
        expires_in: 3600,
        token_type: "Bearer",
        scope: "openid email https://www.googleapis.com/auth/gmail.readonly"
      })
    end)

    assert {:ok, %{access_token: @access, expires_in: 3600}} = Google.refresh(@refresh)

    configure(fn _ ->
      json(%{
        access_token: @access,
        expires_in: 3600,
        token_type: "Bearer",
        scope: "https://mail.google.com/"
      })
    end)

    assert {:error, :invalid_response} = Google.refresh(@refresh)
  end

  test "returned scope must include readonly Gmail, accepting Google's canonical email scope" do
    for scope <- ["openid email", "", "openid email https://www.googleapis.com/auth/gmail.modify"] do
      configure(fn _ ->
        json(%{access_token: @access, expires_in: 3600, token_type: "Bearer", scope: scope})
      end)

      assert {:error, :invalid_response} = Google.exchange_code("fake-code", @verifier, @redirect)
    end

    configure(fn _ ->
      json(%{
        access_token: @access,
        expires_in: 3600,
        token_type: "Bearer",
        scope:
          "openid https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/gmail.readonly"
      })
    end)

    assert {:ok, _} = Google.exchange_code("fake-code", @verifier, @redirect)
  end

  test "identity requires verified email and stable sub" do
    configure(fn req ->
      assert {req.method, req.host, req.path} ==
               {"GET", "openidconnect.googleapis.com", "/v1/userinfo"}

      assert {"authorization", "Bearer " <> @access} in req.headers
      json(%{sub: "stable-sub", email: "fake@example.invalid", email_verified: true})
    end)

    assert {:ok, %{subject: "stable-sub", email: "fake@example.invalid"}} =
             Google.identity(@access)

    for verified <- [false, "true", nil] do
      configure(fn _ ->
        json(%{sub: "stable-sub", email: "fake@example.invalid", email_verified: verified})
      end)

      assert {:error, :invalid_response} = Google.identity(@access)
    end
  end

  test "inbox and search list at most 20 then metadata only, never read-flag writes" do
    owner = self()

    configure(fn req ->
      send(owner, {:request, req})

      if String.starts_with?(req.path, "/gmail/v1/users/me/threads?") do
        json(%{threads: [%{id: "abc"}], nextPageToken: "next-page"})
      else
        json(thread_fixture())
      end
    end)

    assert {:ok,
            %{
              threads: [
                %{
                  id: "abc",
                  subject: "Subject",
                  from: "Sender",
                  snippet: "Summary",
                  unread: true,
                  date: "Today"
                }
              ],
              next_page_token: "next-page"
            }} = Google.inbox(@access)

    assert_receive {:request, list}

    assert URI.decode_query(URI.parse(list.path).query) == %{
             "maxResults" => "20",
             "labelIds" => "INBOX"
           }

    assert_receive {:request, metadata}
    assert metadata.method == "GET"
    assert URI.decode_query(URI.parse(metadata.path).query)["format"] == "metadata"

    assert URI.query_decoder(URI.parse(metadata.path).query)
           |> Enum.filter(fn {k, _} -> k == "metadataHeaders" end) == [
             {"metadataHeaders", "Subject"},
             {"metadataHeaders", "From"},
             {"metadataHeaders", "Date"}
           ]

    assert {:ok, _} = Google.search(@access, "from:fake@example.invalid & x", "previous-page")
    assert_receive {:request, search}

    assert URI.decode_query(URI.parse(search.path).query) == %{
             "maxResults" => "20",
             "q" => "from:fake@example.invalid & x",
             "pageToken" => "previous-page"
           }
  end

  test "unread observations pair the label conversation total with an exact empty recent search" do
    owner = self()

    for count <- [0, 42] do
      configure(fn req ->
        assert req.method == "GET"
        assert req.host == "gmail.googleapis.com"
        assert {"authorization", "Bearer " <> @access} in req.headers

        case URI.parse(req.path).path do
          "/gmail/v1/users/me/labels/INBOX" ->
            send(owner, :label_request)
            json(%{id: "INBOX", threadsUnread: count, messagesUnread: 999})

          "/gmail/v1/users/me/threads" ->
            json(%{resultSizeEstimate: 1000})
        end
      end)

      assert {:ok, %{total: ^count, recent: 0}} = Google.inbox_unread(@access)
      assert_receive :label_request
      refute_receive :label_request
    end
  end

  test "unread observations reject invalid label totals and protocol errors" do
    for data <-
          [
            %{},
            %{id: "INBOX", messagesUnread: 12, resultSizeEstimate: 12},
            %{threadsUnread: 12},
            %{id: "UNREAD", threadsUnread: 12},
            %{id: "inbox", threadsUnread: 12}
          ] ++ Enum.map([nil, -1, 1.0, "12", true, [], %{}], &%{id: "INBOX", threadsUnread: &1}) do
      configure(fn _ -> json(data) end)
      assert {:error, :invalid_response} = Google.inbox_unread(@access)
    end

    for {status, reason} <- [{401, :unauthorized}, {429, :rate_limited}, {503, :provider_error}] do
      configure(fn _ -> {:ok, %{status: status, headers: [], body: ""}} end)
      assert {:error, ^reason} = Google.inbox_unread(@access)
    end

    assert {:error, :invalid_request} = Google.inbox_unread("invalid token")
  end

  test "recent unread counts unique fully paged thread IDs with one fixed received-time cutoff" do
    owner = self()
    started = DateTime.utc_now() |> DateTime.to_unix()

    configure(fn req ->
      uri = URI.parse(req.path)

      case uri.path do
        "/gmail/v1/users/me/labels/INBOX" ->
          send(owner, {:label_deadline, req.timeout_ms})
          json(%{id: "INBOX", threadsUnread: 42})

        "/gmail/v1/users/me/threads" ->
          params = URI.decode_query(uri.query)
          assert params["maxResults"] == "500"
          assert params["fields"] == "threads/id,nextPageToken"
          refute Map.has_key?(params, "format")

          assert URI.query_decoder(uri.query)
                 |> Enum.filter(fn {key, _} -> key == "labelIds" end) ==
                   [{"labelIds", "INBOX"}, {"labelIds", "UNREAD"}]

          send(owner, {:recent_query, params["q"], req.timeout_ms})

          case params["pageToken"] do
            nil ->
              json(%{
                threads: [%{id: "a"}, %{id: "b"}],
                nextPageToken: "next",
                resultSizeEstimate: 999
              })

            "next" ->
              json(%{threads: [%{id: "b"}, %{id: "c"}], resultSizeEstimate: 1})
          end
      end
    end)

    assert {:ok, %{total: 42, recent: 3}} = Google.inbox_unread(@access)
    finished = DateTime.utc_now() |> DateTime.to_unix()
    assert_receive {:label_deadline, label_deadline}
    assert_receive {:recent_query, query, first_deadline}
    assert_receive {:recent_query, ^query, second_deadline}
    assert second_deadline <= first_deadline
    assert first_deadline <= label_deadline
    assert [_, cutoff, until] = Regex.run(~r/\Aafter:(\d+) before:(\d+)\z/, query)
    assert String.to_integer(until) - String.to_integer(cutoff) == 86_400
    assert String.to_integer(until) in started..finished
  end

  test "recent unread accepts the exact page bound only if every page is complete" do
    owner = self()

    for more? <- [false, true] do
      configure(fn req ->
        uri = URI.parse(req.path)

        if uri.path == "/gmail/v1/users/me/labels/INBOX" do
          json(%{id: "INBOX", threadsUnread: 10_000})
        else
          params = URI.decode_query(uri.query)
          page = if params["pageToken"], do: String.to_integer(params["pageToken"]), else: 1
          send(owner, {:recent_page, page})
          threads = for id <- 1..500, do: %{id: "#{page}-#{id}"}
          data = %{threads: threads, resultSizeEstimate: 1}

          data =
            if page < 10 or more?, do: Map.put(data, :nextPageToken, "#{page + 1}"), else: data

          json(data)
        end
      end)

      if more? do
        assert {:error, :response_too_large} = Google.inbox_unread(@access)
      else
        assert {:ok, %{total: 10_000, recent: 5000}} = Google.inbox_unread(@access)
      end

      for page <- 1..10, do: assert_receive({:recent_page, ^page})
      refute_receive {:recent_page, _}
    end
  end

  test "recent unread never publishes label or partial counts on later page errors" do
    for {response, reason} <- [
          {json(%{threads: [%{id: "../unsafe"}]}), :invalid_response},
          {json(%{threads: nil}), :invalid_response},
          {json(%{threads: List.duplicate(%{id: "a"}, 501)}), :invalid_response},
          {json(%{nextPageToken: ""}), :invalid_response},
          {json(%{threads: [%{id: "b"}], nextPageToken: "next"}), :invalid_response},
          {{:ok, %{status: 429, headers: [], body: ""}}, :rate_limited},
          {{:ok, %{status: 401, headers: [], body: ""}}, :unauthorized},
          {{:ok, %{status: 503, headers: [], body: ""}}, :provider_error},
          {{:error, :timeout}, :timeout}
        ] do
      configure(fn req ->
        uri = URI.parse(req.path)

        cond do
          uri.path == "/gmail/v1/users/me/labels/INBOX" ->
            json(%{id: "INBOX", threadsUnread: 42})

          URI.decode_query(uri.query)["pageToken"] == "next" ->
            response

          true ->
            json(%{threads: [%{id: "a"}], nextPageToken: "next", resultSizeEstimate: 1})
        end
      end)

      assert {:error, ^reason} = Google.inbox_unread(@access)
    end
  end

  test "one whole-operation deadline covers the label and every recent unread page" do
    owner = self()

    configure(
      fn req ->
        uri = URI.parse(req.path)

        cond do
          uri.path == "/gmail/v1/users/me/labels/INBOX" ->
            json(%{id: "INBOX", threadsUnread: 42})

          is_nil(URI.decode_query(uri.query)["pageToken"]) ->
            json(%{threads: [%{id: "a"}], nextPageToken: "next"})

          true ->
            send(owner, :recent_page_waiting)

            receive do
              :never_sent -> json(%{})
            end
        end
      end,
      timeout_ms: 100
    )

    assert {:error, :timeout} = Google.inbox_unread(@access)
    assert_receive :recent_page_waiting
  end

  test "missing threads means empty page, overlarge list and unsafe IDs fail" do
    configure(fn _ -> json(%{}) end)
    assert {:ok, %{threads: [], next_page_token: nil}} = Google.inbox(@access)
    configure(fn _ -> json(%{threads: List.duplicate(%{id: "abc"}, 21)}) end)
    assert {:error, :invalid_response} = Google.inbox(@access)
    configure(fn _ -> json(%{threads: [%{id: "../unsafe"}]}) end)
    assert {:error, :invalid_response} = Google.inbox(@access)
    assert {:error, :invalid_request} = Google.thread(@access, "../unsafe")
  end

  test "full body fetched only when opening, plain preferred, attachments ignored" do
    configure(fn req ->
      assert req.method == "GET"
      assert URI.decode_query(URI.parse(req.path).query)["format"] == "full"
      fixture = thread_fixture()
      message = hd(fixture["messages"])

      payload =
        Map.merge(message["payload"], %{
          "mimeType" => "multipart/mixed",
          "parts" => [
            part("text/html", "<b>HTML</b>"),
            part("text/plain", "Plain <b>text</b>"),
            Map.put(part("text/plain", "PRIVATE ATTACHMENT"), "filename", "attachment.txt")
          ]
        })

      json(%{fixture | "messages" => [%{message | "payload" => payload}]})
    end)

    assert {:ok,
            %{
              id: "abc",
              messages: [
                %{
                  id: "msg1",
                  text: "Plain <b>text</b>",
                  subject: "Subject",
                  from: "Sender",
                  to: "Recipient",
                  date: "Today"
                }
              ]
            }} = Google.thread(@access, "abc")
  end

  test "malformed optional attachment metadata does not make the message unreadable" do
    payload = %{
      "mimeType" => "multipart/mixed",
      "parts" => [
        part("text/plain", "Readable body"),
        %{
          "mimeType" => "application/octet-stream",
          "filename" => "opaque.bin",
          "body" => %{"attachmentId" => "unsafe/segment", "size" => 4}
        }
      ]
    }

    assert {:ok, %{messages: [%{text: "Readable body", attachments: []}]}} =
             Google.Message.thread(with_body(payload), "abc")
  end

  test "attachment metadata is extracted but bytes are only fetched by explicit bounded request" do
    attachment_id = "att.part+=_~"

    payload = %{
      "mimeType" => "multipart/mixed",
      "parts" => [
        %{
          "mimeType" => "image/png",
          "filename" => "photo.png",
          "body" => %{"attachmentId" => attachment_id, "size" => 4}
        }
      ]
    }

    assert {:ok, %{messages: [%{attachments: [attachment]}]}} =
             Google.Message.thread(with_body(payload), "abc")

    assert attachment == %{
             attachment_id: attachment_id,
             filename: "photo.png",
             mime_type: "image/png",
             size: 4
           }

    configure(fn req ->
      assert req.path == "/gmail/v1/users/me/messages/msg1/attachments/#{attachment_id}"
      json(%{size: 4, data: Base.url_encode64("data", padding: false)})
    end)

    assert {:ok, "data"} = Google.attachment(@access, "msg1", attachment_id)
    assert {:error, :invalid_request} = Google.attachment(@access, "../bad", attachment_id)
    assert {:error, :invalid_request} = Google.attachment(@access, "msg1", "unsafe/segment")
  end

  test "HTML-only extraction drops active content, attributes, comments and remote references" do
    html =
      "<style>BAD STYLE</style><script>BAD SCRIPT</script><!-- hidden --><p>Hello &amp; goodbye</p><img src='https://evil.invalid/pixel'><a href='https://evil.invalid'>label</a><template>BAD TEMPLATE</template>"

    text = Google.Message.html_text(html)
    assert text =~ "Hello & goodbye"
    assert text =~ "label"

    for bad <- ["BAD", "hidden", "https://", "<img", "<script"] do
      refute text =~ bad
    end

    assert Google.Message.html_text("safe<unclosed") == "safe"
    assert Google.Message.html_text("<img title='>' src='https://evil.invalid'>safe") == "safe"

    assert Google.Message.html_text("safe<img title='unterminated > https://evil.invalid") ==
             "safe"

    assert Google.Message.html_text("&#x1F600; &lt;b&gt;") == "\u{1F600} <b>"

    assert {:ok, %{messages: [%{text: ^text}]}} =
             Google.Message.thread(with_body(part("text/html", html)), "abc")
  end

  test "MIME depth, part count, text bytes and invalid encodings are bounded" do
    deep =
      Enum.reduce(1..12, part("text/plain", "text"), fn _, p ->
        %{"mimeType" => "multipart/mixed", "parts" => [p]}
      end)

    many = %{
      "mimeType" => "multipart/mixed",
      "parts" => List.duplicate(part("text/plain", "x"), 101)
    }

    huge = part("text/plain", String.duplicate("x", 256 * 1024 + 1))

    for payload <- [deep, many, huge] do
      assert {:error, :response_too_large} = Google.Message.thread(with_body(payload), "abc")
    end

    assert {:error, :invalid_response} =
             Google.Message.thread(
               with_body(%{"mimeType" => "text/plain", "body" => %{"data" => "%%%"}}),
               "abc"
             )
  end

  test "revoke is explicit POST body and does not retry" do
    owner = self()

    configure(fn req ->
      send(owner, {:request, req})
      assert {req.method, req.path, req.body} == {"POST", "/revoke", "token=" <> @refresh}
      {:ok, %{status: 200, headers: [], body: ""}}
    end)

    assert :ok = Google.revoke(@refresh)
    assert_receive {:request, _}
    refute_receive {:request, _}
  end

  test "errors, exceptions, fake payloads and timeouts are contained without logs or Finch telemetry" do
    id = "google-sensitive-test"

    events = [
      [:finch, :request, :start],
      [:finch, :request, :stop],
      [:finch, :request, :exception]
    ]

    :telemetry.attach_many(
      id,
      events,
      &__MODULE__.telemetry_handler/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(id) end)
    configure(fn _ -> raise "sensitive: #{@access}" end)

    assert capture_log(fn -> assert {:error, :provider_error} = Google.identity(@access) end) ==
             ""

    refute_receive {:telemetry, _, _, _}
    configure(fn _ -> {:error, {:sensitive, @access}} end)
    assert {:error, :transport_error} = Google.identity(@access)

    configure(
      fn _ ->
        Process.sleep(100)
        json(%{})
      end,
      timeout_ms: 10
    )

    assert {:error, :timeout} = Google.identity(@access)

    configure(fn _ ->
      {:ok,
       %{
         status: 400,
         headers: [],
         body: Jason.encode!(%{error: "invalid_grant", secret: @refresh})
       }}
    end)

    assert {:error, :invalid_grant} = Google.refresh(@refresh)

    configure(fn _ ->
      {:ok, %{status: 302, headers: [{"location", "https://evil.invalid"}], body: @access}}
    end)

    assert {:error, :provider_error} = Google.identity(@access)
  end

  test "response caps, compressed payload rejection, and missing fake fail closed" do
    configure(fn _ ->
      {:ok, %{status: 200, headers: [], body: String.duplicate("x", 10 * 1024 * 1024 + 1)}}
    end)

    assert {:error, :response_too_large} = Google.identity(@access)

    configure(fn _ ->
      {:ok, %{status: 200, headers: [{"large", String.duplicate("x", 64 * 1024)}], body: "{}"}}
    end)

    assert {:error, :response_too_large} = Google.identity(@access)

    configure(fn _ ->
      {:ok,
       %{
         status: 200,
         headers: [{"content-type", "application/json"}, {"content-encoding", "gzip"}],
         body: "{}"
       }}
    end)

    assert {:error, :invalid_response} = Google.identity(@access)
    Application.put_env(:lovelace, :gmail, [])
    assert {:error, :transport_error} = Google.identity(@access)
  end

  def telemetry_handler(event, measurements, metadata, owner),
    do: send(owner, {:telemetry, event, measurements, metadata})

  defp configure(handler, extra \\ []) do
    Application.put_env(
      :lovelace,
      :gmail,
      Keyword.merge([transport: FakeTransport, transport_options: [handler: handler]], extra)
    )
  end

  defp json(data),
    do:
      {:ok,
       %{
         status: 200,
         headers: [{"content-type", "application/json; charset=utf-8"}],
         body: Jason.encode!(data)
       }}

  defp part(mime, text),
    do: %{"mimeType" => mime, "body" => %{"data" => Base.url_encode64(text, padding: false)}}

  defp with_body(body) do
    fixture = thread_fixture()
    message = hd(fixture["messages"])
    body = Map.put(body, "headers", message["payload"]["headers"])
    %{fixture | "messages" => [%{message | "payload" => body}]}
  end

  defp thread_fixture do
    %{
      "id" => "abc",
      "snippet" => "Summary",
      "messages" => [
        %{
          "id" => "msg1",
          "labelIds" => ["INBOX", "UNREAD"],
          "payload" => %{
            "headers" => [
              %{"name" => "Subject", "value" => "Subject"},
              %{"name" => "From", "value" => "Sender"},
              %{"name" => "To", "value" => "Recipient"},
              %{"name" => "Date", "value" => "Today"}
            ]
          }
        }
      ]
    }
  end
end
