defmodule Ryker.Delivery.ReactionPublisher do
  @moduledoc """
  Narrow platform port for one durable emoji reaction.
  """
  alias Ryker.Delivery.Request

  @callback publish_reaction(Request.t(), term()) :: {:ok, map()} | {:error, term()}
  @callback publish_reaction(Request.t(), term(), Ryker.Delivery.MessagePublisher.before_write()) ::
              {:ok, map()} | {:error, term()}
  @optional_callbacks publish_reaction: 3
end
