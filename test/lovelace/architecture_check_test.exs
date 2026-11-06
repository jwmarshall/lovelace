defmodule Lovelace.ArchitectureCheckTest do
  use ExUnit.Case, async: true

  alias Lovelace.Architecture.{Check, Source}
  alias Lovelace.Example
  alias Lovelace.Example.Group.Leaf
  alias Lovelace.Example.{Inner, Sibling}
  alias Lovelace.Explicit

  test "core/web references resolve renamed aliases and reject configuration discovery" do
    violations =
      check("""
      defmodule Lovelace.GitHub.Auth do
        alias LovelaceWeb.Endpoint, as: Browser
        def callback, do: Application.get_env(:lovelace, Browser)
      end
      """)

    assert_rule(violations, :core_to_web)
    assert Enum.all?(violations, &(&1.file == "fixture.ex" and is_integer(&1.line)))
  end

  test "nested application modules retain their core namespace" do
    violations =
      check("""
      defmodule Lovelace.Example do
        defmodule Inner do
          def callback, do: LovelaceWeb.Endpoint.url()
        end
      end
      """)

    assert_rule(violations, :core_to_web)
    assert Enum.any?(violations, &String.contains?(&1.message, "Lovelace.Example.Inner"))
  end

  test "nested integration modules retain their adapter namespace" do
    violations =
      check("""
      defmodule Lovelace.Integrations.Example do
        defmodule Transport do
          def fetch, do: Lovelace.GitHub.Operations.poll("id")
        end
      end
      """)

    assert_rule(violations, :adapter_to_orchestration)

    assert Enum.any?(
             violations,
             &String.contains?(&1.message, "Lovelace.Integrations.Example.Transport")
           )
  end

  test "nested declarations install sibling aliases without reusing an existing name alias" do
    source = """
    defmodule Lovelace.Example do
      alias Lovelace.SharedHelper, as: Inner
      defmodule Inner do
        def value, do: :ok
      end
      defmodule Group.Leaf do
        def value, do: :ok
      end
      defmodule Sibling do
        def value, do: {Inner.value(), Group.Leaf.value()}
      end
      def value, do: Sibling.value()
      defmodule Elixir.Lovelace.Explicit do
        def value, do: :ok
      end
    end
    """

    assert [] == check(source)
    index = Source.parse!([{"nested.ex", source}])

    for module <- [Inner, Leaf, Sibling, Explicit] do
      assert MapSet.member?(index.definitions, {module, :value, 0})
    end

    for target <- [Inner, Leaf] do
      assert Enum.any?(index.calls, fn call ->
               call.function == {Sibling, :value, 0} and call.target == target
             end)
    end

    assert Enum.any?(index.calls, fn call ->
             call.function == {Example, :value, 0} and call.target == Sibling
           end)
  end

  test "composition exceptions are exact edges, not namespace exemptions" do
    assert [] ==
             check("""
             defmodule Lovelace.Application do
               def children, do: [LovelaceWeb.Endpoint, LovelaceWeb.Telemetry]
             end
             defmodule Lovelace.Security.Bootstrap do
               def port, do: Application.fetch_env!(:lovelace, LovelaceWeb.Endpoint)
             end
             """)

    assert_rule(
      check("""
      defmodule Lovelace.Application do
        def forbidden, do: LovelaceWeb.HomeLive.mount(nil, nil, nil)
      end
      defmodule Lovelace.Security.Other do
        def forbidden, do: LovelaceWeb.Endpoint.config(:url)
      end
      """),
      :core_to_web
    )
  end

  test "adapters cannot discover configuration through orchestration aliases" do
    assert_rule(
      check("""
      defmodule Lovelace.Integrations.GitHub.Transport do
        alias Lovelace.GitHub.{Auth, Operations}
        def callback, do: Auth.callback_uri()
        def snapshot, do: Operations.poll("id")
      end
      """),
      :adapter_to_orchestration
    )
  end

  test "UI cannot escape into provider work through a helper and local function" do
    violations =
      check("""
      defmodule LovelaceWeb.ProviderHelper do
        def fetch(id), do: perform(id)
        defp perform(id), do: Lovelace.Integrations.Google.thread(id)
      end
      defmodule LovelaceWeb.ExampleLive do
        alias LovelaceWeb.ProviderHelper, as: Helper
        def handle_event(id), do: Helper.fetch(id)
      end
      """)

    assert_rule(violations, :ui_provider_work)

    assert Enum.any?(
             violations,
             &String.contains?(
               &1.message,
               "ExampleLive.handle_event/1 -> LovelaceWeb.ProviderHelper.fetch/1"
             )
           )
  end

  test "UI reachability follows imports, pipelines, captures, defaults, delegates and static apply" do
    violations =
      check(~S'''
      defmodule Lovelace.ProviderHelper do
        def fetch(id, opts \\ []), do: Lovelace.Integrations.GitHub.snapshot(id, opts)
      end
      defmodule LovelaceWeb.ExampleLive do
        import Lovelace.ProviderHelper, only: [fetch: 1]
        def piped(id), do: id |> fetch()
        def captured, do: &Lovelace.ProviderHelper.fetch/1
        def applied(id), do: apply(Lovelace.ProviderHelper, :fetch, [id])
        def remote_applied(id), do: Kernel.apply(Lovelace.ProviderHelper, :fetch, [id])
        defdelegate delegated(id), to: Lovelace.ProviderHelper, as: :fetch
      end
      ''')

    for function <- ["piped/1", "captured/0", "applied/1", "remote_applied/1", "delegated/1"] do
      assert Enum.any?(
               violations,
               &(&1.rule == :ui_provider_work and String.contains?(&1.message, function))
             )
    end
  end

  test "guarded helpers cannot hide provider work behind local captures and nested modules" do
    violations =
      check("""
      defmodule Lovelace.ReadHelper do
        alias Lovelace.Integrations.Google, as: Provider
        defmodule Transport do
          def fetch(id) when is_binary(id), do: Provider.thread(id)
        end
        def fetch(ids) when is_list(ids), do: Enum.map(ids, &read/1)
        defp read(id), do: __MODULE__.Transport.fetch(id)
      end
      defmodule LovelaceWeb.ExampleLive do
        alias Lovelace.ReadHelper, as: Helper
        def load(ids), do: Helper.fetch(ids)
      end
      """)

    assert Enum.any?(violations, fn violation ->
             violation.rule == :ui_provider_work and
               violation.message ==
                 "UI provider path: LovelaceWeb.ExampleLive.load/1 -> " <>
                   "Lovelace.ReadHelper.fetch/1 -> Lovelace.ReadHelper.read/1 -> " <>
                   "Lovelace.ReadHelper.Transport.fetch/1 -> " <>
                   "Lovelace.Integrations.Google.thread/1"
           end)
  end

  test "literal module atoms cannot hide orchestration configuration from an adapter" do
    violations =
      check("""
      defmodule Lovelace.Integrations.GitHub.Transport do
        def configuration do
          Application.fetch_env!(:lovelace, :"Elixir.Lovelace.GitHub.Auth")
        end
      end
      """)

    assert Enum.any?(violations, fn violation ->
             violation.rule == :adapter_to_orchestration and
               violation.message ==
                 "adapter Elixir.Lovelace.Integrations.GitHub.Transport depends on " <>
                   "orchestration Elixir.Lovelace.GitHub.Auth"
           end)
  end

  test "non-Kernel apply follows its own implementation rather than executing its MFA arguments" do
    violations =
      check("""
      defmodule Lovelace.CallSpec do
        def apply(module, function, args), do: %{module: module, function: function, args: args}
        def project(id), do: %{id: id}
      end
      defmodule Lovelace.ReadHelper do
        def fetch(id), do: Lovelace.Integrations.Google.thread(id)
        def apply(_resource, _field, [id]), do: __MODULE__.fetch(id)
      end
      defmodule LovelaceWeb.ExampleLive do
        alias Lovelace.CallSpec, as: Spec
        alias Lovelace.ReadHelper, as: Helper
        def describe(id), do: Spec.apply(Helper, :fetch, [id])
        def load(id), do: Helper.apply(Spec, :project, [id])
      end
      """)

    assert [violation] = violations
    assert violation.rule == :ui_provider_work

    assert violation.message ==
             "UI provider path: LovelaceWeb.ExampleLive.load/1 -> " <>
               "Lovelace.ReadHelper.apply/3 -> Lovelace.ReadHelper.fetch/1 -> " <>
               "Lovelace.Integrations.Google.thread/1"
  end

  test "a pure helper projection is not tainted by an unrelated provider function" do
    assert [] ==
             check("""
             defmodule Lovelace.SharedHelper do
               def project(value), do: %{count: length(value)}
               def provider(id), do: Lovelace.Integrations.Google.thread(id)
             end
             defmodule LovelaceWeb.ExampleLive do
               def render(values), do: Lovelace.SharedHelper.project(values)
             end
             """)
  end

  test "an application helper is not a transitive provider escape" do
    assert_rule(
      check("""
      defmodule Lovelace.ReadHelper do
        def load(id), do: Lovelace.Integrations.Google.thread(id)
      end
      defmodule LovelaceWeb.ExampleLive do
        def load(id), do: Lovelace.ReadHelper.load(id)
      end
      """),
      :ui_provider_work
    )
  end

  test "Ash domains, resources, contracts and local credential status are allowed" do
    assert [] ==
             check("""
             defmodule Lovelace.Mail do
               use Ash.Domain
               resources do
                 resource Lovelace.Mail.Account
               end
             end
             defmodule Lovelace.Mail.Provider do
               @callback page(binary()) :: {:ok, map()}
             end
             defmodule Lovelace.Integrations.Google do
               @behaviour Lovelace.Mail.Provider
               def page(id), do: {:ok, %{id: id}}
             end
             defmodule Lovelace.Calendar.Projection do
               alias Lovelace.Mail.Account
               def account_type, do: Account
             end
             defmodule LovelaceWeb.ExampleLive do
               def load, do: Lovelace.Mail.accounts(actor: %{role: :local_owner})
               def local_status, do: Lovelace.Integrations.Google.ClientCredentials.status()
             end
             """)
  end

  test "cross-domain persistence is rejected without banning resource references" do
    assert_rule(
      check("""
      defmodule Lovelace.Onboarding.CalendarSetup do
        alias Lovelace.Calendar.State, as: CalendarState
        def load, do: CalendarState |> Ash.Query.for_read(:read) |> Ash.read!()
      end
      """),
      :private_domain_persistence
    )

    assert [] ==
             check("""
             defmodule Lovelace.Calendar.Operations do
               def load, do: Lovelace.Calendar.State |> Ash.Query.for_read(:read) |> Ash.read!()
             end
             defmodule Lovelace.Google.Access do
               def account, do: Ash.get(Lovelace.Mail.Account, "synthetic-id")
               def transact(fun), do: Ash.transact([Lovelace.Mail.Account, Lovelace.Mail.WorkspaceAccount], fun)
             end
             """)
  end

  test "foreign private capabilities and borrowed lock identities are rejected" do
    assert_rule(
      check("""
      defmodule Lovelace.Calendar.Operations do
        def token(id), do: Lovelace.Mail.Operations.access_token(id)
      end
      """),
      :private_domain_capability
    )

    assert_rule(
      check("""
      defmodule Lovelace.GitHub.ClientCredentials do
        alias Lovelace.GitHub.Operations
        def change(fun), do: :global.trans({{Operations, :state}, self()}, fun)
      end
      """),
      :private_lock_identity
    )
  end

  test "the coordination owner may call orchestration inside its own lock" do
    assert [] ==
             check("""
             defmodule Lovelace.GitHub.Coordination do
               def change do
                 :global.trans({{__MODULE__, :state}, self()}, fn ->
                   Lovelace.GitHub.Operations.commit()
                 end)
               end
             end
             """)
  end

  test "web callers cannot bypass private persistence or private domain capabilities" do
    violations =
      check("""
      defmodule LovelaceWeb.ExampleLive do
        def private_state, do: Ash.read!(Lovelace.Calendar.State)
        def private_call, do: Lovelace.Mail.Operations.account_page("id")
      end
      """)

    assert_rule(violations, :private_domain_persistence)
    assert_rule(violations, :private_domain_capability)
  end

  test "YouTube caches stay private and adapters cannot call its use cases" do
    violations =
      check("""
      defmodule LovelaceWeb.VideoLive do
        def load, do: Ash.read!(Lovelace.YouTube.State)
      end
      defmodule Lovelace.Integrations.Google.YouTube do
        def refresh(id), do: Lovelace.YouTube.refresh(id)
      end
      """)

    assert_rule(violations, :private_domain_persistence)
    assert_rule(violations, :adapter_to_orchestration)
  end

  test "comments and string contents cannot fabricate dependency findings" do
    assert [] ==
             check(~S'''
             defmodule Lovelace.Example do
               # LovelaceWeb.Endpoint.config(:url)
               def example, do: "LovelaceWeb.Endpoint and Task.async are documentation"
             end
             ''')
  end

  test "syntax errors fail closed and results have deterministic order" do
    assert_raise TokenMissingError, fn -> check("defmodule Lovelace.Bad do") end

    left =
      {"b.ex", "defmodule Lovelace.B do\n def bad, do: LovelaceWeb.Endpoint.config(:url)\nend"}

    right =
      {"a.ex", "defmodule Lovelace.A do\n def bad, do: LovelaceWeb.Endpoint.config(:url)\nend"}

    assert Check.check([left, right]) == Check.check([right, left])
  end

  test "the async inventory indexes aliases, supervision MFAs, timers and worker entries" do
    index =
      Source.parse!([
        {"inventory.ex",
         """
         defmodule Lovelace.Inventory do
           use Oban.Worker, queue: :synthetic
           alias Task, as: Bounded
           def run, do: Bounded.async(fn -> :ok end)
           def child, do: {Task, :start_link, [fn -> :ok end]}
           def timer, do: Process.send_after(self(), :expire, 100)
           def ui(socket), do: Phoenix.LiveView.start_async(socket, :read, fn -> :ok end)
           def perform(_job), do: :ok
         end
         """}
      ])

    for name <- [:async, :start_link, :send_after, :start_async, :perform] do
      assert Enum.any?(index.async, &(&1.name == name and &1.file == "inventory.ex"))
    end
  end

  defp check(source), do: Check.check([{"fixture.ex", source}])

  defp assert_rule(violations, rule) do
    assert Enum.any?(violations, &(&1.rule == rule)), inspect(violations)
  end
end
