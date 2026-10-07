defmodule Ryker.Checks.IL08ChangesetPure do
  use Credo.Check,
    base_priority: :higher,
    category: :design,
    explanations: [
      check: """
      Iron Law IL-8: changeset modules are pure; they never call Repo.

      A pure changeset can be tested alone and composed into any
      transaction. Reading and writing belong to the context that builds
      the transaction.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    # `*_changeset.ex`, and `changeset.ex` for a context's own schema.
    if String.ends_with?(source_file.filename, "changeset.ex") do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  # `fun != :{}` skips a grouped alias such as `alias Ryker.Repo.{A, B}`,
  # which quotes to a dot node ending in `:Repo` but calls nothing.
  defp walk({{:., _, [{:__aliases__, meta, parts}, fun]}, _, args} = ast, ctx)
       when is_atom(fun) and fun != :{} and is_list(args) do
    if List.last(parts) == :Repo,
      do: {ast, put_issue(ctx, issue_for(ctx, meta, "Repo.#{fun}"))},
      else: {ast, ctx}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "IL-8: #{trigger} inside a changeset module. Changesets are pure; " <>
          "the context reads and writes.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
