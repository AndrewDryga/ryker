defmodule Ryker.Checks.IL08ValidationInChangesets do
  use Credo.Check,
    base_priority: :higher,
    category: :design,
    explanations: [
      check: """
      Iron Law IL-8, the other half: a module that reads or writes the
      database leaves validation to a changeset module. `cast`, `validate_*`,
      the constraint mappings and `add_error` belong in a `*_changeset.ex`
      module, with one function per transition, where they can be tested
      alone. A context may still `change` a row with values it already holds.

      Flagged in a module that calls `Repo` and is not a changeset module:
      `import Ecto.Changeset` in any form, and `Ecto.Changeset.cast`,
      `cast_assoc`, `cast_embed`, `validate_*`, `*_constraint` or
      `add_error`. A helper that never calls `Repo`, such as
      `Ryker.Settings.Validation`, may use them.
      """
    ]

  @builders [:add_error, :cast, :cast_assoc, :cast_embed]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if checked?(source_file) do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  # Production code only: a test may build a changeset to provoke a constraint.
  defp checked?(%SourceFile{filename: filename} = source_file) do
    String.contains?("/" <> filename, "/lib/") and
      not String.ends_with?(filename, "changeset.ex") and calls_repo?(source_file)
  end

  defp calls_repo?(source_file), do: Credo.Code.prewalk(source_file, &find_repo_call/2, false)

  defp find_repo_call({{:., _, [{:__aliases__, _, parts}, fun]}, _, args} = ast, found)
       when is_atom(fun) and fun != :{} and is_list(args),
       do: {ast, found or List.last(parts) == :Repo}

  defp find_repo_call(ast, found), do: {ast, found}

  defp walk({:import, meta, [{:__aliases__, _, [:Ecto, :Changeset]} | _]} = ast, ctx),
    do: {ast, put_issue(ctx, issue_for(ctx, meta, "import Ecto.Changeset"))}

  defp walk({{:., _, [{:__aliases__, meta, [:Ecto, :Changeset]}, fun]}, _, args} = ast, ctx)
       when is_atom(fun) and is_list(args) do
    if validation?(fun),
      do: {ast, put_issue(ctx, issue_for(ctx, meta, "Ecto.Changeset.#{fun}"))},
      else: {ast, ctx}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp validation?(fun) do
    name = Atom.to_string(fun)

    fun in @builders or String.starts_with?(name, "validate_") or
      String.ends_with?(name, "_constraint")
  end

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "IL-8: #{trigger} in a module that calls Repo. Validation and " <>
          "constraints belong in a *_changeset.ex module.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
