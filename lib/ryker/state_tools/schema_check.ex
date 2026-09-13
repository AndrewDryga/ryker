defmodule Ryker.StateTools.SchemaCheck do
  @moduledoc false

  # Validates tool arguments against the exact JSON-schema subset the catalog
  # emits (anyOf, oneOf, const, enum, object, array, string, integer, boolean,
  # null). The catalog is the one the caller advertised, so a tool it withheld
  # is not configured here either.

  alias Ryker.StateTools.Catalog

  @spec exact_schema(String.t(), map(), [map()]) :: :ok | {:error, atom()}
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

  defp schema_error("propose_automation", %{"proposals" => proposals}, _schema)
       when is_list(proposals) do
    if Enum.any?(proposals, &unsupported_automation_source?/1),
      do: {:error, :invalid_automation_source},
      else: {:error, :invalid_arguments}
  end

  defp schema_error(_name, _arguments, _schema), do: {:error, :invalid_arguments}

  defp unsupported_automation_source?(%{"trigger" => %{"type" => "source_event"} = trigger}),
    do: trigger["source_kind"] not in Catalog.source_kinds()

  defp unsupported_automation_source?(_proposal), do: false

  defp valid_schema_value?(%{"anyOf" => schemas}, value),
    do: Enum.any?(schemas, &valid_schema_value?(&1, value))

  defp valid_schema_value?(%{"oneOf" => schemas} = schema, value) do
    base = Map.drop(schema, ["oneOf"])

    base_valid =
      map_size(base) == 0 or Map.keys(base) == ["additionalProperties"] or
        valid_schema_value?(base, value)

    base_valid and Enum.count(schemas, &valid_schema_value?(&1, value)) == 1
  end

  defp valid_schema_value?(%{"const" => expected} = schema, value),
    do: value == expected and valid_schema_value?(Map.drop(schema, ["const"]), value)

  defp valid_schema_value?(%{"enum" => values} = schema, value),
    do: value in values and valid_schema_value?(Map.drop(schema, ["enum"]), value)

  defp valid_schema_value?(%{"properties" => _properties} = schema, value)
       when is_map(value) and not is_map_key(schema, "type"),
       do: valid_schema_value?(Map.put(schema, "type", "object"), value)

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
    length = String.length(value)

    String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      length >= Map.get(schema, "minLength", 0) and
      length <= Map.get(schema, "maxLength", length) and
      valid_pattern?(value, schema["pattern"]) and valid_format?(value, schema["format"])
  end

  defp valid_schema_value?(%{"type" => "integer"} = schema, value) when is_integer(value),
    do:
      value >= Map.get(schema, "minimum", value) and
        value <= Map.get(schema, "maximum", value)

  defp valid_schema_value?(%{"type" => "boolean"}, value), do: is_boolean(value)
  defp valid_schema_value?(%{"type" => "null"}, value), do: is_nil(value)
  defp valid_schema_value?(schema, _value) when map_size(schema) == 0, do: true
  defp valid_schema_value?(_schema, _value), do: false

  defp valid_pattern?(_value, nil), do: true

  defp valid_pattern?(value, pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.match?(regex, value)
      {:error, _reason} -> false
    end
  end

  defp valid_format?(_value, nil), do: true

  defp valid_format?(value, "date-time") do
    match?({:ok, %DateTime{}, 0}, DateTime.from_iso8601(value))
  end

  defp valid_format?(_value, _format), do: false
end
