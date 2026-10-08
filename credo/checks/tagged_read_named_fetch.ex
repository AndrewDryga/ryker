defmodule Ryker.Checks.TaggedReadNamedFetch do
  use Credo.Check,
    base_priority: :normal,
    category: :readability,
    explanations: [
      check: """
      Emisar's README: a row-returning read is `fetch_*`, and the prefix is
      its contract, `{:ok, row}` or a reason. A function whose last
      expression is `Repo.fetch`, piped, or a `with` that turns only a missing
      row into a reason (`with {:error, :not_found} <- Repo.fetch(query)`),
      hands back that tuple, so its name starts with `fetch_`
      (`fetch_and_lock_*` when the read locks the row, see
      `Ryker.Checks.LockNameReturnsNothing`).
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if String.contains?("/" <> source_file.filename, "/lib/") and
         not String.ends_with?(source_file.filename, "/query.ex") do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  defp walk({kind, meta, [head, [do: body]]} = ast, ctx) when kind in [:def, :defp] do
    name = name(head)

    if not String.starts_with?(name, "fetch_") and fetches_last?(body),
      do: {ast, put_issue(ctx, issue_for(ctx, meta, name))},
      else: {ast, ctx}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp name({:when, _meta, [head | _guards]}), do: name(head)
  defp name({name, _meta, _arguments}) when is_atom(name), do: Atom.to_string(name)
  defp name(_head), do: "fetch_"

  defp fetches_last?({:__block__, _meta, expressions}),
    do: expressions |> List.last() |> fetches?()

  defp fetches_last?(expression), do: fetches?(expression)

  defp fetches?({{:., _, [{:__aliases__, _, parts}, :fetch]}, _meta, _arguments}),
    do: List.last(parts) == :Repo

  defp fetches?({:|>, _meta, [_left, right]}), do: fetches?(right)

  defp fetches?({:with, _meta, [{:<-, _, [{:error, :not_found}, right]} | _rest]}),
    do: fetches?(right)

  defp fetches?(_expression), do: false

  defp issue_for(ctx, meta, name) do
    format_issue(
      ctx,
      message:
        "`#{name}` answers `{:ok, row}` or a reason: name it `fetch_*`, as Emisar's " <>
          "README asks of a row-returning read.",
      trigger: name,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
