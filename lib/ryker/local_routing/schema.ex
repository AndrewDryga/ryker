defmodule Ryker.LocalRouting.Schema do
  @moduledoc """
  Routing's response contract (`Ryker.Admission.Decision.json_schema/4`) in
  the form a local model server can hold an answer to.

  The contract states its fields once and each allowed shape of a decision in
  a top-level `oneOf` beside them. A grammar-constrained server, such as
  llama.cpp under Ollama, builds its grammar from the `oneOf` alone, so every
  shape would lose the fields it does not repeat (the reason among them) and
  every answer would be refused for a missing field. Here each shape is the
  whole object: every field, the shape's own constraints over the shared
  ones, all of them required and nothing else allowed. The shapes exclude one
  another, so `anyOf` says the same as `oneOf` and is the form these servers
  read. Text patterns are left out, since local grammars refuse or misread
  them; routing's own checks, which every answer goes through, enforce them
  (`Ryker.LocalRouting.Verdict`).
  """

  @spec local(map()) :: map()
  def local(%{"oneOf" => shapes, "properties" => properties, "required" => required})
      when is_list(shapes) and is_map(properties) and is_list(required) do
    %{
      "anyOf" =>
        Enum.map(shapes, fn shape ->
          portable(%{
            "additionalProperties" => false,
            "properties" => Map.merge(properties, Map.get(shape, "properties", %{})),
            "required" => required,
            "type" => "object"
          })
        end)
    }
  end

  # A key of `properties` names a field, never a keyword, so only its value
  # is rewritten.
  defp portable(%{} = schema) do
    schema
    |> Map.drop(["$schema", "pattern", "title"])
    |> Map.new(fn
      {"oneOf", alternatives} -> {"anyOf", portable(alternatives)}
      {"properties", fields} -> {"properties", Map.new(fields, fn {k, v} -> {k, portable(v)} end)}
      {key, value} -> {key, portable(value)}
    end)
  end

  defp portable(list) when is_list(list), do: Enum.map(list, &portable/1)
  defp portable(value), do: value
end
