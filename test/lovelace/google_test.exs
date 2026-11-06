defmodule Lovelace.GoogleTest do
  use Lovelace.DataCase, async: false

  import ExUnit.CaptureLog

  alias Lovelace.ConnectionDiagnostics.State
  alias Lovelace.Google
  alias Lovelace.Integrations.Google.ClientCredentials

  @owner [actor: %{role: :local_owner}]
  @id "synthetic-shared-google-client"
  @secret "synthetic-shared-google-secret"
  @account "710dd510-61ed-4e6a-975c-78ce13f5d6e2"
  @service "LOVELACE Google OAuth"

  defmodule Keychain do
    def get(account, service) do
      send(self(), {:keychain_read, account, service})
      respond(:get, {:error, :not_found})
    end

    def put(account, value, service) do
      send(self(), {:keychain_write, account, value, service})
      respond(:put, :ok)
    end

    defp respond(operation, default) do
      case Process.get({__MODULE__, operation}, default) do
        :raise -> raise "synthetic-shared-google-secret"
        :throw -> throw("synthetic-shared-google-secret")
        :exit -> exit("synthetic-shared-google-secret")
        result -> result
      end
    end
  end

  setup do
    previous = Application.fetch_env(:lovelace, :google_client_keychain)
    Application.put_env(:lovelace, :google_client_keychain, Keychain)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:lovelace, :google_client_keychain, value)
        :error -> Application.delete_env(:lovelace, :google_client_keychain)
      end
    end)
  end

  test "status distinguishes absent, invalid, stored, locked and unavailable without values" do
    valid = Jason.encode!(%{client_id: @id, client_secret: @secret})

    for {response, expected} <- [
          {{:error, :not_found}, :not_connected},
          {{:ok, valid}, :stored},
          {{:ok, "not json"}, :invalid},
          {{:ok, "{}"}, :invalid},
          {{:ok, Jason.encode!(%{client_id: @id, client_secret: "has space"})}, :invalid},
          {{:ok, String.duplicate("x", 16_385)}, :invalid},
          {{:ok, nil}, :invalid},
          {{:ok, <<255>>}, :invalid},
          {{:error, :locked}, :locked},
          {{:error, @secret}, :unavailable},
          {nil, :unavailable}
        ] do
      Process.put({Keychain, :get}, response)
      assert ClientCredentials.status() == expected
      assert {:ok, ^expected} = Google.client_status(@owner)
    end

    Process.put({Keychain, :get}, {:error, :not_found})
    assert {:error, :invalid_configuration} = ClientCredentials.read()
    Process.put({Keychain, :get}, {:ok, valid})
    assert {:ok, %{client_id: @id, client_secret: @secret}} = ClientCredentials.read()
  end

  test "first credential save initializes an absent diagnostic slot without changing its namespace" do
    assert {:ok, nil} =
             Ash.get(State, :google,
               actor: %{role: :connection_diagnostics},
               not_found_error?: false
             )

    assert {:ok, true} = Google.save_client_credentials(@id, @secret, @owner)
    assert_received {:keychain_write, @account, json, @service}
    assert Jason.decode!(json) == %{"client_id" => @id, "client_secret" => @secret}
    assert_received {:keychain_read, @account, @service}

    assert Ash.get!(State, :google, actor: %{role: :connection_diagnostics}).status ==
             :unavailable
  end

  test "client replacement fences every account across ordered bounded pages" do
    accounts =
      for index <- 1..101 do
        suffix = index |> Integer.to_string() |> String.pad_leading(12, "0")

        Lovelace.Mail.save_connection!(
          %{
            id: "00000000-0000-4000-8000-" <> suffix,
            subject: "bounded-client-subject-#{index}",
            email: "bounded-#{102 - index}@example.invalid",
            generation: Ash.UUID.generate(),
            calendar_enabled: true,
            youtube_enabled: true
          },
          @owner
        )
      end

    [first | active] = accounts

    disconnected =
      Lovelace.Mail.update_account!(
        first,
        %{
          expected_generation: first.generation,
          status: :disconnected,
          calendar_enabled: false,
          youtube_enabled: false
        },
        @owner
      )

    assert {:ok, true} = Google.save_client_credentials(@id, @secret, @owner)

    for account <- active do
      current = Lovelace.Mail.get_account!(account.id, @owner)
      assert current.generation != account.generation
      assert current.status == :reconnect
      refute current.calendar_enabled
      refute current.youtube_enabled
    end

    current = Lovelace.Mail.get_account!(disconnected.id, @owner)
    assert current.generation == disconnected.generation
    assert current.status == :disconnected
  end

  test "only the local owner can inspect status or save credentials" do
    for actor <- [
          nil,
          %{},
          %{role: "local_owner"},
          %{role: :mail_service},
          %{role: :owner_auth_service},
          %{role: :stage_designer}
        ] do
      assert {:error, %Ash.Error.Forbidden{}} = Google.client_status(actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} =
               Google.save_client_credentials(@id, @secret, actor: actor)
    end

    refute_received {:keychain_read, _, _}
    refute_received {:keychain_write, _, _, _}
  end

  test "malformed or oversized pairs never reach storage or expose values" do
    log =
      capture_log(fn ->
        for value <- [
              "",
              " " <> @secret,
              @secret <> "\n",
              @secret <> <<255>>,
              String.duplicate(@secret, 400),
              String.duplicate("é", 4097)
            ] do
          for {id, secret} <- [{value, @secret}, {@id, value}] do
            assert {:error, error} = Google.save_client_credentials(id, secret, @owner)
            refute inspect(error) =~ @id
            refute inspect(error) =~ @secret
            refute Exception.message(error) =~ @secret
          end
        end
      end)

    refute log =~ @secret
    refute_received {:keychain_write, _, _, _}
  end

  test "native errors and exceptions expose no credential or diagnostic" do
    log =
      capture_log(fn ->
        for response <- [:raise, :throw, :exit, {:error, @secret}, {:error, :locked}, :unexpected] do
          Process.put({Keychain, :get}, response)
          Process.put({Keychain, :put}, response)
          assert {:ok, status} = Google.client_status(@owner)
          assert status in [:locked, :unavailable]
          assert {:error, error} = Google.save_client_credentials(@id, @secret, @owner)
          refute inspect(error) =~ @secret
          refute Exception.message(error) =~ @secret
        end
      end)

    refute log =~ @secret
  end
end
