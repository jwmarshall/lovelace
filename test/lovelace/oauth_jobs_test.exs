defmodule Lovelace.OAuthJobsTest.Google do
  @moduledoc false
  @behaviour Lovelace.Google.OAuthProvider
  defdelegate authorization_url(params), to: Lovelace.TestGoogle
  defdelegate refresh(token), to: Lovelace.TestGoogle
  defdelegate revoke(token), to: Lovelace.TestGoogle

  def exchange_code(code, verifier, uri) do
    Lovelace.TestMail.record(:oauth_exchange)

    case Lovelace.TestMail.result() do
      {:wait_exchange, owner} ->
        send(owner, {:oauth_waiting, self()})

        receive do
          :continue -> Lovelace.TestGoogle.exchange_code(code, verifier, uri)
        end

      _ ->
        Lovelace.TestGoogle.exchange_code(code, verifier, uri)
    end
  end

  def identity(token) do
    case Lovelace.TestMail.result() do
      {:wait_identity, owner} ->
        send(owner, {:identity_waiting, self()})

        receive do
          :continue -> Lovelace.TestGoogle.identity(token)
        end

      _ ->
        Lovelace.TestGoogle.identity(token)
    end
  end
end

defmodule Lovelace.OAuthJobsTest do
  use LovelaceWeb.ConnCase, async: false
  use Oban.Testing, repo: Lovelace.Repo, engine: Oban.Engines.Lite

  alias Ecto.Adapters.SQL
  alias Lovelace.GitHub.Auth
  alias Lovelace.Google.Access
  alias Lovelace.Integrations.Google.ClientCredentials
  alias Lovelace.Mail
  alias Lovelace.Mail.OAuth
  alias Lovelace.OAuth.{Exchange, Worker}
  alias Lovelace.TestSupport.OnboardingKeychain
  @owner %{role: :local_owner}

  defmodule ResultBarrier do
    def await(id, holder, observer) do
      Process.put({__MODULE__, :holder}, holder)
      Process.put({__MODULE__, :observer}, observer)
      Lovelace.OAuth.await(id, __MODULE__)
    end

    def result(id) do
      holder = Process.get({__MODULE__, :holder})
      result = holder.result(id)

      if observer = Process.delete({__MODULE__, :observer}) do
        send(observer, {:result_observed, self(), result})

        receive do
          :continue -> result
        end
      else
        result
      end
    end
  end

  setup %{conn: conn} do
    start_supervised!({Lovelace.TestGitHub, []})
    start_supervised!(OnboardingKeychain)
    {:ok, _} = Lovelace.TestMail.start()

    settings = [
      github_provider: Lovelace.TestGitHub,
      github_keychain: Lovelace.TestGitHubKeychain,
      gmail_provider: Lovelace.OAuthJobsTest.Google,
      gmail_vault: Lovelace.TestMailVault,
      google_client_keychain: OnboardingKeychain
    ]

    previous = Map.new(settings, fn {key, _} -> {key, Application.get_env(:lovelace, key)} end)
    Enum.each(settings, fn {key, value} -> Application.put_env(:lovelace, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:lovelace, key)
        {key, value} -> Application.put_env(:lovelace, key, value)
      end)
    end)

    session = authenticate_owner(conn) |> get_session(:owner_session_token)

    Lovelace.GitHub.save_client_credentials!("Iv1.synthetic", "synthetic_secret", "synthetic-app",
      actor: @owner
    )

    :ok =
      ClientCredentials.save("synthetic-client", "synthetic-secret")

    workspace = Lovelace.Workspaces.create_workspace!("Synthetic OAuth", actor: @owner)
    %{session: session, workspace: workspace}
  end

  for provider <- [:google, :github] do
    @provider provider
    test "#{provider} admitted exchange survives its requesting process and duplicate delivery",
         context do
      {holder, admit, _cancel} = attempt(@provider, context)
      owner = self()

      {request, monitor} =
        spawn_monitor(fn ->
          send(owner, {:admitted, admit.()})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:admitted, {:ok, reference}}
      send(request, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^request, :normal}
      job = Lovelace.Repo.get!(Oban.Job, reference.job_id)
      assert job.args == %{"attempt_id" => reference.id}
      assert {:ok, %{job_id: job_id}} = Exchange.get(reference.id)
      assert job_id == job.id
      assert :ok = Worker.perform(job)
      assert {:ok, _} = holder.result(reference.id)
      assert :ok = Worker.perform(job)
      assert count(@provider) == 1
      assert {:ok, %{status: :completed, outcome: :connected}} = Exchange.get(reference.id)
    end

    test "#{provider} completion between holder and durable reads preserves its settled result",
         context do
      {holder, admit, _cancel} = attempt(@provider, context)
      assert {:ok, reference} = admit.()
      observer = self()
      waiter = Task.async(fn -> ResultBarrier.await(reference.id, holder, observer) end)
      assert_receive {:result_observed, reader, :pending}

      assert :ok = Worker.perform(Lovelace.Repo.get!(Oban.Job, reference.job_id))
      assert {:ok, %{status: :completed, outcome: :connected}} = Exchange.get(reference.id)
      send(reader, :continue)

      assert {:ok, result} = Task.await(waiter)
      assert {:ok, ^result} = holder.result(reference.id)
      assert count(@provider) == 1
    end

    test "#{provider} aborted enqueue leaves no durable admission or consumed authorization",
         context do
      {_holder, rejected_admit, _cancel} = attempt(@provider, context)

      SQL.query!(
        Lovelace.Repo,
        "CREATE TEMP TRIGGER reject_oauth_job BEFORE INSERT ON oban_jobs BEGIN SELECT RAISE(ABORT, 'synthetic private enqueue failure'); END",
        []
      )

      try do
        assert {:error, _} = rejected_admit.()
        assert Ash.read!(Exchange, actor: %{role: :oauth_service}) == []
        assert all_enqueued(worker: Worker) == []
        assert count(@provider) == 0
      after
        SQL.query!(Lovelace.Repo, "DROP TRIGGER reject_oauth_job", [])
      end

      assert {:error, _} = rejected_admit.()
      {_holder, fresh_admit, _cancel} = attempt(@provider, context)
      assert {:ok, reference} = fresh_admit.()
      assert [job] = all_enqueued(worker: Worker)
      assert job.id == reference.job_id
      assert job.args == %{"attempt_id" => reference.id}
      assert :ok = Worker.perform(job)
      assert {:ok, %{status: :completed, outcome: :connected}} = Exchange.get(reference.id)
      assert count(@provider) == 1
      assert :ok = Worker.perform(job)
      assert count(@provider) == 1
    end

    test "#{provider} rescue of an uncertain durable claim never submits again", context do
      {_holder, admit, _cancel} = attempt(@provider, context)
      assert {:ok, reference} = admit.()
      assert {:ok, exchange} = Exchange.get(reference.id)
      assert {:ok, _} = Exchange.record(exchange, %{status: :claimed})
      job = Lovelace.Repo.get!(Oban.Job, reference.job_id)
      assert :ok = Worker.perform(job)
      assert :ok = Worker.perform(job)
      assert count(@provider) == 0
      assert {:ok, %{status: :claimed}} = Exchange.get(reference.id)
    end

    test "#{provider} lost protected secrets fail closed after holder restart", context do
      {holder, admit, _cancel} = attempt(@provider, context)
      assert {:ok, reference} = admit.()
      restart(holder)
      job = Lovelace.Repo.get!(Oban.Job, reference.job_id)
      assert :ok = Worker.perform(job)
      assert :ok = Worker.perform(job)
      assert count(@provider) == 0
      assert {:error, _} = holder.result(reference.id)
      assert {:ok, %{status: :failed, outcome: :reauthorize}} = Exchange.get(reference.id)
    end

    test "#{provider} cancellation fences in-flight provider publication", context do
      {_holder, admit, cancel} = attempt(@provider, context)
      wait(@provider, self())
      assert {:ok, reference} = admit.()
      job = Lovelace.Repo.get!(Oban.Job, reference.job_id)
      task = Task.async(fn -> Worker.perform(job) end)

      worker =
        receive do
          {:oauth_waiting, worker} -> worker
          {:github_waiting, worker} -> worker
        after
          1000 -> flunk("synthetic exchange did not start")
        end

      cancel.()
      send(worker, :continue)
      assert :ok = Task.await(task)
      assert count(@provider) == 1
      assert :ok = Worker.perform(job)
      assert count(@provider) == 1
      assert Lovelace.Mail.list_accounts!(actor: @owner) == []
      assert %{connections: []} = Lovelace.GitHub.directory!(actor: @owner)
      assert {:ok, %{status: :failed, outcome: :reauthorize}} = Exchange.get(reference.id)
    end
  end

  test "admission denies an unauthorized actor without creating a job" do
    id = Ash.UUID.generate()
    assert {:error, _} = Lovelace.OAuth.exchange(id, :google, actor: nil)
    assert {:ok, nil} = Exchange.get(id)
  end

  test "provider failure between holder and durable reads retains its safe failure category",
       context do
    {:ok, state, _} = OAuth.begin(context.workspace.id, context.session)

    assert {:ok, reference} =
             OAuth.admit(state, context.session, %{"code" => "invalid-code", "state" => state})

    observer = self()
    waiter = Task.async(fn -> ResultBarrier.await(reference.id, OAuth, observer) end)
    assert_receive {:result_observed, reader, :pending}

    assert :ok = Worker.perform(Lovelace.Repo.get!(Oban.Job, reference.job_id))
    assert {:ok, %{status: :failed, outcome: :reauthorize}} = Exchange.get(reference.id)
    send(reader, :continue)

    assert {:error, {:token_exchange, :provider_error}, %{capability: :gmail}} =
             Task.await(waiter)

    assert Mail.list_accounts!(actor: @owner) == []
    assert count(:google) == 1
  end

  test "Google client mutation fences an already-running exchange", context do
    {_holder, admit, _cancel} = attempt(:google, context)
    wait(:google, self())
    assert {:ok, reference} = admit.()
    job = Lovelace.Repo.get!(Oban.Job, reference.job_id)
    task = Task.async(fn -> Worker.perform(job) end)
    assert_receive {:oauth_waiting, worker}

    assert {:ok, true} =
             Lovelace.Google.save_client_credentials("replacement-client", "replacement-secret",
               actor: @owner
             )

    send(worker, :continue)
    assert :ok = Task.await(task)
    assert Lovelace.Mail.list_accounts!(actor: @owner) == []
    assert {:ok, %{status: :failed, outcome: :reauthorize}} = Exchange.get(reference.id)
  end

  test "a dead Google client mutation owner cannot leave sign-in permanently blocked", context do
    parent = self()

    {owner, monitor} =
      spawn_monitor(fn ->
        OAuth.client_change(fn ->
          send(parent, :client_mutation_reserved)

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive :client_mutation_reserved
    assert {:error, :busy} = OAuth.begin(context.workspace.id, context.session)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    assert {:ok, _, _} = begin_after_release(context, 50)
  end

  for capability <- [:gmail, :calendar], mutation <- [:disconnect, :replace] do
    test "queued #{capability} exchange rejects connection #{mutation} before provider submission",
         context do
      {account, job, id} = bound_google_attempt(context, unquote(capability))
      mutate_google(unquote(mutation), context, account)
      assert :ok = Worker.perform(job)
      assert count(:google) == 0
      assert {:ok, %{status: :failed, outcome: :reauthorize}} = Exchange.get(id)
    end

    test "blocked #{capability} exchange rechecks after connection #{mutation} releases its lock",
         context do
      {account, job, id} = bound_google_attempt(context, unquote(capability))

      task =
        Access.serial(account.id, fn ->
          task = Task.async(fn -> Worker.perform(job) end)
          assert :claimed = await_claim(id, 100)
          mutate_google(unquote(mutation), context, account)
          task
        end)

      assert :ok = Task.await(task)
      assert count(:google) == 0
      assert {:ok, %{status: :failed, outcome: :reauthorize}} = Exchange.get(id)
    end
  end

  for mutation <- [:disconnect, :replace] do
    test "unbound Gmail identity cannot undo a later #{mutation}", context do
      {:ok, account} = google_account(context)
      {OAuth, admit, _cancel} = attempt(:google, context)
      Lovelace.TestMail.response({:wait_identity, self()})
      assert {:ok, reference} = admit.()
      job = Lovelace.Repo.get!(Oban.Job, reference.job_id)
      task = Task.async(fn -> Worker.perform(job) end)
      assert_receive {:identity_waiting, worker}
      mutate_google(unquote(mutation), context, account)
      current = Mail.get_account!(account.id, actor: @owner)
      send(worker, :continue)
      assert :ok = Task.await(task)
      assert {:ok, %{status: :failed, outcome: :reauthorize}} = Exchange.get(reference.id)
      assert Mail.get_account!(account.id, actor: @owner).generation == current.generation
      assert Mail.get_account!(account.id, actor: @owner).status == current.status
      assert :ok = Worker.perform(job)
      assert count(:google) == 1
    end
  end

  test "unbound Gmail absent-subject snapshot cannot replace a connection created during identity lookup",
       context do
    {OAuth, admit, _cancel} = attempt(:google, context)
    Lovelace.TestMail.response({:wait_identity, self()})
    assert {:ok, reference} = admit.()
    job = Lovelace.Repo.get!(Oban.Job, reference.job_id)
    task = Task.async(fn -> Worker.perform(job) end)
    assert_receive {:identity_waiting, worker}
    {:ok, account} = google_account(context)
    send(worker, :continue)
    assert :ok = Task.await(task)
    assert {:ok, %{status: :failed, outcome: :reauthorize}} = Exchange.get(reference.id)
    assert Mail.get_account!(account.id, actor: @owner).generation == account.generation
    assert :ok = Worker.perform(job)
    assert count(:google) == 1
  end

  test "fresh unbound Gmail consent begun after disconnect may reconnect that generation",
       context do
    {:ok, account} = google_account(context)
    mutate_google(:disconnect, context, account)
    {OAuth, admit, _cancel} = attempt(:google, context)
    assert {:ok, reference} = admit.()
    assert :ok = Worker.perform(Lovelace.Repo.get!(Oban.Job, reference.job_id))
    assert {:ok, %{status: :completed, outcome: :connected}} = Exchange.get(reference.id)
    assert Mail.get_account!(account.id, actor: @owner).status == :ready
    assert count(:google) == 1
  end

  test "a changed callback destination invalidates queued consent before sending its code",
       context do
    {_holder, admit, _cancel} = attempt(:google, context)
    assert {:ok, reference} = admit.()
    previous = Application.fetch_env(:lovelace, :gmail)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:lovelace, :gmail, value)
        :error -> Application.delete_env(:lovelace, :gmail)
      end
    end)

    settings = Application.get_env(:lovelace, :gmail, [])

    Application.put_env(
      :lovelace,
      :gmail,
      Keyword.put(settings, :redirect_uri, "http://localhost:4000/changed-synthetic-callback")
    )

    job = Lovelace.Repo.get!(Oban.Job, reference.job_id)
    assert :ok = Worker.perform(job)
    assert {:ok, %{status: :failed, outcome: :reauthorize}} = Exchange.get(reference.id)
    assert count(:google) == 0
    assert Mail.list_accounts!(actor: @owner) == []
    assert :ok = Worker.perform(job)
    assert count(:google) == 0
  end

  test "overlapping Google credential changes cannot enter or release another mutation",
       context do
    assert :finished =
             OAuth.client_change(fn ->
               assert {:error, :unavailable} =
                        OAuth.client_change(fn -> flunk("overlapping mutation was entered") end)

               assert {:error, :busy} = OAuth.begin(context.workspace.id, context.session)
               :finished
             end)

    assert {:ok, state, _verifier} = OAuth.begin(context.workspace.id, context.session)
    assert {:ok, _} = OAuth.cancel(state, context.session)
  end

  test "OTP diagnostics hide queued authorization secrets without consuming consent", context do
    {:ok, state, verifier} = OAuth.begin(context.workspace.id, context.session)
    code = "fake-code"

    assert {:ok, reference} =
             OAuth.admit(state, context.session, %{"code" => code, "state" => state})

    diagnostics = inspect(:sys.get_status(OAuth), limit: :infinity)
    for secret <- [code, verifier, context.session], do: refute(diagnostics =~ secret)
    assert :pending = OAuth.result(reference.id)
    assert :ok = Worker.perform(Lovelace.Repo.get!(Oban.Job, reference.job_id))
    assert {:ok, %{status: :completed, outcome: :connected}} = Exchange.get(reference.id)
    assert count(:google) == 1

    assert {:error, :invalid_state} = OAuth.cancel(state, context.session)
    assert [%{status: :ready}] = Mail.list_accounts!(actor: @owner)
  end

  defp google_account(context) do
    Access.accept(
      context.workspace.id,
      %{subject: "new-subject", email: "new@example.invalid"},
      "prior-refresh",
      :calendar
    )
  end

  defp bound_google_attempt(context, capability) do
    {:ok, account} =
      Access.accept(
        context.workspace.id,
        %{subject: "new-subject", email: "new@example.invalid"},
        "prior-refresh",
        :calendar
      )

    {:ok, state, _} =
      OAuth.begin(
        context.workspace.id,
        context.session,
        account.id,
        capability,
        account.generation
      )

    {:ok, reference} =
      OAuth.admit(state, context.session, %{"state" => state, "code" => "fake-code"})

    {account, Lovelace.Repo.get!(Oban.Job, reference.job_id), reference.id}
  end

  defp mutate_google(:disconnect, _context, account) do
    assert {:ok, _} = Mail.disconnect(account.id, actor: @owner)
  end

  defp mutate_google(:replace, context, account) do
    assert {:ok, _} =
             Access.accept(
               context.workspace.id,
               %{subject: account.subject, email: account.email},
               "replacement-refresh"
             )
  end

  defp await_claim(id, remaining) do
    case Exchange.get(id) do
      {:ok, %{status: :queued}} when remaining > 0 ->
        Process.sleep(5)
        await_claim(id, remaining - 1)

      {:ok, %{status: status}} ->
        status

      other ->
        other
    end
  end

  defp begin_after_release(context, remaining) do
    case OAuth.begin(context.workspace.id, context.session) do
      {:error, :busy} when remaining > 0 ->
        Process.sleep(5)
        begin_after_release(context, remaining - 1)

      result ->
        result
    end
  end

  defp attempt(:google, context) do
    {:ok, state, _} = OAuth.begin(context.workspace.id, context.session)

    {OAuth,
     fn -> OAuth.admit(state, context.session, %{"code" => "fake-code", "state" => state}) end,
     fn -> assert {:ok, _} = OAuth.cancel(state, context.session) end}
  end

  defp attempt(:github, context) do
    {:ok, url} = Auth.begin(context.session)
    state = URI.decode_query(URI.parse(url).query)["state"]

    {Auth, fn -> Auth.admit(context.session, %{"code" => "synthetic_code", "state" => state}) end,
     fn -> assert :ok = Auth.cancel(context.session) end}
  end

  defp count(:google), do: Enum.count(Lovelace.TestMail.calls(), &(&1 == :oauth_exchange))

  defp count(:github),
    do:
      Enum.count(Lovelace.TestGitHub.state().calls, &match?({:exchange_code, _, _, _, _, _}, &1))

  defp wait(:google, owner), do: Lovelace.TestMail.response({:wait_exchange, owner})

  defp wait(:github, owner),
    do:
      Lovelace.TestGitHub.configure(
        exchange_response: {:wait, owner, {:ok, Lovelace.TestGitHub.bundle()}}
      )

  defp restart(holder) do
    supervisor =
      if Process.whereis(Lovelace.Security.ProtectedSupervisor),
        do: Lovelace.Security.ProtectedSupervisor,
        else: Lovelace.Supervisor

    :ok = Supervisor.terminate_child(supervisor, holder)
    {:ok, _} = Supervisor.restart_child(supervisor, holder)
  end
end
