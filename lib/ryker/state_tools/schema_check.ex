defmodule Ryker.StateTools.SchemaCheck do
  @moduledoc false
  alias Ryker.Schedules
  alias Ryker.StateTools.Catalog
  alias Ryker.Text
  alias Ryker.UTCDateTime
  alias Ryker.Wording

  # Validates tool arguments against the exact JSON-schema subset the catalog
  # emits (anyOf, oneOf, const, enum, object, array, string, integer, boolean,
  # null). The catalog is the one the caller advertised, so a tool it withheld
  # is not configured here either.

  @maximum_issues 8

  @spec exact_schema(String.t(), map(), [map()]) :: :ok | {:error, term()}
  def exact_schema(name, arguments, catalog) do
    case Enum.find(catalog, &(&1["name"] == name)) do
      %{"inputSchema" => schema} ->
        if valid_schema_value?(schema, arguments),
          do: :ok,
          else: schema_error(name, arguments, schema)

      nil ->
        {:error, :not_configured}
    end
  end

  defp schema_error("request_task", %{"repository" => repository}, schema) do
    if valid_schema_value?(schema["properties"]["repository"], repository),
      do: {:error, :invalid_arguments},
      else: {:error, :invalid_repository_reference}
  end

  defp schema_error("validate_final", _arguments, _schema),
    do: {:error, :invalid_final_arguments}

  # Each refusal names the correction: four calls for "every weekday" failed in
  # a row on 2026-09-25 before the model settled for Mondays.
  defp schema_error("propose_automation", %{"proposals" => proposals}, _schema)
       when is_list(proposals) do
    cond do
      length(proposals) > Catalog.maximum_automation_proposals() ->
        {:error, :automation_proposal_limit}

      Enum.any?(proposals, &unsupported_automation_source?/1) ->
        {:error, :invalid_automation_source}

      Enum.any?(proposals, &unsupported_time_trigger?/1) ->
        {:error, :invalid_schedule_trigger}

      true ->
        {:error, :invalid_arguments}
    end
  end

  # Every other refusal says where: each field that breaks the schema, by JSON
  # Pointer, with a stable code and the constraint in words (never the value
  # sent), the first eight of them and how many there were. A bare
  # "invalid_arguments" left the model to guess which field to change
  # (Emisar's actionable validation, 2026-10-08).
  defp schema_error(_name, arguments, schema) do
    all = issues(schema, arguments, "")

    {:error,
     {:invalid_arguments,
      %{
        issues: Enum.take(all, @maximum_issues),
        count: length(all),
        truncated: length(all) > @maximum_issues
      }}}
  end

  defp unsupported_automation_source?(%{"trigger" => %{"type" => "source_event"} = trigger}),
    do: trigger["source_kind"] not in Catalog.source_kinds()

  defp unsupported_automation_source?(_proposal), do: false

  defp unsupported_time_trigger?(%{"trigger" => %{"type" => "time"} = trigger}),
    do: Schedules.ScheduleRecurrence.from_trigger(trigger) == {:error, :invalid_schedule_trigger}

  defp unsupported_time_trigger?(_proposal), do: false

  defp valid_schema_value?(%{"anyOf" => schemas}, value),
    do: Enum.any?(schemas, &valid_schema_value?(&1, value))

  defp valid_schema_value?(%{"oneOf" => schemas} = schema, value) do
    base = Map.drop(schema, ["oneOf"])

    base_valid =
      map_size(base) == 0 or Map.keys(base) == ["additionalProperties"] or
        valid_schema_value?(base, value)

    base_valid and Enum.count(schemas, &valid_schema_value?(&1, value)) == 1
  end

  defp valid_schema_value?(%{"const" => expected} = schema, value) do
    rest = Map.delete(schema, "const")
    value == expected and valid_schema_value?(rest, value)
  end

  defp valid_schema_value?(%{"enum" => values} = schema, value) do
    rest = Map.delete(schema, "enum")
    value in values and valid_schema_value?(rest, value)
  end

  defp valid_schema_value?(%{"properties" => _properties} = schema, value)
       when is_map(value) and not is_map_key(schema, "type") do
    object = Map.put(schema, "type", "object")
    valid_schema_value?(object, value)
  end

  defp valid_schema_value?(%{"type" => "object"} = schema, value) when is_map(value) do
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])
    keys = Map.keys(value)

    Enum.all?(required, &Map.has_key?(value, &1)) and
      (Map.get(schema, "additionalProperties", true) != false or
         Enum.all?(keys, &Map.has_key?(properties, &1))) and
      Enum.all?(value, fn {key, child} ->
        case Map.fetch(properties, key) do
          {:ok, child_schema} -> valid_schema_value?(child_schema, child)
          :error -> Map.get(schema, "additionalProperties", true) != false
        end
      end)
  end

  defp valid_schema_value?(%{"type" => "array"} = schema, value) when is_list(value) do
    length = length(value)

    length >= Map.get(schema, "minItems", 0) and
      length <= Map.get(schema, "maxItems", length) and
      (Map.get(schema, "uniqueItems", false) == false or Enum.uniq(value) == value) and
      Enum.all?(value, &valid_schema_value?(schema["items"], &1))
  end

  defp valid_schema_value?(%{"type" => "string"} = schema, value) when is_binary(value) do
    length = Text.char_length(value)

    String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      length >= Map.get(schema, "minLength", 0) and
      length <= Map.get(schema, "maxLength", length) and
      valid_pattern?(value, schema["pattern"]) and valid_format?(value, schema["format"])
  end

  defp valid_schema_value?(%{"type" => "integer"} = schema, value) when is_integer(value) do
    value >= Map.get(schema, "minimum", value) and
      value <= Map.get(schema, "maximum", value)
  end

  defp valid_schema_value?(%{"type" => "boolean"}, value), do: is_boolean(value)
  defp valid_schema_value?(%{"type" => "null"}, value), do: is_nil(value)
  defp valid_schema_value?(schema, _value) when map_size(schema) == 0, do: true
  defp valid_schema_value?(_schema, _value), do: false

  defp issues(%{"anyOf" => schemas}, value, path) do
    if Enum.any?(schemas, &valid_schema_value?(&1, value)),
      do: [],
      else: branch_issues(schemas, value, path)
  end

  defp issues(%{"oneOf" => schemas} = schema, value, path) do
    base = Map.drop(schema, ["oneOf"])

    base_issues =
      if map_size(base) == 0 or Map.keys(base) == ["additionalProperties"],
        do: [],
        else: issues(base, value, path)

    case Enum.count(schemas, &valid_schema_value?(&1, value)) do
      1 -> base_issues
      0 -> base_issues ++ branch_issues(schemas, value, path)
      _many -> base_issues ++ [issue(path, "one_of", "matches more than one allowed shape")]
    end
  end

  defp issues(%{"const" => expected} = schema, value, path) do
    if value == expected,
      do: schema |> Map.delete("const") |> issues(value, path),
      else: [issue(path, "const", "must be #{Jason.encode!(expected)}")]
  end

  defp issues(%{"enum" => values} = schema, value, path) do
    if value in values,
      do: schema |> Map.delete("enum") |> issues(value, path),
      else: [issue(path, "enum", "must be one of " <> choices(values))]
  end

  defp issues(%{"properties" => _properties} = schema, value, path)
       when is_map(value) and not is_map_key(schema, "type") do
    object = Map.put(schema, "type", "object")
    issues(object, value, path)
  end

  defp issues(%{"type" => "object"} = schema, value, path) when is_map(value) do
    properties = Map.get(schema, "properties", %{})
    closed? = Map.get(schema, "additionalProperties", true) == false

    missing =
      for key <- Enum.sort(Map.get(schema, "required", [])),
          not Map.has_key?(value, key),
          do: issue(pointer(path, key), "required", "is required")

    present =
      value
      |> Enum.sort_by(fn {key, _child} -> key end)
      |> Enum.flat_map(fn {key, child} ->
        case Map.fetch(properties, key) do
          {:ok, child_schema} ->
            issues(child_schema, child, pointer(path, key))

          :error when closed? ->
            [issue(pointer(path, key), "additional_property", "is not allowed")]

          :error ->
            []
        end
      end)

    missing ++ present
  end

  defp issues(%{"type" => "array"} = schema, value, path) when is_list(value) do
    length = length(value)
    minimum = Map.get(schema, "minItems", 0)
    maximum = Map.get(schema, "maxItems", length)

    bounds =
      cond do
        length < minimum ->
          [issue(path, "min_items", "needs at least #{Wording.count(minimum, "item")}")]

        length > maximum ->
          [issue(path, "max_items", "takes at most #{Wording.count(maximum, "item")}")]

        Map.get(schema, "uniqueItems", false) and Enum.uniq(value) != value ->
          [issue(path, "unique_items", "repeats an item")]

        true ->
          []
      end

    items =
      value
      |> Enum.with_index()
      |> Enum.flat_map(fn {child, index} ->
        issues(schema["items"], child, pointer(path, Integer.to_string(index)))
      end)

    bounds ++ items
  end

  defp issues(%{"type" => "string"} = schema, value, path) when is_binary(value) do
    length = Text.char_length(value)
    minimum = Map.get(schema, "minLength", 0)
    maximum = Map.get(schema, "maxLength", length)

    cond do
      not String.valid?(value) or :binary.match(value, <<0>>) != :nomatch ->
        [issue(path, "invalid_text", "must be text without NUL bytes")]

      length < minimum ->
        [issue(path, "min_length", "needs at least #{Wording.count(minimum, "character")}")]

      length > maximum ->
        [issue(path, "max_length", "takes at most #{Wording.count(maximum, "character")}")]

      not valid_pattern?(value, schema["pattern"]) ->
        [issue(path, "pattern", "does not match its pattern")]

      not valid_format?(value, schema["format"]) ->
        [issue(path, "format", "must be a #{schema["format"]}")]

      true ->
        []
    end
  end

  defp issues(%{"type" => "integer"} = schema, value, path) when is_integer(value) do
    cond do
      value < Map.get(schema, "minimum", value) ->
        [issue(path, "minimum", "must be at least #{schema["minimum"]}")]

      value > Map.get(schema, "maximum", value) ->
        [issue(path, "maximum", "must be at most #{schema["maximum"]}")]

      true ->
        []
    end
  end

  defp issues(%{"type" => type} = schema, value, path) do
    if valid_schema_value?(schema, value),
      do: [],
      else: [issue(path, "type", "must be #{article(type)}")]
  end

  defp issues(schema, value, path) do
    if valid_schema_value?(schema, value),
      do: [],
      else: [issue(path, "invalid", "is not allowed here")]
  end

  # A value no branch takes is reported by the branch of its own type that it
  # comes closest to, by fewest issues (a too-long string under a nullable
  # string, or the proposal shape whose fields it nearly has); a value of no
  # branch's type is one issue naming the types it may be.
  defp branch_issues(schemas, value, path) do
    case Enum.filter(schemas, &(json_type(&1) == value_type(value))) do
      [] ->
        types = schemas |> Enum.map(&json_type/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
        [issue(path, "type", "must be " <> Enum.map_join(types, " or ", &article/1))]

      same_type ->
        same_type
        |> Enum.map(&issues(&1, value, path))
        |> Enum.min_by(&length/1)
    end
  end

  defp json_type(%{"type" => type}), do: type
  defp json_type(%{"properties" => _}), do: "object"
  defp json_type(%{"const" => value}), do: value_type(value)
  defp json_type(_schema), do: nil

  defp value_type(value) when is_map(value), do: "object"
  defp value_type(value) when is_list(value), do: "array"
  defp value_type(value) when is_binary(value), do: "string"
  defp value_type(value) when is_integer(value), do: "integer"
  defp value_type(value) when is_boolean(value), do: "boolean"
  defp value_type(nil), do: "null"
  defp value_type(_value), do: nil

  defp article("object"), do: "an object"
  defp article("array"), do: "an array"
  defp article("string"), do: "a string"
  defp article("integer"), do: "an integer"
  defp article("boolean"), do: "true or false"
  defp article("null"), do: "null"
  defp article(type), do: type

  # The allowed values, as the schema names them; a long list is cut.
  defp choices(values) when length(values) > 12,
    do: (values |> Enum.take(12) |> Enum.map_join(", ", &Jason.encode!/1)) <> ", …"

  defp choices(values), do: Enum.map_join(values, ", ", &Jason.encode!/1)

  defp issue(path, code, message),
    do: %{path: if(path == "", do: "/", else: path), code: code, message: message}

  defp pointer(path, key),
    do: path <> "/" <> (key |> String.replace("~", "~0") |> String.replace("/", "~1"))

  defp valid_pattern?(_value, nil), do: true

  defp valid_pattern?(value, pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.match?(regex, value)
      {:error, _reason} -> false
    end
  end

  defp valid_format?(_value, nil), do: true

  defp valid_format?(value, "date-time") do
    UTCDateTime.iso8601?(value)
  end

  defp valid_format?(_value, _format), do: false
end
