defmodule Ryker.ControlPlane.LiveSocket do
  @moduledoc false
  use Phoenix.LiveView.Socket

  alias Phoenix.LiveView.Socket

  @impl true
  alias Ryker.ControlPlane.BrowserGuard

  def id(socket), do: Socket.id(socket)

  @impl true
  def connect(_params, socket, %{peer_data: %{address: address}, uri: %URI{host: host}}) do
    if BrowserGuard.loopback?(address) and
         host in ["localhost", "127.0.0.1", "::1"], do: {:ok, socket}, else: :error
  end

  def connect(_params, _socket, _info), do: :error
end
