defmodule Ryker.CopiedHelpersTest do
  # Emisar's rule: a pure helper used in more than one place is its own small
  # module with unit tests, not a function copied between call sites. The scan
  # behind this test found 37 copied helpers on 2026-10-08, and beside them a
  # family of near-copies: eleven ways to word "3 messages", nineteen backoff
  # formulas, twenty-two Slack id patterns, six Slack links built by hand. Two
  # copies had already drifted into bugs: a task's title and an open goal's
  # outcome were measured in bytes where everything else counted characters.
  #
  # A clause counts as copied when its head and body match another module's
  # once variable names are set aside, and it is big enough to be logic rather
  # than one call.
  use ExUnit.Case, async: true

  # Shapes a layer requires, which look alike because they must: OTP
  # callbacks, a page's render entry, a custody's claim, a Query module's own
  # select.
  @shapes ~w(start_link/1 init/1 html/1 run_once/1 claim_next/2 select_with_episode/1)

  # Copies kept on purpose, each with the modules allowed to hold it.
  @kept %{
    # Each catalog's own lookup over its own entries.
    "fetch/1" => ~w(Ryker.ControlPlane.SettingsSections Ryker.Webhooks.Presets),
    # A two-line read composed where it is used, inside the caller's transaction.
    "lock_record/1" => ~w(Ryker.Emisar.Approvals Ryker.Waits.EventWaits),
    "settings/0" => ~w(Ryker.ControlPlane.ChannelDetail Ryker.ControlPlane.IncidentProjection),
    # The self-analysis and repository reading lanes run one protocol over
    # their own tables and prompts; `submission/1` names each lane's own Prompt.
    "end_attempt/3" => ~w(Ryker.Improvement.Analyses Ryker.RepositoryKnowledge.Custody),
    "renew/2" => ~w(Ryker.Improvement.Analyses Ryker.RepositoryKnowledge.Custody),
    "with_lease/2" =>
      ~w(Ryker.Improvement.Analyses Ryker.Learning.Batches Ryker.RepositoryKnowledge.Custody),
    "remote_session/3" => ~w(Ryker.Improvement.Executor Ryker.RepositoryKnowledge.Executor),
    "remote_turn/4" => ~w(Ryker.Improvement.Executor Ryker.RepositoryKnowledge.Executor),
    "submission/1" => ~w(Ryker.Improvement.Executor Ryker.RepositoryKnowledge.Executor),
    "conversation_ref/1" => ~w(Ryker.Slack.CommandHandler Ryker.Slack.InteractionHandler)
  }

  @smallest 25

  test "no helper is copied between modules" do
    copies =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(&clauses/1)
      |> Enum.group_by(fn {_module, _name, normalized} -> normalized end)
      |> Enum.flat_map(fn {normalized, found} -> copied(normalized, found) end)
      |> Enum.sort()

    assert copies == []
  end

  defp copied(normalized, found) do
    modules = found |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
    {_module, name, _normalized} = hd(found)

    if length(modules) > 1 and size(normalized) >= @smallest and not allowed?(name, modules),
      do: ["#{name} in #{Enum.join(modules, ", ")}"],
      else: []
  end

  defp allowed?(name, modules),
    do: name in @shapes or modules -- Map.get(@kept, name, []) == []

  defp clauses(path) do
    {:ok, ast} = path |> File.read!() |> Code.string_to_quoted()

    {_ast, {_modules, found}} =
      Macro.prewalk(ast, {[], []}, fn
        {:defmodule, _meta, [{:__aliases__, _, parts}, _body]} = node, {modules, found} ->
          {node, {[Enum.join(parts, ".") | modules], found}}

        {kind, _meta, [head, [do: body]]} = node, {modules, found} when kind in [:def, :defp] ->
          {node, {modules, [{hd(modules), name(head), normalize({head, body})} | found]}}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp name({:when, _meta, [head | _guards]}), do: name(head)
  defp name({name, _meta, args}) when is_list(args), do: "#{name}/#{length(args)}"
  defp name({name, _meta, context}) when is_atom(context), do: "#{name}/0"

  # Variables renamed by order of appearance and metadata dropped, so two
  # clauses differing only in names compare equal.
  defp normalize(ast) do
    {normalized, _names} =
      Macro.prewalk(ast, %{}, fn
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
