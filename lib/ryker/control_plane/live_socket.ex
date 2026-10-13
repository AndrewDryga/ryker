defmodule Ryker.ControlPlane.LiveSocket do
  @moduledoc """
  The live socket, admitted on the same peer and host boundary as every request.

  Who is signed in is checked where a page mounts (`WorkbenchLive.mount/3`), not here. Phoenix
  answers the socket before the endpoint's plugs, so the sign-in gate never sees it, and a page
  that mounts with nobody signed in goes to the sign-in page. A page whose sign-in no longer
  counts reconnects the same way: signed out, ended from Settings › Access, or an Access sign-in
  that ran out (2026-10-04 review). Refused here instead, such a page reconnected over and over
  and never left (2026-10-13).
  """
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
