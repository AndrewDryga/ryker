defmodule Ryker.Evals.Evidence do
  @moduledoc false
  alias Ryker.CanonicalJSON
  alias Ryker.Crypto

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
        "sha256" => Crypto.sha256_hex(encoded),
        "truncated" => true
      }
    end
  end

  @doc """
  A stored row as a report shows it: every schema field under its name, times
  in ISO 8601 and enum values as strings. The learning eval and its probe each
  had a copy (2026-10-04 review).
  """
  @spec record(struct()) :: %{String.t() => term()}
  def record(%{__struct__: schema} = row) do
    row
    |> Map.take(schema.__schema__(:fields))
    |> Map.new(fn {key, value} -> {Atom.to_string(key), printable(value)} end)
  end

  defp printable(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp printable(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp printable(value), do: value

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
end
