defmodule Responder.State.KnowledgeUpdate do
  @moduledoc "Bounded proposal to maintain one topic; the host supplies ownership and sources."
  alias Responder.State.Observations
  @fields ~w(topic_key title summary topics target_ref expected_version)

  def prepare(nil), do: {:ok, nil}

  def prepare(%{} = value) do
    with true <- Enum.sort(Map.keys(value)) == Enum.sort(@fields),
         true <- text?(value["title"], 160),
         true <-
           is_binary(value["topic_key"]) and
             Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,159}\z/, value["topic_key"]),
         {:ok, _} <- Observations.prepare(Map.take(value, ~w(summary topics))),
         true <- target?(value["target_ref"], value["expected_version"]) do
      {:ok, value}
    else
      _ -> {:error, {:invalid_decision, :knowledge}}
    end
  end

  def prepare(_), do: {:error, {:invalid_decision, :knowledge}}

  def json_schema do
    note = Observations.json_schema()["anyOf"] |> List.last() |> Map.fetch!("properties")

    %{
      "anyOf" => [
        %{"type" => "null"},
        %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => @fields,
          "properties" => %{
            "topic_key" => %{
              "type" => "string",
              "maxLength" => 160,
              "pattern" => "^[a-z0-9][a-z0-9-]{0,159}$"
            },
            "title" => Map.put(note["summary"], "maxLength", 160),
            "summary" => note["summary"],
            "topics" => note["topics"],
            "target_ref" => %{
              "anyOf" => [
                %{"type" => "null"},
                %{
                  "type" => "string",
                  "pattern" =>
                    "^knowledge:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
                }
              ]
            },
            "expected_version" => %{"type" => "integer", "minimum" => 0}
          },
          "oneOf" => [
            %{
              "properties" => %{
                "target_ref" => %{"type" => "null"},
                "expected_version" => %{"const" => 0}
              }
            },
            %{
              "properties" => %{
                "target_ref" => %{"type" => "string"},
                "expected_version" => %{"minimum" => 1}
              }
            }
          ]
        }
      ]
    }
  end

  defp target?(nil, 0), do: true

  defp target?("knowledge:" <> id, version) when is_integer(version) and version > 0,
    do: Ecto.UUID.cast(id) == {:ok, id}

  defp target?(_, _), do: false

  defp text?(value, max),
    do:
      is_binary(value) and String.valid?(value) and
        String.length(value) <= max and String.trim(value) != "" and
        not String.contains?(value, <<0>>)
end
