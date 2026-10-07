defmodule Ryker.Checks.WebNoRepoCalls do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      House rule (§6): the web layer never runs a query. A LiveView, a
      component, the router and the endpoint show what a projection or a
      context read for them (`Ryker.ControlPlane.Projection`). A `Repo` call
      in one of them reads the database from the template's side, where no
      projection test covers it.
      """
    ]

  @web [:Component, :Endpoint, :LiveComponent, :LiveView, :Router]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if web_module?(source_file) do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  # A web module is known by the Phoenix behaviour it uses, not where it lives.
  defp web_module?(source_file), do: Credo.Code.prewalk(source_file, &find_use_web/2, false)

  defp find_use_web({:use, _, [{:__aliases__, _, [:Phoenix, kind]} | _]} = ast, _found)
       when kind in @web,
       do: {ast, true}

  defp find_use_web(ast, found), do: {ast, found}

  # `fun != :{}` skips a grouped alias such as `alias Ryker.Repo.{A, B}`.
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
        "House rule: #{trigger} in a web module. Read it in a projection or " <>
          "a context and pass the result in.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
