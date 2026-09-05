defmodule Responder.ControlPlane.LegacyPlug do
  @moduledoc "Preserves confirmed HTTP actions and download contracts during LiveView migration."
  alias Responder.ControlPlane.Endpoint
  alias Responder.ControlPlane.Router

  def init(options), do: options

  def call(conn, _options) do
    options = Endpoint.config(:control_plane)
    Router.call(conn, options)
  end
end
