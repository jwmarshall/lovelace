# Run only through `mix test.ui`: a separate test BEAM and disposable database.
if Mix.env() != :test, do: Mix.raise("UI regressions require MIX_ENV=test")

browser =
  System.get_env("LOVELACE_BROWSER") || System.find_executable("chromium") ||
    System.find_executable("chromium-browser") || System.find_executable("google-chrome") ||
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

unless File.regular?(browser),
  do: Mix.raise("Install Chrome/Chromium or set LOVELACE_BROWSER to its executable")

root = Path.join(System.tmp_dir!(), "lovelace-ui-#{Ecto.UUID.generate()}")
File.mkdir_p!(root)
File.chmod!(root, 0o700)

# No test may fall through to a real provider or credential operation. These are
# synthetic read-only responses; the normal test-build guards also remain.
defmodule Lovelace.UIFixture do
  @moduledoc false
  @behaviour Lovelace.Calendar.Provider

  alias Lovelace.TestSupport.PNG

  def get("00000000-0000-4000-8000-000000000005"), do: {:error, :locked}
  def get(_id), do: {:ok, "synthetic-refresh"}
  def put(_id, _token), do: :ok
  def delete(_id), do: :ok
  @spec refresh(binary()) :: {:ok, Lovelace.Google.OAuthProvider.tokens()}
  def refresh("synthetic-refresh"),
    do: {:ok, %{access_token: "synthetic-access", expires_in: 3600}}

  def revoke(_token), do: :ok

  @spec attachment(binary(), binary(), binary()) :: {:ok, binary()}
  def attachment("synthetic-access", "synthetic-message-3", "synthetic-photo"),
    do: {:ok, scene_image(1)}

  @impl true
  def calendars("synthetic-access") do
    {:ok,
     %{
       calendars: [
         %{id: "primary", name: "Synthetic personal", selected: true},
         %{id: "shared@example.test", name: "Synthetic shared", selected: false}
       ],
       truncated: false
     }}
  end

  @impl true
  def events("synthetic-access", calendar_id, _from, _to) do
    date = Date.utc_today() |> Date.to_iso8601()
    tomorrow = Date.utc_today() |> Date.add(1) |> Date.to_iso8601()

    {:ok,
     %{
       events: [
         %{
           id: "synthetic-all-day",
           title: "Synthetic day off",
           start: date,
           end: tomorrow,
           all_day: true,
           url: "https://calendar.google.com/calendar/event?eid=synthetic"
         },
         %{
           id: "synthetic-focus",
           title:
             if(calendar_id == "primary",
               do: "Synthetic focus time",
               else: "Synthetic shared event"
             ),
           start: date <> "T12:00:00Z",
           end: date <> "T13:00:00Z",
           all_day: false,
           url: "https://calendar.google.com/calendar/event?eid=synthetic"
         }
       ],
       truncated: false
     }}
  end

  def subscriptions("synthetic-access", nil) do
    {:ok,
     %{
       channels: [
         %{"id" => "UCaaaaaaaaaaaaaaaaaaaaaa", "title" => "Synthetic architecture"},
         %{"id" => "UCbbbbbbbbbbbbbbbbbbbbbb", "title" => "Synthetic music"}
       ],
       next_page: nil
     }}
  end

  def uploads_playlists("synthetic-access", ids) do
    {:ok, Map.new(ids, &{&1, "UU" <> String.slice(&1, 2..-1//1)})}
  end

  def uploads("synthetic-access", "UUaaaaaaaaaaaaaaaaaaaaaa") do
    {:ok,
     %{
       videos: [
         %{
           "id" => "aaaaaaaaaaa",
           "title" => "Synthetic concrete & light",
           "channel_id" => "UCaaaaaaaaaaaaaaaaaaaaaa",
           "published_at" => "2026-11-05T12:00:00Z"
         },
         %{
           "id" => "bbbbbbbbbbb",
           "title" => "Synthetic quiet spaces",
           "channel_id" => "UCaaaaaaaaaaaaaaaaaaaaaa",
           "published_at" => "2026-11-04T12:00:00Z"
         }
       ],
       truncated: false
     }}
  end

  # Deliberately synthetic geometry, not generated/private artwork. Distinct
  # palettes and silhouettes make gallery selection visible in screenshots.
  def scene_image(number) do
    palette =
      Enum.at(
        [
          {{76, 105, 109}, {38, 56, 57}, {27, 35, 37}, {188, 151, 103}},
          {{113, 101, 88}, {62, 68, 61}, {39, 43, 41}, {193, 167, 118}},
          {{80, 105, 102}, {43, 65, 62}, {29, 42, 41}, {166, 185, 160}}
        ],
        rem(number - 1, 3)
      )

    pixels = for y <- 0..269, into: <<>>, do: scene_row(y, number, palette)

    IO.iodata_to_binary([
      <<137, 80, 78, 71, 13, 10, 26, 10>>,
      PNG.chunk("IHDR", <<480::32, 270::32, 8, 6, 0, 0, 0>>),
      PNG.chunk("IDAT", :zlib.compress(pixels)),
      PNG.chunk("IEND", "")
    ])
  end

  @spec inbox(binary(), Lovelace.Mail.Provider.page_token()) ::
          {:ok, Lovelace.Mail.Provider.page()}
  def inbox("synthetic-access", _page) do
    threads =
      for number <- 1..20 do
        %{
          id: "synthetic-thread-#{number}",
          subject: "Synthetic conversation #{number}",
          from: "sender@example.test",
          snippet: "Read-only browser fixture",
          date: "Today",
          unread: false
        }
      end

    {:ok, %{threads: threads, next_page_token: nil}}
  end

  @spec search(binary(), binary(), Lovelace.Mail.Provider.page_token()) ::
          {:ok, Lovelace.Mail.Provider.page()}
  def search("synthetic-access", _query, _page), do: inbox("synthetic-access", nil)

  @spec thread(binary(), binary()) :: {:ok, Lovelace.Mail.Provider.thread()}
  def thread("synthetic-access", id) do
    # Bounded synthetic provider latency lets Chrome inspect the real loading
    # state, rather than injecting markup or racing an immediate fake response.
    Process.sleep(650)
    subject = "Synthetic conversation #{String.replace_prefix(id, "synthetic-thread-", "")}"

    latest_text =
      Enum.map_join(1..20, "\n\n", fn
        19 ->
          "https://mail-fixture.invalid/" <> String.duplicate("synthetic-unbroken-path", 30)

        20 ->
          ~s|<img src="https://mail-fixture.invalid/body.png" onerror="alert('synthetic')">|

        number ->
          "Synthetic paragraph #{number}. This read-only conversation exercises comfortable " <>
            "long-form reading, line wrapping and the shared scrolling content pane. " <>
            "Nothing in this browser fixture is real mail, and no remote content should load."
      end)

    messages =
      for number <- 1..3 do
        %{
          id: "synthetic-message-#{number}",
          subject: if(number == 2, do: "Synthetic alternate subject", else: subject),
          from: "Synthetic Sender <sender@example.test>",
          to:
            ~s(Browser <browser@example.test>, <img src="https://mail-fixture.invalid/recipient.png">),
          date:
            "Sat, 15 Mar 2025 #{String.pad_leading(to_string(number + 8), 2, "0")}:30:00 +0000",
          text: if(number == 3, do: latest_text, else: "Synthetic earlier message #{number}."),
          attachments:
            if(number == 3,
              do: [
                %{
                  attachment_id: "synthetic-photo",
                  filename: "synthetic-scene.png",
                  mime_type: "image/png",
                  size: byte_size(scene_image(1))
                }
              ],
              else: []
            )
        }
      end

    {:ok, %{id: id, messages: messages}}
  end

  defp scene_row(y, number, palette) do
    row = for x <- 0..479, into: <<>>, do: scene_pixel(x, y, number, palette)
    <<0>> <> row
  end

  defp scene_pixel(x, y, number, {sky, ground, building, light}) do
    silhouette = rem(number - 1, 7) + 1

    color =
      cond do
        within?(x, y, (72 + silhouette * 18)..(192 + silhouette * 18), 95..207) -> building
        within?(x, y, (192 + silhouette * 18)..(202 + silhouette * 18), 95..207) -> light
        within?(x, y, 290..430, (145 - silhouette * 8)..218) -> building
        within?(x, y, (16 + number * 12)..(20 + number * 12), 238..251) -> light
        y >= 226 -> ground
        true -> sky
      end

    {red, green, blue} = color
    shade = div(y, 18)
    <<max(red - shade, 0), max(green - shade, 0), max(blue - shade, 0), 255>>
  end

  defp within?(x, y, horizontal, vertical), do: x in horizontal and y in vertical
end

try do
  System.put_env("LOVELACE_STAGE_ENABLED", "false")
  # Apply migrations during disposable application startup, just as releases do.
  System.put_env("RELEASE_NAME", "ui-contract-test")
  repo = Application.fetch_env!(:lovelace, Lovelace.Repo)

  Application.put_env(
    :lovelace,
    Lovelace.Repo,
    Keyword.merge(repo, database: Path.join(root, "test.db"), pool: DBConnection.ConnectionPool)
  )

  Application.put_env(:lovelace, :gmail_provider, Lovelace.UIFixture)
  Application.put_env(:lovelace, :gmail_vault, Lovelace.UIFixture)
  Application.put_env(:lovelace, :calendar_provider, Lovelace.UIFixture)
  Application.put_env(:lovelace, :youtube_provider, Lovelace.UIFixture)
  {:ok, _} = Lovelace.TestSupport.GeminiVault.start_link([])
  Application.put_env(:lovelace, :gemini_vault, Lovelace.TestSupport.GeminiVault)
  {:ok, _} = Lovelace.TestSupport.OnboardingKeychain.start_link([])
  Application.put_env(:lovelace, :google_client_keychain, Lovelace.TestSupport.OnboardingKeychain)

  scenery = %Lovelace.StageDesigner.Settings{
    enabled: false,
    storage_dir: Path.join(root, "scenery")
  }

  Application.put_env(:lovelace, :stage_designer, scenery)
  Application.put_env(:lovelace, :workspace_idle_minutes, 3)

  # Run only explicitly exercised queues against synthetic providers/credentials.
  # No plugins or automatic sweep/polling run; test transports cannot reach providers.
  oban = Application.fetch_env!(:lovelace, Oban)

  Application.put_env(
    :lovelace,
    Oban,
    Keyword.merge(oban,
      testing: :disabled,
      queues: [gemini: 1, gmail: 1, diagnostics: 1, github: 1],
      plugins: []
    )
  )

  endpoint = Application.fetch_env!(:lovelace, LovelaceWeb.Endpoint)

  Application.put_env(
    :lovelace,
    LovelaceWeb.Endpoint,
    Keyword.merge(endpoint,
      server: true,
      http: [ip: {127, 0, 0, 1}, port: 0],
      check_origin: ["//localhost"]
    )
  )

  {:ok, _} = Application.ensure_all_started(:lovelace)
  Lovelace.Owner.configure!("synthetic browser owner password", actor: %{role: :owner_setup})
  {:ok, {_ip, port}} = LovelaceWeb.Endpoint.server_info(:http)

  # First exercise a genuinely empty installation, using only bundled public
  # artwork and a synthetic owner. No generated catalog or provider call exists.
  unless System.get_env("LOVELACE_UI_HOLD") == "true" do
    {_output, default_status} =
      System.cmd(
        "node",
        [
          "test/browser/ui_contract.mjs",
          browser,
          root,
          "http://localhost:#{port}",
          "",
          "",
          "",
          "bundled-default"
        ],
        into: IO.stream(:stdio, :line),
        env: [{"LOVELACE_STAGE_ENABLED", "false"}]
      )

    if default_status != 0, do: Mix.raise("Bundled default scenery browser regressions failed")
  end

  # The full gallery requires a configured integration. Test builds reject the
  # production Gemini connector, so this synthetic key cannot reach Google.
  :ok = Lovelace.TestSupport.GeminiVault.put(nil, "synthetic-browser-gemini-key")

  owner = %{role: :local_owner}

  :ok =
    Lovelace.Integrations.Google.ClientCredentials.save(
      "synthetic-browser-google-client",
      "synthetic-browser-google-secret"
    )

  # Publish only locally encoded fixtures through the real validated image route.
  # All 23 distinct archived images remain available beyond the recent fallback
  # window and fill two gallery pages (20 + 3), without a total retention cap.
  # Archive dates are old; seed a recent failed reservation below to verify
  # manual generation stays available inside the automatic startup cooldown.
  now = DateTime.utc_now()
  actor = %{role: :stage_designer}
  initial = Lovelace.StageDesigner.initialize_state!(%{}, actor: actor)

  Enum.reduce(1..23, initial, fn number, state ->
    generated_at = DateTime.add(now, -(24 + (24 - number) * 24) * 3600, :second)

    reserved =
      Lovelace.StageDesigner.reserve_state!(state, %{last_attempt_at: generated_at}, actor: actor)

    {:ok, published} =
      Lovelace.StageDesigner.Storage.store_and_publish(
        scenery,
        Lovelace.UIFixture.scene_image(number),
        reserved,
        generated_at
      )

    published
  end)

  Lovelace.StageDesigner.get_state!(1, actor: actor)
  |> Lovelace.StageDesigner.reserve_state!(%{last_attempt_at: now}, actor: actor)
  |> Lovelace.StageDesigner.fail_state!(%{}, actor: actor)

  workspace = Lovelace.Workspaces.create_workspace!("Browser studio", actor: owner)

  shared_workspace = Lovelace.Workspaces.create_workspace!("Synthetic space 1", actor: owner)

  for number <- 2..14,
      do: Lovelace.Workspaces.create_workspace!("Synthetic space #{number}", actor: owner)

  account =
    Lovelace.Mail.save_connection!(
      %{
        id: Ecto.UUID.generate(),
        subject: "synthetic-browser-account",
        email: "browser@example.test",
        generation: Ecto.UUID.generate(),
        calendar_enabled: true,
        youtube_enabled: true
      },
      actor: owner
    )

  Lovelace.Mail.update_account!(
    account,
    %{
      expected_generation: account.generation,
      inbox_unread_count: 7,
      inbox_unread_recent_count: 3,
      inbox_unread_at: now,
      inbox_unread_error: nil
    },
    actor: owner
  )

  for space <- [workspace, shared_workspace] do
    Lovelace.Mail.attach_account!(%{workspace_id: space.id, account_id: account.id},
      actor: owner
    )
  end

  unattached =
    Lovelace.Mail.save_connection!(
      %{
        id: Ecto.UUID.generate(),
        subject: "synthetic-unattached-browser-account",
        email: "unattached@example.test",
        generation: Ecto.UUID.generate()
      },
      actor: owner
    )

  Lovelace.Mail.update_account!(
    unattached,
    %{
      expected_generation: unattached.generation,
      inbox_unread_count: 0,
      inbox_unread_recent_count: 0,
      inbox_unread_at: now,
      inbox_unread_error: nil
    },
    actor: owner
  )

  # Seed a real bounded Calendar cache from synthetic provider data. Chrome uses UTC
  # for this fixture; production always takes its day boundaries from the browser.
  day = Date.utc_today()
  first = DateTime.new!(day, ~T[00:00:00]) |> DateTime.to_iso8601()
  last = DateTime.new!(Date.add(day, 1), ~T[00:00:00]) |> DateTime.to_iso8601()

  {:ok, %{revision: revision}} =
    Lovelace.Calendar.prepare(account.id, first, last, Date.to_iso8601(day), "UTC", actor: owner)

  {:ok, _} = Lovelace.Calendar.poll(account.id, account.generation, revision, actor: owner)

  {:ok, catalog} = Lovelace.YouTube.prepare(account.id, actor: owner)
  {:ok, _} = Lovelace.YouTube.poll(account.id, account.generation, catalog.revision, actor: owner)

  {:ok, selection} =
    Lovelace.YouTube.select_channels(
      account.id,
      ["UCaaaaaaaaaaaaaaaaaaaaaa"],
      catalog.generation,
      catalog.revision,
      actor: owner
    )

  {:ok, _} =
    Lovelace.YouTube.poll(account.id, account.generation, selection.revision, actor: owner)

  # Exercise browser-admitted refreshes through the actual worker using only
  # the synthetic provider above; seeded obsolete jobs fail their revision fence.
  :ok = Oban.start_queue(queue: :youtube, limit: 1)

  # Exercise real Connections density with five independent synthetic accounts.
  for number <- 3..5 do
    Lovelace.Mail.save_connection!(
      %{
        id:
          if(number == 5, do: "00000000-0000-4000-8000-000000000005", else: Ecto.UUID.generate()),
        subject: "synthetic-extra-browser-account-#{number}",
        email: "secondary-#{number}@example.test",
        generation: Ecto.UUID.generate()
      },
      actor: owner
    )
  end

  {:ok, _} = Lovelace.TestGitHub.start_link()
  Application.put_env(:lovelace, :github_provider, Lovelace.TestGitHub)
  Application.put_env(:lovelace, :github_keychain, Lovelace.TestGitHubKeychain)

  Lovelace.TestGitHub.configure(
    rows: [Lovelace.TestGitHub.row(%{"checks" => "FAILURE"})],
    workflow_runs: [
      Lovelace.TestGitHub.workflow_run(%{"conclusion" => "failure"}),
      Lovelace.TestGitHub.workflow_run(%{"id" => 10})
    ]
  )

  Lovelace.GitHub.save_client_credentials!(
    "Iv1.synthetic",
    "synthetic-browser-github-secret",
    "lovelace-synthetic",
    actor: owner
  )

  {:ok, session} = Lovelace.Owner.unlock("synthetic browser owner password", "github-ui-fixture")
  {:ok, _} = Lovelace.GitHub.Operations.authorize(session, Lovelace.TestGitHub.bundle())

  for organization <- Lovelace.GitHub.directory!(actor: owner).organizations do
    Lovelace.GitHub.attach!(workspace.id, organization.id, actor: owner)
    Lovelace.GitHub.poll!(organization.id, organization.generation, actor: owner)
  end

  # Bounded synthetic latency lets Chrome observe the durable discovery claim.
  Lovelace.TestGitHub.configure(installation_response: {:delay, 5_000})

  if System.get_env("LOVELACE_UI_HOLD") == "true" do
    IO.puts("SYNTHETIC_UI_READY http://localhost:#{port}/accounts/#{account.id}/youtube")
    IO.puts("Synthetic owner password: synthetic browser owner password")

    receive do
      :stop_ui_fixture -> :ok
    end
  end

  {_output, status} =
    System.cmd(
      "node",
      [
        "test/browser/ui_contract.mjs",
        browser,
        root,
        "http://localhost:#{port}",
        workspace.id,
        account.id,
        unattached.id
      ],
      into: IO.stream(:stdio, :line),
      env: [{"LOVELACE_STAGE_ENABLED", "false"}]
    )

  if status != 0, do: Mix.raise("Browser UI contract regressions failed")
after
  Application.stop(:lovelace)
  Application.stop(:oban)
  Application.stop(:ash_sqlite)
  File.rm_rf!(root)
end
