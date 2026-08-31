defmodule Responder.Delivery.Platform do
  @moduledoc """
  Stable transport identity shared by narrow delivery publishers.
  """

  @callback transport() :: String.t()
end
