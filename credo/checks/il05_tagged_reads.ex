defmodule Ryker.Checks.IL05TaggedReads do
  use Credo.Check,
    base_priority: :higher,
    category: :design,
    explanations: [
      check: """
      Iron Law IL-5: a public function that reads one row answers
      `{:ok, row}` or `{:error, :not_found}`, never the row or nil.

      Callers then match one shape, and a `with` chain reads the absence as
      the error it is instead of passing nil along. Read the row with
      `Ryker.Repo.fetch/2`. A value a query selects (a time, one column) is
      not a row: its pipeline names a `select_*` helper and it stays a value.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    filename = "/" <> source_file.filename

    if String.contains?(filename, "/lib/") and
         not String.ends_with?(filename, ["/query.ex", "/changeset.ex", "/lib/ryker/repo.ex"]) do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  defp walk({:def, meta, [head, body]} = ast, ctx) when is_list(body) do
    case {name(head), body |> Keyword.get(:do) |> last_expression()} do
      {name, {_call, _meta, _args} = last} when is_atom(name) ->
        if row_read?(last),
          do: {ast, put_issue(ctx, issue_for(ctx, meta, name))},
          else: {ast, ctx}

      _other ->
        {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp name({:when, _meta, [head | _guards]}), do: name(head)
  defp name({name, _meta, _args}) when is_atom(name), do: name
  defp name(_head), do: nil

  defp last_expression({:__block__, _meta, [_ | _] = expressions}),
    do: expressions |> List.last() |> last_expression()

  defp last_expression(expression), do: expression

  # `Repo.one(query)` or `query |> ... |> Repo.one()`, of whole rows, and
  # `Repo.peek`, which is the same read named for a nil that means no row.
  defp row_read?({:|>, _meta, [query, call]}), do: repo_one?(call, 0) and not selects?(query)
  defp row_read?(call), do: repo_one?(call, 1) and not selects?(call)

  defp repo_one?({{:., _, [{:__aliases__, _, parts}, read]}, _, args}, arity)
       when read in [:one, :peek],
       do: List.last(parts) == :Repo and length(args) in [arity, arity + 1]

  defp repo_one?(_call, _arity), do: false

  defp selects?(ast) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn
        {{:., _, [_module, fun]}, _, _args} = node, found when is_atom(fun) ->
          {node, found or select_helper?(fun)}

        {fun, _, args} = node, found when is_atom(fun) and is_list(args) ->
          {node, found or select_helper?(fun)}

        node, found ->
          {node, found}
      end)

    found
  end

  defp select_helper?(fun), do: fun |> Atom.to_string() |> String.starts_with?("select_")

  defp issue_for(ctx, meta, name) do
    format_issue(
      ctx,
      message:
        "IL-5: #{name} answers a row or nil. Read it with Ryker.Repo.fetch/2 " <>
          "and answer {:ok, row} or {:error, :not_found}.",
      trigger: "#{name}",
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
