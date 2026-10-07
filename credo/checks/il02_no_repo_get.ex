defmodule Ryker.Checks.IL02NoRepoGet do
  use Credo.Check,
    base_priority: :higher,
    category: :design,
    param_defaults: [pending: []],
    explanations: [
      check: """
      Iron Law IL-2: never `Repo.get`, `Repo.get!`, `Repo.get_by` or
      `Repo.get_by!`.

      They read a table without its Query module, so whatever that module says
      about the rows (which are live, which belong together) is skipped. Build
      the lookup in the Query module (`TurnQuery.by_id/2`) and read it with
      `Ryker.Repo.fetch/2`, which answers `{:ok, row}` or `{:error, :not_found}`.

      `pending:` lists the paths not moved yet, as for IL-1.
      """,
      params: [pending: "Paths whose lookups have not moved into Query modules yet."]
    ]

  @forbidden [:get, :get!, :get_by, :get_by!]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    filename = "/" <> source_file.filename
    pending = Params.get(params, :pending, __MODULE__)

    if String.contains?(filename, "/lib/") and
         not String.ends_with?(filename, "/lib/ryker/repo.ex") and
         not Enum.any?(pending, &String.contains?(filename, "/" <> &1)) do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  defp walk({{:., _, [{:__aliases__, meta, parts}, fun]}, _, args} = ast, ctx)
       when fun in @forbidden and is_list(args) and args != [] do
    if List.last(parts) == :Repo,
      do: {ast, put_issue(ctx, issue_for(ctx, meta, "Repo.#{fun}"))},
      else: {ast, ctx}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "IL-2: #{trigger} skips the Query module. Build the lookup there " <>
          "and read it with Ryker.Repo.fetch/2.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
