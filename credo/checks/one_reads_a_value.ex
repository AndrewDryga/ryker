defmodule Ryker.Checks.OneReadsAValue do
  use Credo.Check,
    base_priority: :normal,
    category: :readability,
    explanations: [
      check: """
      Emisar's reads say what they expect of the row. A row the code reads by
      its identity is `Repo.fetch` (`{:ok, row}` or `{:error, :not_found}`),
      `Repo.fetch!` (the caller has proved it is there: a foreign key it
      follows, a row it just locked) or `Repo.peek` (no row is itself the
      answer). `Repo.one` and `Repo.one!` are left for a value a query selects
      and for aggregates.

      The check flags `Repo.one` or `Repo.one!` of a query built with a `by_*`
      filter and no `select_*` helper: a row read by its identity.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    filename = "/" <> source_file.filename

    if String.contains?(filename, "/lib/") and
         not String.ends_with?(filename, ["/query.ex", "/lib/ryker/repo.ex"]) do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  # `query |> ... |> Repo.one!()`
  defp walk({:|>, meta, [query, call]} = ast, ctx) do
    if one?(call, 0) and identity_read?(query),
      do: {ast, put_issue(ctx, issue_for(ctx, meta, call))},
      else: {ast, ctx}
  end

  # `Repo.one!(query)`
  defp walk({{:., meta, [_repo, _read]}, _, [query | _options]} = call, ctx) do
    if one?(call, 1) and identity_read?(query),
      do: {call, put_issue(ctx, issue_for(ctx, meta, call))},
      else: {call, ctx}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp one?({{:., _, [{:__aliases__, _, parts}, read]}, _, arguments}, arity)
       when read in [:one, :one!],
       do: List.last(parts) == :Repo and length(arguments) in [arity, arity + 1]

  defp one?(_call, _arity), do: false

  defp identity_read?(query) do
    {_ast, names} =
      Macro.prewalk(query, [], fn
        {{:., _, [_module, fun]}, _, _arguments} = node, names when is_atom(fun) ->
          {node, [Atom.to_string(fun) | names]}

        node, names ->
          {node, names}
      end)

    Enum.any?(names, &String.starts_with?(&1, "by_")) and
      not Enum.any?(names, &String.starts_with?(&1, "select_"))
  end

  defp issue_for(ctx, meta, {{:., _, [_repo, read]}, _, _arguments}) do
    format_issue(
      ctx,
      message:
        "Repo.#{read} of a row read by its identity: use Repo.fetch, Repo.fetch! when the " <>
          "row is proved there, or Repo.peek when no row is the answer.",
      trigger: "Repo.#{read}",
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
