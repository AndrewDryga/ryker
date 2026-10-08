defmodule Ryker.CopiedHelpersTest do
  # Emisar's rule: a pure helper used in more than one place is its own small
  # module with unit tests, not a function copied between call sites. The scan
  # behind this test found 37 copied helpers on 2026-10-08, and beside them a
  # family of near-copies: eleven ways to word "3 messages", nineteen backoff
  # formulas, twenty-two Slack id patterns, six Slack links built by hand. Two
  # copies had already drifted into bugs: a task's title and an open goal's
  # outcome were measured in bytes where everything else counted characters,
  # and the model's final-answer preflight demanded a visible reply on turns
  # the executor would let finish silently.
  #
  # A clause counts as copied when its head and body match another module's
  # once variable names are set aside and aliases are resolved (two modules'
  # `Example` are different schemas), and it is big enough to be logic rather
  # than one call.
  use ExUnit.Case, async: true

  # Shapes a layer requires, which look alike because they must: OTP and Plug
  # callbacks, a polling worker's callbacks, a page's render entry, a
  # custody's claim. Every schema's Query module keeps its own filters and
  # orders too, as Emisar's do.
  @shapes ~w(start_link/1 init/1 child_spec/1 call/2 setup/1 wake_on/1 html/1 run_once/1 claim_next/2)

  # One-line normalizers and a boundary's own error around a check it shares
  # (`Reference.check/4` and the like): each reads better where it is used.
  @idioms ~w(optional_reference/2 optional_reference/3 optional_reference?/1 optional_text/2
             optional_timestamp/2 boolean/2 list/1 string/1 maybe_control/3 segment/1)

  # Copies kept on purpose, each with the modules allowed to hold it.
  @kept %{
    # A read composed where it is used, inside the caller's own transaction.
    "count/1" => ~w(Ryker.ControlPlane.OverviewProjection Ryker.Slack.AppHomeProjection),
    "lock_record/1" => ~w(Ryker.Emisar.Approvals Ryker.Waits.EventWaits),
    "settings/0" => ~w(Ryker.ControlPlane.ChannelDetail Ryker.ControlPlane.IncidentProjection),
    # Parallel implementations: the same steps over each module's own schema.
    "search_page/2" => ~w(Ryker.Behaviors.Recall Ryker.Memories.Recall),
    "retry/1" => ~w(Ryker.Delivery.RoutingResponseCustody Ryker.WeeklyReport.Custody),
    # Each boundary checks its own input against Slack's search limit.
    "source_limit/1" => ~w(Ryker.Slack.CapabilityTools.Arguments Ryker.Slack.Client.Messages),
    # The worker protocol fixes these two streaming hashes (Ryker.Crypto's note).
    "hex/1" => ~w(Ryker.CoopFleet.Bodies Ryker.CoopFleet.WorkspaceCheckpointBundle),
    # The self-analysis and repository reading lanes run one protocol over
    # their own tables; sharing it is the lane protocol's own change.
    "end_attempt/3" => ~w(Ryker.Improvement.Analyses Ryker.RepositoryKnowledge.Custody),
    "ended?/1" => ~w(Ryker.Improvement.Executor Ryker.RepositoryKnowledge.Executor),
    "remote_turn/4" => ~w(Ryker.Improvement.Executor Ryker.RepositoryKnowledge.Executor),
    "renew/2" => ~w(Ryker.Improvement.Analyses Ryker.RepositoryKnowledge.Custody),
    "terminal_receipt/1" => ~w(Ryker.Improvement.Analyses Ryker.RepositoryKnowledge.Custody),
    "unaddressable?/2" =>
      ~w(Ryker.Improvement.Executor Ryker.Learning.Executor Ryker.RepositoryKnowledge.Executor),
    "with_lease/2" =>
      ~w(Ryker.Improvement.Analyses Ryker.Learning.Batches Ryker.RepositoryKnowledge.Custody)
  }

  @smallest 12

  test "no helper is copied between modules" do
    copies =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(&clauses/1)
      |> functions()
      |> Enum.group_by(fn {_module, _name, normalized} -> normalized end)
      |> Enum.flat_map(fn {normalized, found} -> copied(normalized, found) end)
      |> Enum.sort()

    assert copies == []
  end

  # A function is all its clauses, in order: two functions that share a
  # first clause and differ after it are not copies.
  defp functions(clauses) do
    clauses
    |> Enum.reverse()
    |> Enum.chunk_by(fn {module, name, _normalized} -> {module, name} end)
    |> Enum.map(fn [{module, name, _normalized} | _rest] = chunk ->
      {module, name, Enum.map(chunk, &elem(&1, 2))}
    end)
  end

  defp copied(normalized, found) do
    modules = found |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
    {_module, name, _normalized} = hd(found)

    if length(modules) > 1 and size(normalized) >= @smallest and not allowed?(name, modules),
      do: ["#{name} in #{Enum.join(modules, ", ")}"],
      else: []
  end

  defp allowed?(name, modules) do
    name in @shapes or name in @idioms or modules -- Map.get(@kept, name, []) == [] or
      Enum.all?(modules, &String.ends_with?(&1, ".Query"))
  end

  # Each clause with the module it is in, after that module's aliases.
  defp clauses(path) do
    {:ok, ast} = path |> File.read!() |> Code.string_to_quoted()

    {_ast, %{found: found}} =
      Macro.traverse(ast, %{modules: [], aliases: %{}, found: []}, &visit/2, &leave/2)

    found
  end

  defp leave({:defmodule, _meta, [_name, _body]} = node, acc),
    do: {node, %{acc | modules: tl(acc.modules)}}

  defp leave(node, acc), do: {node, acc}

  defp visit({:defmodule, _meta, [{:__aliases__, _, parts}, _body]} = node, acc) do
    module = acc |> expand(parts) |> Enum.join(".")
    {node, %{acc | modules: [module | acc.modules], aliases: Map.put(acc.aliases, module, %{})}}
  end

  defp visit({:alias, _meta, [{:__aliases__, _, parts} | options]} = node, acc) do
    as =
      case options do
        [[as: {:__aliases__, _, [as]}]] -> as
        _no_as -> List.last(parts)
      end

    {node, put_alias(acc, as, expand(acc, parts))}
  end

  defp visit(
         {:alias, _meta, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]} = node,
         acc
       ) do
    acc =
      Enum.reduce(children, acc, fn {:__aliases__, _, parts}, acc ->
        put_alias(acc, List.last(parts), expand(acc, base) ++ parts)
      end)

    {node, acc}
  end

  defp visit({kind, _meta, [head, [do: body]]} = node, acc) when kind in [:def, :defp] do
    module = hd(acc.modules)
    normalized = normalize({head, body}, module, Map.fetch!(acc.aliases, module))
    {node, %{acc | found: [{module, name(head), normalized} | acc.found]}}
  end

  defp visit(node, acc), do: {node, acc}

  defp put_alias(acc, as, parts) do
    module = hd(acc.modules)
    %{acc | aliases: Map.update!(acc.aliases, module, &Map.put(&1, as, parts))}
  end

  # A module's parts with its aliases and `__MODULE__` written out, as strings.
  defp expand(acc, [{:__MODULE__, _, _} | rest]), do: [hd(acc.modules) | names(rest)]

  defp expand(%{modules: [module | _]} = acc, [first | rest]),
    do: Map.get(acc.aliases[module], first, [Atom.to_string(first)]) ++ names(rest)

  defp expand(%{modules: []}, parts), do: names(parts)

  defp names(parts), do: Enum.map(parts, &Atom.to_string/1)

  defp name({:when, _meta, [head | _guards]}), do: name(head)
  defp name({name, _meta, args}) when is_list(args), do: "#{name}/#{length(args)}"
  defp name({name, _meta, context}) when is_atom(context), do: "#{name}/0"

  # Variables renamed by order of appearance, metadata dropped, aliases and
  # `__MODULE__` resolved. A module attribute is the module's own value, so a
  # function that reads its module's attribute is no copy of another's.
  defp normalize(ast, module, aliases) do
    {normalized, _names} =
      Macro.prewalk(ast, %{}, fn
        {:@, _meta, [{attribute, _, context}]}, names when is_atom(context) ->
          {{:@, [], [module, attribute]}, names}

        {:__MODULE__, _meta, context}, names when is_atom(context) ->
          {{:alias, [], [module]}, names}

        {:__aliases__, _meta, [first | rest]}, names when is_atom(first) ->
          resolved =
            Map.get(aliases, first, [Atom.to_string(first)]) ++ Enum.map(rest, &to_string/1)

          {{:alias, [], [Enum.join(resolved, ".")]}, names}

        {name, _meta, context}, names when is_atom(name) and is_atom(context) ->
          index = Map.get(names, name, map_size(names))
          {{:variable, [], [index]}, Map.put_new(names, name, index)}

        {form, _meta, args}, names ->
          {{form, [], args}, names}

        other, names ->
          {other, names}
      end)

    normalized
  end

  # A renamed variable is one node, as the variable it stands for was.
  defp size(ast) do
    {_ast, count} =
      Macro.prewalk(ast, 0, fn
        {:variable, [], [_index]}, count -> {:variable, count + 1}
        node, count -> {node, count + 1}
      end)

    count
  end
end
