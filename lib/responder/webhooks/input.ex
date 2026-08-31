defmodule Responder.Webhooks.Input do
  @moduledoc """
  Converts arbitrary webhook JSON into a source-neutral ingress input.

  The payload is data only. Route configuration supplies identity, capabilities,
  and delivery destination.
  """

  alias Responder.CanonicalJSON
  alias Responder.Ingress.Input
  alias Responder.Webhooks.Route

  @behaviour Responder.Ingress.Adapter

  @maximum_revision 9_223_372_036_854_775_807
  @metadata_fields [
    :event_id,
    :event_type,
    :item_id,
    :occurred_at,
    :occurred_at_source,
    :revision
  ]

  @spec new(Route.t(), term(), keyword() | map()) :: {:ok, Input.t()} | {:error, term()}
  def new(%Route{} = route, payload, metadata) do
    with {:ok, metadata} <- normalize_metadata(metadata),
         :ok <- validate_metadata(metadata) do
      Input.new(%{
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
        source_capabilities: %{},
        source_item_ref: nil
      })
    end
  end

  def new(_route, _payload, _metadata), do: {:error, {:invalid_webhook_input, :route}}

  @impl Responder.Ingress.Adapter
  def source_kind, do: "webhook"

  @impl Responder.Ingress.Adapter
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

    if Map.keys(metadata) |> Enum.sort() == Enum.sort(@metadata_fields),
      do: {:ok, metadata},
      else: {:error, {:invalid_webhook_input, :fields}}
  end

  defp normalize_metadata(_metadata), do: {:error, {:invalid_webhook_input, :fields}}

  defp validate_metadata(metadata) do
    validations = [
      {reference?(metadata.event_id, 1_024), :event_id},
      {is_nil(metadata.event_type) or reference?(metadata.event_type, 256), :event_type},
      {reference?(metadata.item_id, 1_024), :item_id},
      {utc_datetime?(metadata.occurred_at), :occurred_at},
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

  defp reference?(value, maximum) do
    is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      String.trim(value) != "" and byte_size(value) <= maximum
  end

  defp utc_datetime?(%DateTime{} = value) do
    value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0
  end

  defp utc_datetime?(_value), do: false
end
