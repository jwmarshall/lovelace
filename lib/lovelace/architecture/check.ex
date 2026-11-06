defmodule Lovelace.Architecture.Check do
  @moduledoc """
  Deterministic, non-evaluating architecture rules over parsed Elixir syntax.

  Static calls, captures, imports, aliases, delegates, pipelines and literal MFA
  child specs are indexed. UI reachability is function-level, not a module-cycle
  heuristic: a helper's unrelated provider function cannot taint its projection.
  Ash's generated action APIs are intentional admission boundaries, not expanded.

  This is not whole-program analysis. Runtime-selected modules, arbitrary apply,
  generated macro bodies, quoted code and callbacks cannot be proven transitively.
  Review and runtime tests remain necessary for those paths and for authorization,
  secret safety, durable admission and one-shot execution semantics.

  A selected provider module is not itself I/O; dynamic `provider().request(...)`
  dispatch is outside the static call graph. Private persistence checks recognize
  inline resources in Ash query/changeset/read/write syntax, not resources flowing
  through variables. Lock checks inspect module identities in the lock argument,
  not unrelated calls inside its protected callback; computed identities require
  review. Legitimate Ash resource/type references and infrastructure Repo use remain allowed.
  """

  alias Lovelace.Architecture.Source

  # Exact infrastructure references, not an exemption for either namespace.
  @composition [
    {"Elixir.Lovelace.Application", "Elixir.LovelaceWeb.Endpoint"},
    {"Elixir.Lovelace.Application", "Elixir.LovelaceWeb.Telemetry"},
    {"Elixir.Lovelace.Security.Bootstrap", "Elixir.LovelaceWeb.Endpoint"}
  ]
  @private_resources [
    "Elixir.Lovelace.Calendar.State",
    "Elixir.Lovelace.YouTube.State",
    "Elixir.Lovelace.Mail.CacheEntry",
    "Elixir.Lovelace.Mail.ReadRequest",
    "Elixir.Lovelace.Mail.Disconnection",
    "Elixir.Lovelace.OAuth.Exchange",
    "Elixir.Lovelace.ConnectionDiagnostics.State",
    "Elixir.Lovelace.GitHub.Connection",
    "Elixir.Lovelace.StageDesigner.State",
    "Elixir.Lovelace.StageDesigner.Attempt"
  ]
  # These adapters perform local credential storage only. Their static function
  # bodies are still followed: introducing HTTP there does not waive the rule.
  @local_credentials [
    "Elixir.Lovelace.Integrations.Google.ClientCredentials",
    "Elixir.Lovelace.Integrations.Google.Keychain",
    "Elixir.Lovelace.Integrations.Gemini.Credentials",
    "Elixir.Lovelace.Integrations.Gemini.Keychain",
    "Elixir.Lovelace.Integrations.GitHub.Keychain"
  ]

  def check(sources) do
    index = Source.parse!(sources)

    (reference_violations(index) ++ call_violations(index) ++ ui_violations(index))
    |> Enum.uniq_by(&{&1.rule, &1.file, &1.line, &1.message})
    |> Enum.sort_by(&{&1.file, &1.line, &1.rule, &1.message})
  end

  # CLI tooling reads a fixed local source glob under a developer-controlled root.
  # This is not a runtime input or a symlink-confinement boundary.
  # sobelow_skip ["Traversal.FileModule"]
  def sources(root \\ ".") do
    root
    |> Path.join("lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&{Path.relative_to(&1, root), File.read!(&1)})
  end

  def format(violation) do
    "#{violation.file}:#{violation.line}: [#{violation.rule}] #{violation.message}"
  end

  defp reference_violations(index) do
    Enum.flat_map(index.references, fn ref ->
      from = module_name(ref.module)
      target = module_name(ref.target)

      cond do
        forbidden_core_web?(from, target) ->
          [violation(ref, :core_to_web, "#{from} depends on web module #{target}")]

        forbidden_adapter_orchestration?(from, target) ->
          [
            violation(
              ref,
              :adapter_to_orchestration,
              "adapter #{from} depends on orchestration #{target}"
            )
          ]

        foreign_private_persistence?(ref, from, target) ->
          [
            violation(
              ref,
              :private_domain_persistence,
              "#{from} accesses private persistence #{target} outside its owning domain"
            )
          ]

        true ->
          []
      end
    end)
  end

  defp forbidden_core_web?(from, target),
    do: core?(from) and web?(target) and {from, target} not in @composition

  defp forbidden_adapter_orchestration?(from, target),
    do: adapter?(from) and orchestration?(target)

  defp foreign_private_persistence?(ref, from, target),
    do: ref.persistence and target in @private_resources and foreign_domain?(from, target)

  defp call_violations(index) do
    Enum.flat_map(index.calls, fn call ->
      from = module_name(call.module)
      target = module_name(call.target)

      cond do
        private_capability?(target) and foreign_domain?(from, target) ->
          [
            violation(
              call,
              :private_domain_capability,
              "#{from} calls private capability #{target}.#{call.name}/#{call.arity}"
            )
          ]

        call.target in [:global] and call.name in [:trans, :set_lock, :del_lock] ->
          private_lock_violations(call)

        true ->
          []
      end
    end)
  end

  defp private_lock_violations(call) do
    call
    |> Map.get(:lock_targets, [])
    |> Enum.filter(&(orchestration?(module_name(&1)) and &1 != call.module))
    |> Enum.map(fn target ->
      violation(
        call,
        :private_lock_identity,
        "#{module_name(call.module)} uses another module's private lock identity #{module_name(target)}"
      )
    end)
  end

  defp ui_violations(index) do
    calls = Enum.group_by(index.calls, & &1.function)

    index.definitions
    |> Enum.filter(fn {module, _, _} -> web?(module_name(module)) end)
    |> Enum.sort()
    |> Enum.flat_map(fn entry ->
      case provider_path(entry, calls, index.definitions, MapSet.new()) do
        nil ->
          []

        {site, path} ->
          [
            violation(
              site,
              :ui_provider_work,
              "UI provider path: " <> Enum.map_join(path, " -> ", &format_mfa/1)
            )
          ]
      end
    end)
  end

  defp provider_path(entry, calls, definitions, visited) do
    if MapSet.member?(visited, entry) do
      nil
    else
      find_provider_path(entry, calls, definitions, MapSet.put(visited, entry))
    end
  end

  defp find_provider_path(entry, calls, definitions, visited) do
    calls
    |> Map.get(entry, [])
    |> Enum.sort_by(&{&1.line, &1.target, &1.name, &1.arity})
    |> Enum.find_value(&provider_edge_path(&1, entry, calls, definitions, visited))
  end

  defp provider_edge_path(edge, entry, calls, definitions, visited) do
    next = {edge.target, edge.name, edge.arity}

    cond do
      provider?(module_name(edge.target)) ->
        {edge, [entry, next]}

      MapSet.member?(definitions, next) ->
        next
        |> provider_path(calls, definitions, visited)
        |> prepend_provider_path(edge, entry)

      true ->
        nil
    end
  end

  defp prepend_provider_path(nil, _edge, _entry), do: nil
  defp prepend_provider_path({_site, path}, edge, entry), do: {edge, [entry | path]}

  defp private_capability?(name) do
    String.ends_with?(name, [".Operations", ".Connections", ".Coordination"])
  end

  defp orchestration?(name) do
    core?(name) and not adapter?(name) and
      (name in [
         "Elixir.Lovelace.Mail",
         "Elixir.Lovelace.Calendar",
         "Elixir.Lovelace.YouTube",
         "Elixir.Lovelace.GitHub",
         "Elixir.Lovelace.StageDesigner",
         "Elixir.Lovelace.Google",
         "Elixir.Lovelace.Onboarding",
         "Elixir.Lovelace.Workspaces",
         "Elixir.Lovelace.Owner"
       ] or
         String.ends_with?(name, [
           ".Auth",
           ".Operations",
           ".Generation",
           ".Polling",
           ".Credentials",
           ".Store",
           ".Access",
           ".Disconnects",
           ".Reads",
           ".Startup",
           ".CredentialOperations",
           ".Coordination"
         ]))
  end

  defp provider?(name) do
    (adapter?(name) and name not in @local_credentials) or
      name in [
        "Elixir.Req",
        "Elixir.Finch",
        "Elixir.Mint.HTTP",
        "Elixir.Mint.HTTP1",
        "Elixir.Mint.HTTP2",
        "httpc",
        "hackney"
      ]
  end

  defp foreign_domain?(from, target) do
    left = domain(from)
    right = domain(target)
    not is_nil(left) and not is_nil(right) and left != right
  end

  defp domain(name) do
    case String.split(name, ".") do
      ["Elixir", "Lovelace", domain | _] -> domain
      ["Elixir", "LovelaceWeb" | _] -> :web
      _ -> nil
    end
  end

  defp core?(name), do: String.starts_with?(name, "Elixir.Lovelace.") or name == "Elixir.Lovelace"

  defp web?(name),
    do: String.starts_with?(name, "Elixir.LovelaceWeb.") or name == "Elixir.LovelaceWeb"

  defp adapter?(name), do: String.starts_with?(name, "Elixir.Lovelace.Integrations.")
  defp module_name(nil), do: ""
  defp module_name(module), do: Atom.to_string(module)
  defp format_mfa({module, name, arity}), do: "#{inspect(module)}.#{name}/#{arity}"

  defp violation(site, rule, message),
    do: Map.take(site, [:file, :line]) |> Map.merge(%{rule: rule, message: message})
end
