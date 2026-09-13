defmodule Ryker.ControlPlane.LiveSocket do
  @moduledoc "The live socket, admitted on the same loopback and host boundary as every request."
  use Phoenix.LiveView.Socket

  alias Phoenix.LiveView.Socket
  alias Ryker.ControlPlane.BrowserGuard

  @impl true
  def id(socket), do: Socket.id(socket)

  @impl true
  def connect(_params, socket, %{peer_data: %{address: address}, uri: %URI{host: host}}) do
    if BrowserGuard.loopback?(address) and BrowserGuard.local_host?(host),
      do: {:ok, socket},
      else: :error
  end

  def connect(_params, _socket, _info), do: :error
end
