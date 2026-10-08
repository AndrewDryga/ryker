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
  # Until later that day the test compared only functions of the same name. A
  # scan that set names aside found 43 more groups, one rule written under
  # different names: three Slack timestamp parsers, the retention order three
  # times, two artifact-name checks. One had drifted into a bug too: the
  # incident room card cut its words in characters for a renderer that counts
  # bytes, so a goal written in Ukrainian stopped the room's card updating.
  #
  # A function counts as copied when its clauses match another function's
  # once its own name and its variable names are set aside, aliases are
  # resolved, and each call to a function of its own module is read as that
  # module's (two modules' `reference/2` are different checks), and it is big
  # enough to be logic rather than one call.
  use ExUnit.Case, async: true

  # Shapes a layer requires, which look alike because they must: OTP and Plug
  # callbacks, a polling worker's callbacks, a page's render entry, a
  # custody's claim. Every schema's Query module keeps its own filters and
  # orders too, as Emisar's do.
  @shapes ~w(start_link/1 init/1 child_spec/1 call/2 setup/1 wake_on/1 html/1 run_once/1 claim_next/2)

  # Copies kept on purpose, each group with its reason.
  @kept [
    {"A read composed where it is used, inside the caller's own transaction.",
     ~w(Ryker.ControlPlane.OverviewProjection.count/1 Ryker.Slack.AppHomeProjection.count/1)},
    {"A read composed where it is used, inside the caller's own transaction.",
     ~w(Ryker.CoopFleet.ControlPlane.Shared.fetch_and_lock_worker/1 Ryker.CoopFleet.Enrollment.fetch_and_lock_worker/1)},
    {"A read composed where it is used.",
     ~w(Ryker.ControlPlane.ChannelDetail.settings/0 Ryker.ControlPlane.IncidentProjection.settings/0)},
    {"The worker protocol fixes these two streaming hashes (Ryker.Crypto's note).",
     ~w(Ryker.CoopFleet.Bodies.hex/1 Ryker.CoopFleet.WorkspaceCheckpointBundle.hex/1)},
    # One-line normalizers of a stored value, each reading better where it is
    # used than through a module of its own, as Emisar writes them.
    {"A stored value as a list, or an empty one.",
     ~w(Ryker.ControlPlane.SourceText.list/1 Ryker.Ingress.MessageText.list/1
        Ryker.RoutingExamples.list/1)},
    {"No reference, or a valid one.",
     ~w(Ryker.Ingress.Input.optional_reference?/1 Ryker.Work.Cancellation.optional_reference?/1)},
    {"No token, or a valid one.",
     ~w(Ryker.Slack.HomeInteraction.optional_reference?/1 Ryker.Slack.Interaction.optional_reference?/1)},
    {"A stored value as a map, or an empty one.",
     ~w(Ryker.ControlPlane.ProviderMessage.map/1 Ryker.ControlPlane.RequestContextHTML.map_value/1)},
    {"A stored value as a string, or nil.",
     ~w(Ryker.ControlPlane.EpisodeRequest.safe_title/1 Ryker.ControlPlane.ProviderMessage.string/1
        Ryker.ControlPlane.ToolCard.string/1)},
    {"Text that is not empty, or nil.", ~w(Ryker.ControlPlane.LearningActivity.present_text/1
        Ryker.ControlPlane.RequestContextHTML.present/1)},
    {"No window, or a positive one.", ~w(Ryker.Admission.Context.valid_window?/1
        Ryker.Slack.Client.Assistant.optional_positive_integer?/1)},
    {"A document's digest, or nil without one.",
     ~w(Ryker.ControlPlane.SubscriptionProjection.document_digest/1
        Ryker.Slack.SourceAudits.digest_optional/1)},
    {"A URL path segment, percent-encoded with one standard library call.",
     ~w(Ryker.CoopFleet.Requests.segment/1 Ryker.GitHub.RepositoryAccess.segment/1
        Ryker.GitHub.RepositoryFiles.segment/1)}
  ]

  @smallest 12

  test "no helper is copied between functions" do
    copies = for functions <- copies(), not allowed?(functions), do: Enum.join(functions, ", ")

    assert Enum.sort(copies) == []
  end

  # A copy kept on purpose that is no longer a copy, shared since or gone, is
  # a reason nobody needs; the list keeps only what is still true.
  test "every copy kept on purpose is still a copy" do
    copies = copies()
    stale = for {reason, kept} <- @kept, not Enum.any?(copies, &(kept -- &1 == [])), do: reason

    assert stale == []
  end

  # Every group of two or more functions whose clauses match, each group's
  # functions sorted.
  defp copies do
    clauses =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(&clauses/1)

    locals =
      MapSet.new(clauses, fn {module, {name, _arity}, _clause, _aliases} -> {module, name} end)

    clauses
    |> functions(locals)
    |> Enum.group_by(fn {_function, normalized} -> normalized end, &elem(&1, 0))
    |> Enum.flat_map(fn {normalized, functions} ->
      functions = functions |> Enum.uniq() |> Enum.sort()
      if length(functions) > 1 and size(normalized) >= @smallest, do: [functions], else: []
    end)
  end

  # A function is all its clauses, in order: two functions that share a
  # first clause and differ after it are not copies.
  defp functions(clauses, locals) do
    clauses
    |> Enum.reverse()
    |> Enum.chunk_by(fn {module, function, _clause, _aliases} -> {module, function} end)
    |> Enum.map(fn [{module, {name, arity}, _clause, aliases} | _rest] = chunk ->
      normalized =
        Enum.map(chunk, fn {_module, _function, clause, _aliases} ->
          normalize(clause, module, aliases, {name, arity}, locals)
        end)

      {"#{module}.#{name}/#{arity}", normalized}
    end)
  end

  defp allowed?(functions) do
    Enum.all?(functions, &(name(&1) in @shapes)) or
      Enum.all?(functions, &String.contains?(&1, ".Query.")) or
      Enum.any?(@kept, fn {_reason, kept} -> functions -- kept == [] end)
  end

  defp name(function), do: function |> String.split(".") |> List.last()

  # Each clause with the module it is in and that module's aliases.
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
    clause = {module, function(head), {head, body}, Map.fetch!(acc.aliases, module)}
    {node, %{acc | found: [clause | acc.found]}}
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

  defp function({:when, _meta, [head | _guards]}), do: function(head)
  defp function({name, _meta, args}) when is_list(args), do: {name, length(args)}
  defp function({name, _meta, context}) when is_atom(context), do: {name, 0}

  # Variables renamed by order of appearance, metadata dropped, aliases and
  # `__MODULE__` resolved, and the function's own name, in its heads and its
  # calls to itself, set aside. A module attribute is the module's own value,
  # and a call or capture of a function the module defines is that module's,
  # so a function that reads either is no copy of another module's.
  defp normalize(ast, module, aliases, {own, arity}, locals) do
    {normalized, _names} =
      Macro.prewalk(ast, %{}, fn
        {:@, _meta, [{attribute, _, context}]}, names when is_atom(context) ->
          {{:@, [], [module, attribute]}, names}

        {:&, _meta, [{:/, _, [{name, _, context}, captured]}]}, names
        when is_atom(name) and is_atom(context) ->
          {{:&, [], [local(name, module, locals), captured]}, names}

        {:__MODULE__, _meta, context}, names when is_atom(context) ->
          {{:alias, [], [module]}, names}

        {:__aliases__, _meta, [first | rest]}, names when is_atom(first) ->
          resolved =
            Map.get(aliases, first, [Atom.to_string(first)]) ++ Enum.map(rest, &to_string/1)

          {{:alias, [], [Enum.join(resolved, ".")]}, names}

        {^own, _meta, args}, names when is_list(args) and length(args) == arity ->
          {{:own, [], args}, names}

        {name, _meta, context}, names when is_atom(name) and is_atom(context) ->
          index = Map.get(names, name, map_size(names))
          {{:variable, [], [index]}, Map.put_new(names, name, index)}

        {name, _meta, args}, names when is_atom(name) and is_list(args) ->
          {{local(name, module, locals), [], args}, names}

        {form, _meta, args}, names ->
          {{form, [], args}, names}

        other, names ->
          {other, names}
      end)

    normalized
  end

  defp local(name, module, locals),
    do: if(MapSet.member?(locals, {module, name}), do: {module, name}, else: name)

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
