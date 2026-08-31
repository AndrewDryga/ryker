defmodule Responder.Delivery.MessagePublisher do
  @moduledoc """
  Narrow platform port for one durable visible message.
  """

  alias Responder.Delivery.Request

  @callback publish_message(Request.t(), term()) :: {:ok, map()} | {:error, term()}
  @callback update_message(Request.t(), String.t(), map(), term()) :: :ok | {:error, term()}

  @optional_callbacks update_message: 4
end
