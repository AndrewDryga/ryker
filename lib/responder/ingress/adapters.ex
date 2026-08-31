defmodule Responder.Ingress.Adapters do
  @moduledoc """
  The explicit registry of authenticated platform adapters.

  Source identifiers stay bounded strings. No event-controlled value is ever
  converted to an atom or used to resolve a module dynamically.
  """

  alias Responder.Ingress.Input

  @default %{
    "github" => Responder.GitHub.Input,
    "slack" => Responder.Slack.Input,
    "webhook" => Responder.Webhooks.Input
  }

  @spec default() :: %{String.t() => module()}
  def default, do: @default

  @spec prepare(term()) :: {:ok, %{String.t() => module()}} | {:error, term()}
  def prepare(%{} = adapters) do
    adapters
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {kind, adapter}, {:ok, prepared} ->
      if valid_adapter?(kind, adapter) do
        {:cont, {:ok, Map.put(prepared, kind, adapter)}}
      else
        {:halt, {:error, {:invalid_ingress_adapter, kind}}}
      end
    end)
  end

  def prepare(_adapters), do: {:error, {:invalid_ingress_adapters, :registry}}

  @spec normalize(String.t(), term(), term(), %{String.t() => module()}) ::
          {:ok, Input.t()} | {:error, term()}
  def normalize(kind, event, binding, adapters \\ @default)

  def normalize(kind, event, binding, adapters) when is_binary(kind) do
    case Map.fetch(adapters, kind) do
      {:ok, adapter} -> normalize_with(adapter, kind, event, binding)
      :error -> {:error, {:unknown_ingress_adapter, kind}}
    end
  end

  def normalize(kind, _event, _binding, _adapters),
    do: {:error, {:unknown_ingress_adapter, kind}}

  defp normalize_with(adapter, kind, event, binding) do
    case adapter.normalize(event, binding) do
      {:ok, %Input{source: %{kind: ^kind}} = input} ->
        {:ok, input}

      {:ok, %Input{}} ->
        {:error, {:invalid_ingress_adapter_output, kind, :source_kind}}

      {:error, _reason} = error ->
        error

      _other ->
        {:error, {:invalid_ingress_adapter_output, kind, :result}}
    end
  end

  defp valid_adapter?(kind, adapter) do
    is_binary(kind) and is_atom(adapter) and Code.ensure_loaded?(adapter) and
      function_exported?(adapter, :source_kind, 0) and
      function_exported?(adapter, :normalize, 2) and adapter.source_kind() == kind
  end
end
