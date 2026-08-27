defmodule Responder.CanonicalJSON do
  @moduledoc """
  Produces one stable JSON representation for durable identities.

  Stable encoding lets a retry prove it is the same command without exposing a
  caller-supplied idempotency token.
  """

  @spec digest(Jason.Encoder.t()) :: String.t()
  def digest(value) do
    value
    |> encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec encode!(Jason.Encoder.t()) :: String.t()
  def encode!(value) do
    case encode(value) do
      {:ok, encoded} -> encoded
      {:error, reason} -> raise ArgumentError, format_error(reason)
    end
  end

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
        {:error, {:invalid_json_key, path, invalid_key}}
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
      else: {:error, {:invalid_json_value, path, value}}
  end

  defp order(value, _path)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp order(value, path), do: {:error, {:invalid_json_value, path, value}}

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
       do: {:error, {:invalid_json_key, path, original_key}}

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

  defp format_error({:invalid_json_key, path, key}),
    do: "invalid JSON key #{inspect(key)} at #{path}"

  defp format_error({:invalid_json_value, path, value}),
    do: "invalid JSON value #{inspect(value)} at #{path}"

  defp format_error({:encoding_failed, message}), do: "JSON encoding failed: #{message}"
end
