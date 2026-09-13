defmodule Ryker.Evals.Evidence do
  @moduledoc false

  alias Ryker.CanonicalJSON

  @default_maximum_bytes 32 * 1_024
  @sensitive_key ~r/(?:authorization|cookie|credential|password|private.?key|secret|token)/i

  @spec sanitize(term(), pos_integer()) :: term()
  def sanitize(value, maximum_bytes \\ @default_maximum_bytes)

  def sanitize(value, maximum_bytes) when is_integer(maximum_bytes) and maximum_bytes > 0 do
    scrubbed = scrub(value)
    encoded = CanonicalJSON.encode!(scrubbed)

    if byte_size(encoded) <= maximum_bytes do
      scrubbed
    else
      %{
        "bytes" => byte_size(encoded),
        "sha256" => sha256(encoded),
        "truncated" => true
      }
    end
  end

  defp scrub(%{} = value) do
    Map.new(value, fn {key, item} ->
      key = to_string(key)
      {key, if(Regex.match?(@sensitive_key, key), do: "[REDACTED]", else: scrub(item))}
    end)
  end

  defp scrub(value) when is_list(value), do: Enum.map(value, &scrub/1)

  defp scrub(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp scrub(value), do: value

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
