defmodule Ryker.Knowledge.KnowledgeUpdate do
  @moduledoc "Bounded proposal to maintain one topic; the host supplies ownership and sources."
  alias Ryker.JSONSchema
  alias Ryker.Reference

  @fields ~w(topic_key title summary topics anchors target_ref expected_version)

  def prepare(nil), do: {:ok, nil}

  def prepare(%{} = value) do
    with true <- Enum.sort(Map.keys(value)) == Enum.sort(@fields),
         true <- Reference.text?(value["title"], 160),
         true <-
           is_binary(value["topic_key"]) and
             Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,159}\z/, value["topic_key"]),
         true <- Reference.text?(value["summary"], 1200),
         true <- topics?(value["topics"]),
         true <- anchors?(value["anchors"]),
         true <- target?(value["target_ref"], value["expected_version"]) do
      {:ok, value}
    else
      _ -> {:error, {:invalid_decision, :knowledge}}
    end
  end

  def prepare(_), do: {:error, {:invalid_decision, :knowledge}}

  def json_schema do
    note = %{
      "summary" => JSONSchema.text(1200),
      "topics" => %{
        "type" => "array",
        "maxItems" => 8,
        "uniqueItems" => true,
        "items" => JSONSchema.text(80)
      }
    }

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
            "anchors" => %{
              "type" => "array",
              "maxItems" => 8,
              "uniqueItems" => true,
              "items" => %{
                "type" => "string",
                "minLength" => 1,
                "maxLength" => 512,
                "pattern" => "^[!-~]{1,512}$"
              }
            },
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

  defp anchors?(anchors) when is_list(anchors) do
    length(anchors) <= 8 and Enum.uniq(anchors) == anchors and
      Enum.all?(anchors, &(is_binary(&1) and Regex.match?(~r/\A[!-~]{1,512}\z/, &1)))
  end

  defp anchors?(_), do: false

  defp topics?(topics) when is_list(topics) do
    length(topics) <= 8 and Enum.uniq(topics) == topics and
      Enum.all?(topics, &Reference.text?(&1, 80))
  end

  defp topics?(_), do: false
end
