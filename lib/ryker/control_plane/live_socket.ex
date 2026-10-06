defmodule Ryker.ControlPlane.LiveSocket do
  @moduledoc """
  The live socket, admitted on the same peer and host boundary as every
  request, and at a host published through Cloudflare Access only while the
  sign-in that opened its page counts.
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
         signed_in?(host, control_plane, Map.get(info, :session)),
       do: {:ok, socket},
       else: :error
  end

  def connect(_params, _socket, _info), do: :error

  # Phoenix answers the socket before the endpoint's plugs, so `BrowserGuard`
  # never sees it, and the socket carries no Access token to check. The page
  # that opened it did: its session holds the person Access named and when
  # that sign-in stops counting. A held session reconnected at the published
  # host with no current sign-in (2026-10-04 review).
  defp signed_in?(host, %{public_host: host, cloudflare_access: %{}}, session) do
    session
    |> Kernel.||(%{})
    |> Viewer.from_session()
    |> current_access_sign_in?(System.os_time(:second))
  end

  defp signed_in?(_host, _control_plane, _session), do: true

  defp current_access_sign_in?(%{via: :cloudflare, until: until}, now), do: until >= now
  defp current_access_sign_in?(_viewer, _now), do: false
end
