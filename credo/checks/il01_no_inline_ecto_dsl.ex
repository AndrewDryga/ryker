defmodule Ryker.Checks.IL01NoInlineEctoDsl do
  use Credo.Check,
    base_priority: :higher,
    category: :design,
    explanations: [
      check: """
      Iron Law IL-1: no Ecto query DSL outside Query modules.

      Every query starts in the Query module of the schema it reads
      (`Ryker.Work.Turn.Query.all/0` beside `Ryker.Work.Turn`): one place says
      what a table's rows mean, such as which turns are still running, and
      every caller composes it instead of writing its own version. So
      `import Ecto.Query` and a qualified `Ecto.Query.from(...)` belong only in
      a Query module (`<schema>/query.ex`), and a read never starts at the
      schema itself:
      `Repo.all(Sprocket)` or `Sprocket |> Repo.aggregate(:count)` reads every
      row the way no Query module says, so it reads `Sprocket.Query.all()`.
      """
    ]

  @reads [:all, :one, :one!, :aggregate, :exists?, :stream, :delete_all, :update_all]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    filename = "/" <> source_file.filename

    # `lib/ryker.ex` defines `use Ryker, :query`, the one import every Query
    # module takes.
    if String.contains?(filename, "/lib/") and not String.ends_with?(filename, "/query.ex") and
         not String.ends_with?(filename, "/lib/ryker.ex") do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  defp walk({:import, meta, [{:__aliases__, _, [:Ecto, :Query]} | _]} = ast, ctx) do
    {ast, put_issue(ctx, issue_for(ctx, meta, "import Ecto.Query"))}
  end

  # `Ecto.Query.t()` in a spec names a type; every other call is the DSL.
  defp walk({{:., _, [{:__aliases__, meta, [:Ecto, :Query]}, fun]}, _, args} = ast, ctx)
       when is_atom(fun) and fun != :t and is_list(args) do
    {ast, put_issue(ctx, issue_for(ctx, meta, "Ecto.Query.#{fun}"))}
  end

  # A read that starts at a schema rather than its Query module.
  defp walk(
         {{:., _, [{:__aliases__, meta, repo}, fun]}, _, [{:__aliases__, _, _} | _]} = ast,
         ctx
       )
       when fun in @reads do
    if List.last(repo) == :Repo,
      do: {ast, put_issue(ctx, issue_for(ctx, meta, "Repo.#{fun}(Schema)"))},
      else: {ast, ctx}
  end

  defp walk(
         {:|>, _, [{:__aliases__, _, _}, {{:., _, [{:__aliases__, meta, repo}, fun]}, _, _}]} =
           ast,
         ctx
       )
       when fun in @reads do
    if List.last(repo) == :Repo,
      do: {ast, put_issue(ctx, issue_for(ctx, meta, "Schema |> Repo.#{fun}"))},
      else: {ast, ctx}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "IL-1: #{trigger} outside a Query module. Build the query in the " <>
          "schema's Query module (<schema>/query.ex) and start from its all/0.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
