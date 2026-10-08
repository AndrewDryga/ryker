defmodule Ryker.Checks.LockNameReturnsNothing do
  use Credo.Check,
    base_priority: :normal,
    category: :readability,
    explanations: [
      check: """
      Emisar's README: name a function for what it returns, not for one side
      effect along the way. A function named for the lock it takes (`lock_*`,
      `locked_*`) hands back nothing a caller reads; one that hands back the
      row it locked says both jobs: `fetch_and_lock_*` for `{:ok, row}` or a
      reason, `peek_and_lock_*` when no row is itself the answer.

      The check flags a `lock_*` or `locked_*` function whose last expression
      is a read of the repo (`Repo.fetch`, `Repo.peek`, `Repo.one`,
      `Repo.all`), piped, behind `||`, or a `with` that turns only a missing
      row into a reason (`with {:error, :not_found} <- Repo.fetch(locked)`) and
      so hands the row back. A function that takes an advisory lock and
      answers `:ok` keeps its name.
      """
    ]

  @reads [:fetch, :peek, :one, :one!, :all]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if String.contains?("/" <> source_file.filename, "/lib/") do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  defp walk({kind, meta, [head, [do: body]]} = ast, ctx) when kind in [:def, :defp] do
    name = name(head)

    if lock_name?(name) and reads_last?(body),
      do: {ast, put_issue(ctx, issue_for(ctx, meta, name))},
      else: {ast, ctx}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp name({:when, _meta, [head | _guards]}), do: name(head)
  defp name({name, _meta, _arguments}) when is_atom(name), do: Atom.to_string(name)
  defp name(_head), do: ""

  defp lock_name?("lock_" <> _rest), do: true
  defp lock_name?("locked_" <> _rest), do: true
  defp lock_name?(_name), do: false

  defp reads_last?({:__block__, _meta, expressions}), do: expressions |> List.last() |> reads?()
  defp reads_last?(expression), do: reads?(expression)

  defp reads?({{:., _, [{:__aliases__, _, parts}, read]}, _meta, _arguments})
       when read in @reads,
       do: List.last(parts) == :Repo

  defp reads?({:|>, _meta, [_left, right]}), do: reads?(right)
  defp reads?({:||, _meta, [left, _fallback]}), do: reads?(left)

  defp reads?({:with, _meta, [{:<-, _, [{:error, :not_found}, right]} | _rest]}),
    do: reads?(right)

  defp reads?(_expression), do: false

  defp issue_for(ctx, meta, name) do
    format_issue(
      ctx,
      message:
        "`#{name}` hands back the row it locks: name both jobs, `fetch_and_lock_*` " <>
          "(or `peek_and_lock_*` when no row is an answer), as Emisar's README asks.",
      trigger: name,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
