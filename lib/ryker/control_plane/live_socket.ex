defmodule Ryker.ControlPlane.LiveSocket do
  @moduledoc """
  The live socket, admitted on the same peer and host boundary as every request, and only for
  a page someone is signed in on (`Viewer.from_session/1`): a session's sign-in while it lasts,
  or the person a service that published the console named, an Access sign-in only while it
  counts.
  """
  use Phoenix.LiveView.Socket
  alias Phoenix.LiveView.Socket
  alias Ryker.ControlPlane.{BrowserGuard, Endpoint, Viewer}

  @impl true
  def id(socket), do: Socket.id(socket)

  @impl true
  def connect(_params, socket, %{peer_data: %{address: address}, uri: %URI{host: host}} = info) do
    control_plane = Endpoint.config(:control_plane)
    access = Map.get(control_plane, :access, :loopback)
    published_host = Map.get(control_plane, :public_host)

    if BrowserGuard.peer_allowed?(address, access) and
         BrowserGuard.local_host?(host, published_host) and
         signed_in?(Map.get(info, :session)),
       do: {:ok, socket},
       else: :error
  end

  def connect(_params, _socket, _info), do: :error

  # Phoenix answers the socket before the endpoint's plugs, so the sign-in gate never sees it,
  # and the socket carries no Access token to check. The page that opened it did: its session
  # holds the sign-in, or the person Access named and when that sign-in stops counting. A held
  # session reconnected at the published host with no current sign-in (2026-10-04 review).
  defp signed_in?(session) do
    case Viewer.from_session(session || %{}) do
      %{via: :cloudflare, until: until} -> until >= System.os_time(:second)
      nil -> false
      _viewer -> true
    end
  end
end
