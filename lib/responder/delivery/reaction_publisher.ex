defmodule Responder.Delivery.ReactionPublisher do
  @moduledoc """
  Narrow platform port for one durable emoji reaction.
  """

  alias Responder.Delivery.Request

  @callback publish_reaction(Request.t(), term()) :: {:ok, map()} | {:error, term()}
end
