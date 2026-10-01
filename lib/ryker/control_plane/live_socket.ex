defmodule Ryker.ControlPlane.LiveSocket do
  @moduledoc "The live socket, admitted on the same peer and host boundary as every request."
  use Phoenix.LiveView.Socket

  alias Phoenix.LiveView.Socket
  alias Ryker.ControlPlane.{BrowserGuard, Endpoint}

  @impl true
  def id(socket), do: Socket.id(socket)

  @impl true
  def connect(_params, socket, %{peer_data: %{address: address}, uri: %URI{host: host}}) do
    control_plane = Endpoint.config(:control_plane)
    access = Map.get(control_plane, :access, :loopback)
    published_host = Map.get(control_plane, :public_host)

    if BrowserGuard.peer_allowed?(address, access) and
         BrowserGuard.local_host?(host, published_host),
       do: {:ok, socket},
       else: :error
  end

  def connect(_params, _socket, _info), do: :error
end
