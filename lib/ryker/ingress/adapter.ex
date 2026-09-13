defmodule Ryker.Ingress.Adapter do
  @moduledoc """
  One deterministic authenticated-source adapter.

  Gateways authenticate raw transport events and resolve trusted bindings
  before calling an adapter. The adapter may interpret platform identity and
  shape, but it must return exactly one canonical ingress input whose source
  kind matches the registered adapter.
  """

  alias Ryker.Ingress.Input

  @callback source_kind() :: String.t()
  @callback normalize(authenticated_event :: term(), trusted_binding :: term()) ::
              {:ok, Input.t()} | {:error, term()}
end
