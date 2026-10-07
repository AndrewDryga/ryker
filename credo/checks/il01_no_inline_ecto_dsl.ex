defmodule Ryker.Checks.IL01NoInlineEctoDsl do
  use Credo.Check,
    base_priority: :higher,
    category: :design,
    explanations: [
      check: """
      Iron Law IL-1: no Ecto query DSL outside Query modules.

      Every query starts in the Query module of the schema it reads
      (`Ryker.Work.TurnQuery.all/0` beside `Ryker.Work.Turn`): one place says
      what a table's rows mean, such as which turns are still running, and
      every caller composes it instead of writing its own version. So
      `import Ecto.Query` and a qualified `Ecto.Query.from(...)` belong only in
      a `*_query.ex` module.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    filename = "/" <> source_file.filename

    if String.contains?(filename, "/lib/") and not String.ends_with?(filename, "_query.ex") do
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

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "IL-1: #{trigger} outside a Query module. Build the query in the " <>
          "schema's *_query.ex module and start from its all/0.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
