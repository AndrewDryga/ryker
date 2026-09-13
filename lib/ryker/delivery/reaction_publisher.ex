defmodule Ryker.Delivery.ReactionPublisher do
  @moduledoc """
  Narrow platform port for one durable emoji reaction.
  """

  alias Ryker.Delivery.Request

  @callback publish_reaction(Request.t(), term()) :: {:ok, map()} | {:error, term()}
end
