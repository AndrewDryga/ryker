defmodule Ryker.Slack.EmojiCatalog do
  @moduledoc "Bounded custom emoji names and aliases for conversation context; image URLs stay out."
  alias Ryker.CanonicalJSON

  @maximum_names 256
  @maximum_bytes 8192
  @name ~r/\A[a-z0-9_+\-]{1,80}\z/

  @doc "The model's bounded vocabulary from an emoji.list name-to-image-or-alias map."
  @spec document(map()) :: map()
  def document(emoji) when is_map(emoji) do
    valid = Enum.filter(emoji, fn {name, value} -> valid_name?(name) and is_binary(value) end)

    selected =
      valid
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.take(@maximum_names)
      |> Enum.reduce_while(%{"names" => [], "aliases" => %{}, "truncated" => false}, fn {name,
                                                                                         value},
                                                                                        document ->
        candidate = %{
          document
          | "names" => document["names"] ++ [name],
            "aliases" => with_alias(document["aliases"], name, value)
        }

        if byte_size(CanonicalJSON.encode!(candidate)) <= @maximum_bytes,
          do: {:cont, candidate},
          else: {:halt, document}
      end)

    %{selected | "truncated" => length(valid) > length(selected["names"])}
  end

  defp with_alias(aliases, name, "alias:" <> target) do
    if valid_name?(target), do: Map.put(aliases, name, target), else: aliases
  end

  defp with_alias(aliases, _name, _value), do: aliases

  defp valid_name?(value), do: is_binary(value) and Regex.match?(@name, value)
end
