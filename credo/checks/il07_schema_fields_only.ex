defmodule Ryker.Checks.IL07SchemaFieldsOnly do
  use Credo.Check,
    base_priority: :higher,
    category: :design,
    explanations: [
      check: """
      Iron Law IL-7: schema modules are fields and associations only.

      A schema is a data shape. `cast` and `validate_*` pipelines and the
      `changeset`, `create`, `insert` and `update` builders live in its
      `*_changeset.ex` module, where they can be tested alone and composed
      into any transaction. A pure helper about one struct, such as
      `Ryker.Settings.Environment.writable_refs/1`, may stay.
      """
    ]

  @transition_names [:changeset, :create, :insert, :update]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if schema_module?(source_file) do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  # A schema is known by what it uses, not where it lives.
  defp schema_module?(source_file),
    do: Credo.Code.prewalk(source_file, &find_use_schema/2, false)

  defp find_use_schema({:use, _, [{:__aliases__, _, [:Ecto, :Schema]} | _]} = ast, _found),
    do: {ast, true}

  defp find_use_schema(ast, found), do: {ast, found}

  defp walk({kind, _, [head | _]} = ast, ctx) when kind in [:def, :defp] do
    case def_name(head) do
      name when name in @transition_names ->
        {ast, put_issue(ctx, issue_for(ctx, def_meta(head), "#{kind} #{name}"))}

      _other ->
        {ast, ctx}
    end
  end

  # `Ecto.Changeset.<anything>`, and a helper's `validate_*`, called remotely.
  # `Ecto.Type.cast/2` reads one value and is not a changeset.
  defp walk({{:., _, [{:__aliases__, meta, parts}, fun]}, _, args} = ast, ctx)
       when is_atom(fun) and is_list(args) do
    if parts == [:Ecto, :Changeset] or validation?(fun),
      do: {ast, put_issue(ctx, issue_for(ctx, meta, dotted(parts, fun)))},
      else: {ast, ctx}
  end

  # An imported `cast` or `validate_*`, called directly or piped.
  defp walk({fun, meta, args} = ast, ctx) when is_atom(fun) and is_list(args) do
    if (fun == :cast and length(args) >= 2) or validation?(fun),
      do: {ast, put_issue(ctx, issue_for(ctx, meta, Atom.to_string(fun)))},
      else: {ast, ctx}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp validation?(fun), do: fun |> Atom.to_string() |> String.starts_with?("validate_")

  defp dotted(parts, fun), do: Enum.map_join(parts ++ [fun], ".", &Atom.to_string/1)

  defp def_name({:when, _, [inner | _]}), do: def_name(inner)
  defp def_name({name, _, _}) when is_atom(name), do: name
  defp def_name(_head), do: nil

  defp def_meta({:when, _, [inner | _]}), do: def_meta(inner)
  defp def_meta({_, meta, _}), do: meta

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "IL-7: changeset logic in a schema module. Move cast/validate and the " <>
          "changeset/insert/update builders into its *_changeset.ex module; a " <>
          "schema holds fields and associations.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
