defmodule Ryker.Webhooks.Input do
  @moduledoc """
  Converts arbitrary webhook JSON into a source-neutral ingress input.

  The payload is data only. Route configuration supplies identity, capabilities,
  and delivery destination.
  """
  @behaviour Ryker.Ingress.Adapter
  alias Ryker.CanonicalJSON
  alias Ryker.Ingress
  alias Ryker.Maps
  alias Ryker.Reference
  alias Ryker.UTCDateTime
  alias Ryker.Webhooks.Route

  @maximum_revision 9_223_372_036_854_775_807
  @metadata_fields [
    :event_id,
    :event_type,
    :item_id,
    :occurred_at,
    :occurred_at_source,
    :revision
  ]

  @spec new(Route.t(), term(), keyword() | map()) :: {:ok, Ingress.Input.t()} | {:error, term()}
  def new(%Route{} = route, payload, metadata) do
    with {:ok, metadata} <- normalize_metadata(metadata),
         :ok <- validate_metadata(metadata) do
      Ingress.Input.new(%{
        actor: %{kind: :system, ref: route.name},
        content: %{"event_type" => metadata.event_type, "payload" => payload},
        destination: route.destination,
        event_kind: :event,
        event_ref: metadata.event_id,
        native_input_id: native_input_id(route.name, metadata.item_id),
        occurred_at: metadata.occurred_at,
        occurred_at_source: metadata.occurred_at_source,
        revision: metadata.revision,
        source: %{kind: "webhook", ref: route.name},
        source_capabilities: source_capabilities(route),
        source_item_ref: nil
      })
    end
  end

  def new(_route, _payload, _metadata), do: {:error, {:invalid_webhook_input, :route}}

  @impl Ryker.Ingress.Adapter
  def source_kind, do: "webhook"

  @impl Ryker.Ingress.Adapter
  def normalize(%{metadata: metadata, payload: payload} = event, %Route{} = route)
      when map_size(event) == 2,
      do: new(route, payload, metadata)

  def normalize(_event, _binding), do: {:error, {:invalid_webhook_input, :adapter_event}}

  defp normalize_metadata(metadata) when is_list(metadata) do
    if Keyword.keyword?(metadata) and
         Enum.uniq(Keyword.keys(metadata)) == Keyword.keys(metadata) do
      metadata |> Map.new() |> normalize_metadata()
    else
      {:error, {:invalid_webhook_input, :fields}}
    end
  end

  defp normalize_metadata(%{} = metadata) do
    metadata = Map.put_new(metadata, :item_id, metadata[:event_id])

    if Maps.exact_keys?(metadata, @metadata_fields),
      do: {:ok, metadata},
      else: {:error, {:invalid_webhook_input, :fields}}
  end

  defp normalize_metadata(_metadata), do: {:error, {:invalid_webhook_input, :fields}}

  defp validate_metadata(metadata) do
    validations = [
      {Reference.valid?(metadata.event_id, 1_024), :event_id},
      {is_nil(metadata.event_type) or Reference.valid?(metadata.event_type, 256), :event_type},
      {Reference.valid?(metadata.item_id, 1_024), :item_id},
      {UTCDateTime.utc?(metadata.occurred_at), :occurred_at},
      {metadata.occurred_at_source in [:source, :ingress], :occurred_at_source},
      {is_integer(metadata.revision) and metadata.revision > 0 and
         metadata.revision <= @maximum_revision, :revision}
    ]

    Enum.reduce_while(validations, :ok, fn
      {true, _field}, :ok -> {:cont, :ok}
      {false, field}, :ok -> {:halt, {:error, {:invalid_webhook_input, field}}}
    end)
  end

  defp native_input_id(route_name, item_id) do
    "webhook-item:" <> CanonicalJSON.digest([route_name, item_id])
  end

  defp source_capabilities(%Route{publication_lifecycle: nil}), do: %{}

  defp source_capabilities(%Route{publication_lifecycle: scope}) do
    %{
      "publication_lifecycle" => %{
        "environments" => scope.environments,
        "kinds" => scope.kinds,
        "repositories" => scope.repositories,
        "targets" => scope.targets
      }
    }
  end
end
