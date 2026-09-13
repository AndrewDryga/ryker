defmodule Ryker.ControlPlane.HttpPlug do
  @moduledoc """
  The HTTP side of the control plane: confirmed actions, downloads, record
  views and the observability endpoints, served by `Router` with the options
  the endpoint was started with.

  `WebRouter` forwards here after the live routes; the forward's options are
  fixed at compile time, so the runtime options are read on each request.
  """
  alias Ryker.ControlPlane.Endpoint
  alias Ryker.ControlPlane.Router

  def init(options), do: options

  def call(conn, _options) do
    Router.call(conn, Endpoint.config(:control_plane))
  end
end
