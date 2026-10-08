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

  # Ecto counts a length in graphemes unless told otherwise, while a column's
  # check counts code points (`char_length`) or bytes (`octet_length`). Text
  # whose graphemes fit and whose code points or bytes do not passed the
  # changeset and broke the check instead of coming back as a field error: 139
  # of 169 bounds counted graphemes until 2026-10-08. A column with no check
  # counts code points, as Ryker's text does (`Ryker.Text.char_length/1`).
  test "every length a changeset checks counts in its column's unit" do
    checks =
      Repo.query!("""
      SELECT conrelid::regclass::text, pg_get_constraintdef(oid)
      FROM pg_constraint WHERE contype = 'c'
      """).rows
      |> Enum.group_by(&hd/1, &List.last/1)

    bounds = Enum.flat_map(Path.wildcard("lib/**/changeset.ex"), &bounds/1)

    assert length(bounds) > 100

    wrong =
      for {path, line, table, field, count} <- bounds,
          expected = column_unit(Map.get(checks, table, []), field),
          count != expected,
          do: "#{path}:#{line} counts #{field} in #{inspect(count)}, its column in #{expected}"

    assert wrong == []
  end

  defp column_unit(definitions, field) do
    bytes = ~r/octet_length\(\(?#{field}\)?(::\w+)?\)/
    if Enum.any?(definitions, &Regex.match?(bytes, &1)), do: :bytes, else: :codepoints
  end

  # Each `validate_length` of a text field in a changeset module, with its
  # table and the unit it counts in (nil when it names none). A list field's
  # length counts its items, so it has no unit.
  defp bounds(path) do
    {:ok, ast} = path |> File.read!() |> Code.string_to_quoted()

    {_ast, {_schema, found}} =
      Macro.prewalk(ast, {nil, []}, fn
        {:defmodule, _, [{:__aliases__, _, parts}, _body]} = node, {_schema, found} ->
          {node, {schema(parts), found}}

        {:validate_length, meta, arguments} = node, {schema, found} when is_list(arguments) ->
          {node, {schema, bound(schema, arguments, path, meta[:line]) ++ found}}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp bound(nil, _arguments, _path, _line), do: []

  defp bound(schema, arguments, path, line) do
    case field_and_options(arguments) do
      {field, options} when is_atom(field) and not is_nil(field) ->
        if match?({:array, _}, schema.__schema__(:type, field)),
          do: [],
          else: [{path, line, schema.__schema__(:source), field, Keyword.get(options, :count)}]

      _computed ->
        []
    end
  end

  defp schema(parts) do
    schema = Module.safe_concat(Enum.drop(parts, -1))
    if Code.ensure_loaded?(schema) and function_exported?(schema, :__schema__, 1), do: schema
  rescue
    ArgumentError -> nil
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
