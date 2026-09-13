defmodule Ryker.Delivery.Adapters do
  @moduledoc """
  Explicit trusted registry for outbound platform publishers.

  Transport names come from durable host routing, but are never converted to
  atoms or module names. Only modules supplied by trusted runtime
  configuration can execute a delivery.
  """

  alias Ryker.Delivery.Request

  @fields [:binding, :message_publisher, :reaction_publisher]

  @spec new(map()) :: {:ok, map()} | {:error, term()}
  def new(registrations) when is_map(registrations) and map_size(registrations) > 0 do
    Enum.reduce_while(registrations, {:ok, %{}}, fn {transport, registration}, {:ok, result} ->
      case prepare_registration(transport, registration) do
        {:ok, prepared} -> {:cont, {:ok, Map.put(result, transport, prepared)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def new(_registrations), do: {:error, {:invalid_delivery_adapters, :registrations}}

  @spec publish(Request.t(), map()) :: {:ok, map()} | {:error, term()}
  def publish(%Request{} = request, registrations) when is_map(registrations) do
    with {:ok, registration} <- fetch_registration(registrations, request.transport) do
      publish_request(request, registration)
    end
  end

  def publish(_request, _registrations),
    do: {:error, {:invalid_delivery_adapters, :request}}

  @spec update_message(Request.t(), String.t(), map(), map()) :: :ok | {:error, term()}
  def update_message(%Request{kind: :message} = request, message_ref, document, registrations)
      when is_binary(message_ref) and is_map(document) and is_map(registrations) do
    with {:ok, registration} <- fetch_registration(registrations, request.transport) do
      if function_exported?(registration.message_publisher, :update_message, 4) do
        registration.message_publisher.update_message(
          request,
          message_ref,
          document,
          registration.binding
        )
      else
        {:error, {:delivery_message_update_not_supported, request.transport}}
      end
    end
  end

  def update_message(_request, _message_ref, _document, _registrations),
    do: {:error, {:invalid_delivery_adapters, :message_update}}

  defp prepare_registration(transport, %{} = registration) do
    if Map.keys(registration) |> Enum.sort() == Enum.sort(@fields) and transport?(transport) do
      with :ok <- publisher(registration.message_publisher, transport, :message),
           :ok <- publisher(registration.reaction_publisher, transport, :reaction) do
        {:ok, registration}
      end
    else
      {:error, {:invalid_delivery_adapters, :registration}}
    end
  end

  defp prepare_registration(_transport, _registration),
    do: {:error, {:invalid_delivery_adapters, :registration}}

  defp publisher(module, transport, kind) when is_atom(module) do
    callback = if kind == :message, do: :publish_message, else: :publish_reaction

    if Code.ensure_loaded?(module) and function_exported?(module, :transport, 0) and
         function_exported?(module, callback, 2) and module.transport() == transport,
       do: :ok,
       else: {:error, {:invalid_delivery_adapters, kind}}
  end

  defp publisher(_module, _transport, kind),
    do: {:error, {:invalid_delivery_adapters, kind}}

  defp fetch_registration(registrations, transport) do
    case Map.fetch(registrations, transport) do
      {:ok, registration} -> {:ok, registration}
      :error -> {:error, {:delivery_adapter_not_configured, transport}}
    end
  end

  defp publish_request(%Request{kind: :message} = request, registration) do
    registration.message_publisher.publish_message(request, registration.binding)
  end

  defp publish_request(%Request{kind: :reaction} = request, registration) do
    registration.reaction_publisher.publish_reaction(request, registration.binding)
  end

  defp transport?(value),
    do: is_binary(value) and Regex.match?(~r/\A[a-z][a-z0-9_-]{0,63}\z/, value)
end
