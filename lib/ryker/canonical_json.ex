defmodule Ryker.CanonicalJSON do
  @moduledoc """
  Produces one stable JSON representation for durable identities.

  Stable encoding lets a retry prove it is the same command without exposing a
  caller-supplied idempotency token.
  """
  alias Ryker.Crypto

  @doc """
  The SHA-256, in lowercase hex, of `value`'s canonical JSON (`encode!/1`);
  raises for a value canonical JSON cannot hold.
  """
  @spec digest(Jason.Encoder.t()) :: String.t()
  def digest(value) do
    value
    |> encode!()
    |> Crypto.sha256_hex()
  end

  @doc """
  SHA-256 over the sorted-key JSON representation used by Go's encoding/json.

  Go writes the float 1.0 as `1` where Jason writes `1.0` (2026-10-04 review),
  so each float is written here as Go writes it. Refusing floats instead
  stopped every Work turn of a task whose webhook JSON held one (2026-10-09).
  """
  @spec worker_digest(Jason.Encoder.t()) :: String.t()
  def worker_digest(value) do
    case order(value, "$") do
      {:ok, ordered} ->
        ordered
        |> go_floats()
        |> Jason.encode!()
        |> String.replace("&", "\\u0026")
        |> String.replace("<", "\\u003c")
        |> String.replace(">", "\\u003e")
        |> String.replace(<<0x2028::utf8>>, "\\u2028")
        |> String.replace(<<0x2029::utf8>>, "\\u2029")
        |> Crypto.sha256_hex()

      {:error, reason} ->
        raise ArgumentError, format_error(reason)
    end
  end

  defp go_floats(%Jason.OrderedObject{values: values} = object),
    do: %{object | values: Enum.map(values, fn {key, value} -> {key, go_floats(value)} end)}

  defp go_floats(values) when is_list(values), do: Enum.map(values, &go_floats/1)
  defp go_floats(value) when is_float(value), do: Jason.Fragment.new(go_float(value))
  defp go_floats(value), do: value

  # Go writes a float as ECMAScript does: its shortest digits that read back as
  # the same float, positional from 1e-6 up to 1e21 and with an exponent
  # (`1e-7`, `1.5e+21`) outside that, and a negative zero as `-0`.
  defp go_float(float) when float == 0.0 do
    <<sign::1, _rest::63>> = <<float::float>>
    if sign == 1, do: "-0", else: "0"
  end

  defp go_float(float) do
    {digits, exponent} = shortest_digits(abs(float))
    count = byte_size(digits)

    text =
      cond do
        count <= exponent and exponent <= 21 ->
          digits <> String.duplicate("0", exponent - count)

        exponent > 0 and exponent <= 21 ->
          binary_part(digits, 0, exponent) <>
            "." <> binary_part(digits, exponent, count - exponent)

        exponent > -6 and exponent <= 0 ->
          "0." <> String.duplicate("0", -exponent) <> digits

        true ->
          scientific(digits, exponent - 1)
      end

    if float < 0, do: "-" <> text, else: text
  end

  # The float as 0.`digits` x 10^exponent, `digits` with no leading or
  # trailing zero, from Erlang's shortest round-trip text ("1.25e-7").
  defp shortest_digits(float) do
    {mantissa, power} =
      case String.split(:erlang.float_to_binary(float, [:short]), "e") do
        [mantissa, power] -> {mantissa, String.to_integer(power)}
        [mantissa] -> {mantissa, 0}
      end

    [whole, fraction] = String.split(mantissa, ".")
    all = whole <> fraction
    trimmed = String.trim_leading(all, "0")
    leading = byte_size(all) - byte_size(trimmed)
    {String.trim_trailing(trimmed, "0"), byte_size(whole) + power - leading}
  end

  defp scientific(<<first::binary-size(1)>>, power), do: first <> "e" <> signed(power)

  defp scientific(<<first::binary-size(1), rest::binary>>, power),
    do: first <> "." <> rest <> "e" <> signed(power)

  defp signed(power) when power < 0, do: Integer.to_string(power)
  defp signed(power), do: "+" <> Integer.to_string(power)

  @truncation_marker "...<truncated>..."

  @doc """
  `value` itself when its encoding fits in `maximum` bytes, else the head and
  tail of that encoding around a marker, with its size and digest.

  A briefing keeps a long record this way and the record's check rebuilds the
  same preview to compare, so both use this one function: the rule was copied
  three times, and a drift would have marked every briefing with a long record
  stale (2026-10-04 review). The slices drop a character they would split, so
  a preview can be a few bytes short; the digest is its identity.
  """
  @spec bounded(term(), pos_integer()) :: term()
  def bounded(nil, _maximum), do: nil

  def bounded(value, maximum) do
    encoded = encode!(value)

    if byte_size(encoded) <= maximum do
      value
    else
      available = maximum - byte_size(@truncation_marker)
      head_bytes = div(available, 2)
      tail_bytes = available - head_bytes

      %{
        "json_preview" =>
          String.byte_slice(encoded, 0, head_bytes) <>
            @truncation_marker <> String.byte_slice(encoded, -tail_bytes, tail_bytes),
        "original_bytes" => byte_size(encoded),
        "sha256" => Crypto.sha256_hex(encoded),
        "truncated" => true
      }
    end
  end

  @doc """
  `value` as canonical JSON: keys sorted, one spelling for each value. Raises
  for a duplicate or non-string key, or a value JSON cannot hold.
  """
  @spec encode!(Jason.Encoder.t()) :: String.t()
  def encode!(value) do
    case encode(value) do
      {:ok, encoded} -> encoded
      {:error, reason} -> raise ArgumentError, format_error(reason)
    end
  end

  @doc """
  Whether `value` encodes as canonical JSON within `max_bytes` when given:
  `:ok`, `{:error, {:too_large, bytes, max_bytes}}`, or `{:error, reason}`
  naming the key or value that cannot be encoded.
  """
  @spec validate(term(), keyword()) :: :ok | {:error, term()}
  def validate(value, options \\ []) do
    max_bytes = Keyword.get(options, :max_bytes)

    with {:ok, encoded} <- encode(value) do
      within_limit(encoded, max_bytes)
    end
  end

  defp encode(value) do
    with {:ok, ordered} <- order(value, "$"),
         {:ok, encoded} <- Jason.encode(ordered) do
      {:ok, encoded}
    else
      {:error, %Jason.EncodeError{} = error} ->
        {:error, {:encoding_failed, Exception.message(error)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp order(%{} = value, path) do
    case Enum.find(Map.keys(value), &invalid_object_key?/1) do
      nil ->
        entries = Enum.map(value, fn {key, nested} -> {to_string(key), key, nested} end)

        case duplicate_key(entries) do
          nil -> order_entries(entries, path)
          key -> {:error, {:duplicate_key, path, key}}
        end

      invalid_key ->
        {:error, {:invalid_json_key, path, kind(invalid_key)}}
    end
  end

  defp order(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {nested, index}, {:ok, values} ->
      case order(nested, "#{path}[#{index}]") do
        {:ok, ordered} -> {:cont, {:ok, [ordered | values]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp order(value, path) when is_binary(value) do
    if jsonb_string?(value),
      do: {:ok, value},
      else: {:error, {:invalid_json_value, path, kind(value)}}
  end

  defp order(value, _path)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp order(value, path), do: {:error, {:invalid_json_value, path, kind(value)}}

  # An error says what kind of value it refused, never the value: one carried
  # it, and the raised message printed it, so a secret with a NUL byte or
  # invalid UTF-8 in it reached the logs whole (2026-10-04 review).
  defp kind(value) when is_binary(value),
    do: if(String.valid?(value), do: :string_with_nul, else: :invalid_utf8)

  defp kind(value) when is_atom(value), do: :atom
  defp kind(value) when is_tuple(value), do: :tuple
  defp kind(value) when is_pid(value), do: :pid
  defp kind(value) when is_reference(value), do: :reference
  defp kind(value) when is_function(value), do: :function
  defp kind(_value), do: :unsupported

  defp order_entries(entries, path) do
    entries
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {normalized_key, original_key, nested}, {:ok, values} ->
      case order_entry(normalized_key, original_key, nested, path) do
        {:ok, ordered} -> {:cont, {:ok, [{normalized_key, ordered} | values]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, values |> Enum.reverse() |> Jason.OrderedObject.new()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp order_entry(_normalized_key, original_key, _nested, path)
       when not is_binary(original_key),
       do: {:error, {:invalid_json_key, path, kind(original_key)}}

  defp order_entry(normalized_key, _original_key, nested, path),
    do: order(nested, "#{path}.#{normalized_key}")

  defp duplicate_key(entries) do
    entries
    |> Enum.frequencies_by(&elem(&1, 0))
    |> Enum.find_value(fn {key, count} -> if count > 1, do: key end)
  end

  defp invalid_object_key?(key) when is_binary(key), do: not jsonb_string?(key)
  defp invalid_object_key?(key) when is_atom(key), do: false
  defp invalid_object_key?(_key), do: true

  defp jsonb_string?(value) do
    String.valid?(value) and :binary.match(value, <<0>>) == :nomatch
  end

  defp within_limit(_encoded, nil), do: :ok
  defp within_limit(encoded, max_bytes) when byte_size(encoded) <= max_bytes, do: :ok
  defp within_limit(encoded, max_bytes), do: {:error, {:too_large, byte_size(encoded), max_bytes}}

  defp format_error({:duplicate_key, path, key}),
    do: "duplicate JSON key #{inspect(key)} at #{path}"

  defp format_error({:invalid_json_key, path, kind}),
    do: "invalid JSON key (#{described(kind)}) at #{path}"

  defp format_error({:invalid_json_value, path, kind}),
    do: "invalid JSON value (#{described(kind)}) at #{path}"

  defp format_error({:encoding_failed, message}), do: "JSON encoding failed: #{message}"

  defp described(:string_with_nul), do: "a string with a NUL byte"
  defp described(:invalid_utf8), do: "a string that is not UTF-8"
  defp described(:atom), do: "an atom"
  defp described(:unsupported), do: "a value JSON has no form for"
  defp described(kind), do: "a #{kind}"
end
