# Run only through `mix test.ui`: a separate test BEAM and disposable database.
if Mix.env() != :test, do: Mix.raise("UI regressions require MIX_ENV=test")

review = System.get_env("MONOLITH_UI_REVIEW")
unless review in [nil, "full", "setup"], do: Mix.raise("MONOLITH_UI_REVIEW must be full or setup")

browser =
  System.get_env("MONOLITH_BROWSER") || System.find_executable("chromium") ||
    System.find_executable("chromium-browser") || System.find_executable("google-chrome") ||
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

if is_nil(review) and not File.regular?(browser),
  do: Mix.raise("Provide Chrome/Chromium through MONOLITH_BROWSER; no tools are installed")

root = Path.join(System.tmp_dir!(), "monolith-ui-#{Ecto.UUID.generate()}")
File.mkdir_p!(root)
File.chmod!(root, 0o700)

review_owner = self()

if review do
  System.trap_signal(:sigterm, :monolith_ui_review, fn -> send(review_owner, :stop_ui_review) end)
end

# No test may fall through to a real provider or credential operation. These are
# synthetic read-only responses; the normal test-build guards also remain.
defmodule Monolith.UIFixture do
  @moduledoc false
  @behaviour Monolith.Calendar.Provider

  alias Monolith.TestSupport.PNG

  def get("00000000-0000-4000-8000-000000000005"), do: {:error, :locked}
  def get(_id), do: {:ok, "synthetic-refresh"}
  def put(_id, _token), do: :ok
  def delete(_id), do: :ok
  @spec refresh(binary()) :: {:ok, Monolith.Google.OAuthProvider.tokens()}
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

  @spec inbox(binary(), Monolith.Mail.Provider.page_token()) ::
          {:ok, Monolith.Mail.Provider.page()}
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

  @spec search(binary(), binary(), Monolith.Mail.Provider.page_token()) ::
          {:ok, Monolith.Mail.Provider.page()}
  def search("synthetic-access", _query, _page), do: inbox("synthetic-access", nil)

  @spec thread(binary(), binary()) :: {:ok, Monolith.Mail.Provider.thread()}
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
  System.put_env("MONOLITH_STAGE_ENABLED", "false")
  # Do not inherit a workstation's native-vault opt-in in this test-only process.
  Application.put_env(:monolith, :vault_managed, false)
  # Apply migrations during disposable application startup, just as releases do.
  System.put_env("RELEASE_NAME", "ui-contract-test")
  repo = Application.fetch_env!(:monolith, Monolith.Repo)

  Application.put_env(
    :monolith,
    Monolith.Repo,
    Keyword.merge(repo, database: Path.join(root, "test.db"), pool: DBConnection.ConnectionPool)
  )

  Application.put_env(:monolith, :gmail_provider, Monolith.UIFixture)
  Application.put_env(:monolith, :gmail_vault, Monolith.UIFixture)
  Application.put_env(:monolith, :calendar_provider, Monolith.UIFixture)
  {:ok, _} = Monolith.TestSupport.GeminiVault.start_link([])
  Application.put_env(:monolith, :gemini_vault, Monolith.TestSupport.GeminiVault)
  {:ok, _} = Monolith.TestSupport.OnboardingKeychain.start_link([])
  Application.put_env(:monolith, :google_client_keychain, Monolith.TestSupport.OnboardingKeychain)

  scenery = %Monolith.StageDesigner.Settings{
    enabled: false,
    storage_dir: Path.join(root, "scenery")
  }

  Application.put_env(:monolith, :stage_designer, scenery)
  Application.put_env(:monolith, :workspace_idle_minutes, 3)

  # Run only explicitly exercised queues against synthetic providers/credentials.
  # No plugins or automatic sweep/polling run; test transports cannot reach providers.
  oban = Application.fetch_env!(:monolith, Oban)

  Application.put_env(
    :monolith,
    Oban,
    Keyword.merge(oban,
      testing: :disabled,
      queues: [gemini: 1, gmail: 1, calendar: 1, diagnostics: 1, github: 1],
      plugins: []
    )
  )

  endpoint = Application.fetch_env!(:monolith, MonolithWeb.Endpoint)

  Application.put_env(
    :monolith,
    MonolithWeb.Endpoint,
    Keyword.merge(endpoint,
      server: true,
      http: [ip: {127, 0, 0, 1}, port: 0],
      check_origin: ["//localhost"]
    )
  )

  {:ok, _} = Application.ensure_all_started(:monolith)
  {:ok, {_ip, port}} = MonolithWeb.Endpoint.server_info(:http)
  origin = "http://localhost:#{port}"

  if review == "setup" do
    # Test builds intentionally bypass the native vault. Exercise the actual
    # terminal pairing and password forms against only this disposable Ash DB.
    # Never change the production Bootstrap callback or enable native storage.
    :ok = Supervisor.terminate_child(Monolith.Supervisor, Monolith.Security.Bootstrap)
    :ok = Supervisor.delete_child(Monolith.Supervisor, Monolith.Security.Bootstrap)

    {:ok, _} =
      Monolith.Security.Bootstrap.start_link(
        status: fn ->
          if match?({:ok, true}, Monolith.Owner.configured()), do: :configured, else: :new
        end,
        announce: fn code -> IO.puts("Synthetic terminal pairing code: #{code}") end,
        configure: fn password ->
          Monolith.Owner.configure!(password, actor: %{role: :owner_setup})
          Monolith.Owner.unlock(password, "synthetic-ui-setup")
        end
      )

    IO.puts("MONOLITH synthetic setup review: #{origin}/setup")
    IO.puts("Disposable root: #{root}")
    IO.puts("Suggested synthetic password: synthetic browser owner password")

    IO.puts(
      "Native vault is not exercised. Pair once, set a synthetic password; no real credentials."
    )

    IO.puts("Stop this owned process to tear down its server and disposable storage.")

    receive do
      :stop_ui_review -> throw(:ui_review_finished)
    end
  end

  Monolith.Owner.configure!("synthetic browser owner password", actor: %{role: :owner_setup})

  if is_nil(review) do
    # Empty-installation regressions run only in automated mode.
    {_output, default_status} =
      System.cmd(
        "node",
        [
          "test/browser/ui_contract.mjs",
          browser,
          root,
          origin,
          "",
          "",
          "",
          "bundled-default"
        ],
        into: IO.stream(:stdio, :line),
        env: [{"MONOLITH_STAGE_ENABLED", "false"}]
      )

    if default_status != 0, do: Mix.raise("Bundled default scenery browser regressions failed")
  end

  # Test transports reject production Gemini calls even with this synthetic key.
  :ok = Monolith.TestSupport.GeminiVault.put(nil, "synthetic-browser-gemini-key")
  owner = %{role: :local_owner}

  :ok =
    Monolith.Integrations.Google.ClientCredentials.save(
      "synthetic-browser-google-client",
      "synthetic-browser-google-secret"
    )

  # Publish only synthetic encoded fixtures through the real validated route.
  # Archive dates are old; seed a recent failed reservation below to verify
  # manual generation stays available inside the automatic startup cooldown.
  now = DateTime.utc_now()
  actor = %{role: :stage_designer}
  initial = Monolith.StageDesigner.initialize_state!(%{}, actor: actor)

  Enum.reduce(1..23, initial, fn number, state ->
    generated_at = DateTime.add(now, -(24 + (24 - number) * 24) * 3600, :second)

    reserved =
      Monolith.StageDesigner.reserve_state!(state, %{last_attempt_at: generated_at}, actor: actor)

    {:ok, published} =
      Monolith.StageDesigner.Storage.store_and_publish(
        scenery,
        Monolith.UIFixture.scene_image(number),
        reserved,
        generated_at
      )

    published
  end)

  Monolith.StageDesigner.get_state!(1, actor: actor)
  |> Monolith.StageDesigner.reserve_state!(%{last_attempt_at: now}, actor: actor)
  |> Monolith.StageDesigner.fail_state!(%{}, actor: actor)

  workspace = Monolith.Workspaces.create_workspace!("Browser studio", actor: owner)

  shared_workspace = Monolith.Workspaces.create_workspace!("Synthetic space 1", actor: owner)

  for number <- 2..14,
      do: Monolith.Workspaces.create_workspace!("Synthetic space #{number}", actor: owner)

  account =
    Monolith.Mail.save_connection!(
      %{
        id: Ecto.UUID.generate(),
        subject: "synthetic-browser-account",
        email: "browser@example.test",
        generation: Ecto.UUID.generate(),
        calendar_enabled: true
      },
      actor: owner
    )

  Monolith.Mail.update_account!(
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
    Monolith.Mail.attach_account!(%{workspace_id: space.id, account_id: account.id},
      actor: owner
    )
  end

  unattached =
    Monolith.Mail.save_connection!(
      %{
        id: Ecto.UUID.generate(),
        subject: "synthetic-unattached-browser-account",
        email: "unattached@example.test",
        generation: Ecto.UUID.generate()
      },
      actor: owner
    )

  Monolith.Mail.update_account!(
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
    Monolith.Calendar.prepare(account.id, first, last, Date.to_iso8601(day), "UTC", actor: owner)

  {:ok, _} = Monolith.Calendar.poll(account.id, account.generation, revision, actor: owner)

  # Exercise real Connections density with five independent synthetic accounts.
  for number <- 3..5 do
    Monolith.Mail.save_connection!(
      %{
        id:
          if(number == 5, do: "00000000-0000-4000-8000-000000000005", else: Ecto.UUID.generate()),
        subject: "synthetic-extra-browser-account-#{number}",
        email:
          if(number == 4,
            do: "longer.address@example.test",
            else: "secondary-#{number}@example.test"
          ),
        generation: Ecto.UUID.generate()
      },
      actor: owner
    )
  end

  {:ok, _} = Monolith.TestGitHub.start_link()
  Application.put_env(:monolith, :github_provider, Monolith.TestGitHub)
  Application.put_env(:monolith, :github_keychain, Monolith.TestGitHubKeychain)

  Monolith.TestGitHub.configure(
    rows: [Monolith.TestGitHub.row(%{"checks" => "FAILURE"})],
    workflow_runs: [
      Monolith.TestGitHub.workflow_run(%{"conclusion" => "failure"}),
      Monolith.TestGitHub.workflow_run(%{"id" => 10})
    ]
  )

  Monolith.GitHub.save_client_credentials!(
    "Iv1.synthetic",
    "synthetic-browser-github-secret",
    "monolith-synthetic",
    actor: owner
  )

  {:ok, session} = Monolith.Owner.unlock("synthetic browser owner password", "github-ui-fixture")
  {:ok, _} = Monolith.GitHub.Operations.authorize(session, Monolith.TestGitHub.bundle())

  for organization <- Monolith.GitHub.directory!(actor: owner).organizations do
    Monolith.TestGitHub.configure(
      repositories: [
        Monolith.TestGitHub.repository(%{"full_name" => organization.login <> "/repo"}),
        Monolith.TestGitHub.repository(%{
          "id" => "QUIET_SYNTHETIC",
          "name" => "quiet-repository",
          "full_name" => organization.login <> "/quiet-repository"
        }),
        Monolith.TestGitHub.repository(%{
          "id" => "LONG_SYNTHETIC",
          "name" => "repository-with-a-deliberately-long-name-for-content-fit",
          "full_name" =>
            organization.login <> "/repository-with-a-deliberately-long-name-for-content-fit"
        })
      ]
    )

    Monolith.GitHub.attach!(workspace.id, organization.id, actor: owner)
    Monolith.GitHub.poll!(organization.id, organization.generation, actor: owner)

    if organization.login == "acme" do
      Monolith.GitHub.attach_repositories!(
        workspace.id,
        organization.id,
        ["REPO_SYNTHETIC", "LONG_SYNTHETIC"],
        actor: owner
      )
    end
  end

  Monolith.TestGitHub.configure(repositories: nil)

  # Bounded synthetic latency lets Chrome observe the durable discovery claim.
  Monolith.TestGitHub.configure(installation_response: {:delay, 5_000})

  if review == "full" do
    IO.puts("MONOLITH synthetic full review: #{origin}/unlock")
    IO.puts("Disposable root: #{root}")
    IO.puts("Synthetic password: synthetic browser owner password")
    IO.puts("Workspace: #{workspace.id}")
    IO.puts("Google account: #{account.id}; unattached Google account: #{unattached.id}")

    for organization <- Monolith.GitHub.directory!(actor: owner).organizations do
      IO.puts("Synthetic GitHub owner #{organization.login}: #{organization.id}")

      IO.puts(
        "Activity URL: #{origin}#{MonolithWeb.HomeNavigation.github_activity_path(workspace.id, organization.id)}"
      )
    end

    IO.puts("Safe fixture routes: / /workspaces /connections /scenes /settings")
    IO.puts("Only synthetic credentials/providers. Do not follow external OAuth/provider links.")
    IO.puts("Stop this owned process to tear down its server and disposable storage.")

    receive do
      :stop_ui_review -> throw(:ui_review_finished)
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
      env: [{"MONOLITH_STAGE_ENABLED", "false"}]
    )

  if status != 0, do: Mix.raise("Browser UI contract regressions failed")
catch
  :ui_review_finished -> :ok
after
  Application.stop(:monolith)
  Application.stop(:oban)
  Application.stop(:ash_sqlite)
  File.rm_rf!(root)
end
