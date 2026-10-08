defmodule Ryker.ConstraintNamesTest do
  # Emisar's table-rename rule: PostgreSQL keeps a constraint's or index's
  # name when its table is renamed, while Ecto infers a changeset's constraint
  # names from the table, so after a rename a violation raises instead of
  # coming back as a changeset error. Every constraint a changeset declares
  # must exist in the database under the name the changeset gives or Ecto
  # infers. Written 2026-10-08, it found eleven that did not: unique
  # constraints declared on one field where the index covers the workspace
  # too (channel memberships, configurations, membership events, incident
  # rooms), an index name PostgreSQL had cut to 63 bytes, and a schedule check
  # no migration ever created. Each of those violations raised.
  use Ryker.DataCase, async: true

  @kinds [:unique_constraint, :foreign_key_constraint, :check_constraint, :exclusion_constraint]

  test "every constraint a changeset declares exists under the name it expects" do
    names =
      Repo.query!("""
      SELECT conname FROM pg_constraint
      UNION SELECT indexname FROM pg_indexes WHERE schemaname = current_schema()
      """).rows
      |> List.flatten()
      |> MapSet.new()

    declared = Enum.flat_map(Path.wildcard("lib/**/changeset.ex"), &declared/1)

    assert length(declared) > 100

    missing =
      for {path, line, name} <- declared,
          not MapSet.member?(names, name),
          do: "#{path}:#{line} expects #{name}"

    assert missing == []
  end

  # Each constraint call in a changeset module, with the name it expects: the
  # `name:` option, or Ecto's inference from the schema's table and field. A
  # name the call computes is not checked here.
  defp declared(path) do
    {:ok, ast} = path |> File.read!() |> Code.string_to_quoted()

    {_ast, {source, found}} =
      Macro.prewalk(ast, {nil, []}, fn
        {:defmodule, _, [{:__aliases__, _, parts}, _body]} = node, {_source, found} ->
          {node, {source(parts), found}}

        {kind, meta, arguments} = node, {source, found}
        when kind in @kinds and is_list(arguments) ->
          {node, {source, expected(kind, arguments, source, path, meta[:line]) ++ found}}

        node, acc ->
          {node, acc}
      end)

    _ = source
    found
  end

  # The schema a changeset module serves; a module that is no schema's (the
  # settings sections' behaviour) checks nothing here.
  defp source(parts) do
    schema = Module.safe_concat(Enum.drop(parts, -1))

    if Code.ensure_loaded?(schema) and function_exported?(schema, :__schema__, 1),
      do: schema.__schema__(:source)
  rescue
    ArgumentError -> nil
  end

  defp expected(kind, arguments, source, path, line) do
    {field, options} = field_and_options(arguments)

    case {Keyword.get(options, :name), field, source} do
      {name, _field, _source} when is_binary(name) ->
        [{path, line, name}]

      {name, _field, _source} when is_atom(name) and not is_nil(name) ->
        [{path, line, Atom.to_string(name)}]

      {nil, field, source} when is_binary(source) and not is_nil(field) ->
        inferred(kind, field, source, path, line)

      _computed ->
        []
    end
  end

  defp inferred(:unique_constraint, fields, source, path, line) when is_list(fields),
    do: [{path, line, "#{source}_#{Enum.join(fields, "_")}_index"}]

  defp inferred(:unique_constraint, field, source, path, line),
    do: [{path, line, "#{source}_#{field}_index"}]

  defp inferred(:foreign_key_constraint, field, source, path, line),
    do: [{path, line, "#{source}_#{field}_fkey"}]

  defp inferred(:exclusion_constraint, field, source, path, line),
    do: [{path, line, "#{source}_#{field}_exclusion"}]

  defp inferred(_kind, _field, _source, _path, _line), do: []

  # `unique_constraint(changeset, field, options)` called directly, or piped
  # (`|> unique_constraint(field, options)`); a field that is not a literal
  # atom or list of atoms is computed.
  defp field_and_options([_changeset, field, options]),
    do: {literal_field(field), keyword(options)}

  defp field_and_options([first, second]) do
    if keyword(second) != [] or second == [],
      do: {literal_field(first), keyword(second)},
      else: {literal_field(second), []}
  end

  defp field_and_options([field]), do: {literal_field(field), []}
  defp field_and_options(_arguments), do: {nil, []}

  defp keyword(options) when is_list(options),
    do: if(Keyword.keyword?(options), do: options, else: [])

  defp keyword(_options), do: []

  defp literal_field(field) when is_atom(field), do: field

  defp literal_field(fields) when is_list(fields),
    do: if(Enum.all?(fields, &is_atom/1), do: fields)

  defp literal_field(_computed), do: nil
end
