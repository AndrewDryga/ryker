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

  Go writes the float 1.0 as `1` where Jason writes `1.0`, so a float would
  give a digest the worker cannot reproduce (2026-10-04 review). Nothing Ryker
  sends a worker holds one, and a float here raises rather than mismatch.
  """
  @spec worker_digest(Jason.Encoder.t()) :: String.t()
  def worker_digest(value) do
    case float_path(value, "$") do
      nil -> :ok
      path -> raise ArgumentError, "a worker digest cannot hold a float at #{path}"
    end

    value
    |> encode!()
    |> String.replace("&", "\\u0026")
    |> String.replace("<", "\\u003c")
    |> String.replace(">", "\\u003e")
    |> String.replace(<<0x2028::utf8>>, "\\u2028")
    |> String.replace(<<0x2029::utf8>>, "\\u2029")
    |> Crypto.sha256_hex()
  end

  defp float_path(value, path) when is_float(value), do: path

  # A struct is no JSON object; encode!/1 refuses it with its own error.
  defp float_path(%_{}, _path), do: nil

  defp float_path(%{} = value, path) do
    Enum.find_value(value, fn {key, nested} -> float_path(nested, "#{path}.#{key}") end)
  end

  defp float_path(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.find_value(fn {nested, index} -> float_path(nested, "#{path}[#{index}]") end)
  end

  defp float_path(_value, _path), do: nil

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
