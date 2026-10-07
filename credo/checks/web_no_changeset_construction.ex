defmodule Ryker.Checks.WebNoChangesetConstruction do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      House rule (§6): the domain builds changesets; the web layer never
      does. A LiveView or component that casts, changes, validates or
      constrains one holds domain validation where no context test covers
      it. Ryker's console forms cast their fields
      (`Ryker.ControlPlane.SettingsSections.cast/2`) and hand plain
      attributes to a context, which builds the changeset.

      Flagged in a web module: `import Ecto.Changeset` in any form, a call to
      a `*Changeset` module, and any `Ecto.Changeset` call except reading one
      that already exists (`changed?`, `fetch_change`, `fetch_field`,
      `fetch_field!`, `get_assoc`, `get_change`, `get_embed`, `get_field`,
      `traverse_errors`).
      """
    ]

  @web [:Component, :Endpoint, :LiveComponent, :LiveView, :Router]
  @reads [
    :changed?,
    :fetch_change,
    :fetch_field,
    :fetch_field!,
    :get_assoc,
    :get_change,
    :get_embed,
    :get_field,
    :traverse_errors
  ]

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

  defp web_module?(source_file), do: Credo.Code.prewalk(source_file, &find_use_web/2, false)

  defp find_use_web({:use, _, [{:__aliases__, _, [:Phoenix, kind]} | _]} = ast, _found)
       when kind in @web,
       do: {ast, true}

  defp find_use_web(ast, found), do: {ast, found}

  defp walk({:import, meta, [{:__aliases__, _, [:Ecto, :Changeset]} | _]} = ast, ctx),
    do: {ast, put_issue(ctx, issue_for(ctx, meta, "import Ecto.Changeset"))}

  defp walk({{:., _, [{:__aliases__, meta, parts}, fun]}, _, args} = ast, ctx)
       when is_atom(fun) and fun != :{} and is_list(args) do
    if builds_changeset?(parts, fun),
      do: {ast, put_issue(ctx, issue_for(ctx, meta, dotted(parts, fun)))},
      else: {ast, ctx}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp builds_changeset?([:Ecto, :Changeset], fun), do: fun not in @reads

  defp builds_changeset?(parts, _fun),
    do: parts |> List.last() |> Atom.to_string() |> String.ends_with?("Changeset")

  defp dotted(parts, fun), do: Enum.map_join(parts ++ [fun], ".", &Atom.to_string/1)

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "House rule: #{trigger} in a web module. A context builds the " <>
          "changeset; the web layer passes it attributes.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
