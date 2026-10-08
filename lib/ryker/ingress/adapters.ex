defmodule Ryker.Ingress.Adapters do
  @moduledoc """
  The explicit registry of authenticated platform adapters.

  Source identifiers stay bounded strings. No event-controlled value is ever
  converted to an atom or used to resolve a module dynamically.
  """
  alias Ryker.Ingress.Input

  @default %{
    "github" => Ryker.GitHub.Input,
    "slack" => Ryker.Slack.Input,
    "webhook" => Ryker.Webhooks.Input
  }

  @spec default() :: %{String.t() => module()}
  def default, do: @default

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

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, {:invalid_ingress_adapter_output, kind, :result}}
    end
  end
end
