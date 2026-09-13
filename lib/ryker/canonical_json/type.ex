defmodule Ryker.CanonicalJSON.Type do
  @moduledoc """
  Stores canonical JSON as text while exposing ordinary decoded values.

  PostgreSQL JSONB normalizes some numbers and would make a reloaded immutable
  command differ from the bytes the kernel fingerprinted.
  """

  use Ecto.Type

  alias Ryker.CanonicalJSON

  @impl true
  def type, do: :string

  @impl true
  def cast(value) do
    case CanonicalJSON.validate(value) do
      :ok -> {:ok, value}
      {:error, _reason} -> :error
    end
  end

  @impl true
  def dump(value) do
    case CanonicalJSON.validate(value) do
      :ok -> {:ok, CanonicalJSON.encode!(value)}
      {:error, _reason} -> :error
    end
  end

  @impl true
  def load(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> :error
    end
  end

  def load(_value), do: :error
end
