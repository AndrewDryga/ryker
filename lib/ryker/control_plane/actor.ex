defmodule Ryker.ControlPlane.Actor do
  @moduledoc """
  Who a console action is recorded as: the tailnet user Tailscale Serve named
  (`Ryker.ControlPlane.Viewer`), or the local console when nobody was named.

  A page's process takes its person once, when it connects (`act_for/1`), and
  every action it runs reads them here (`ref/0`) instead of each callback taking
  one more argument. A process that never took one, such as a background job or
  a test, acts as the local console.
  """

  alias Ryker.ControlPlane.Viewer

  @local "control-plane:local"
  @tailnet "control-plane:tailscale:"
  @key {__MODULE__, :ref}

  @doc "The local console: a console reached without Tailscale Serve."
  @spec local() :: String.t()
  def local, do: @local

  @doc "What `viewer`'s actions are recorded as."
  @spec of(Viewer.t() | nil) :: String.t()
  def of(%{login: login}), do: @tailnet <> login
  def of(nil), do: @local

  @doc "Makes `viewer` the actor of every action this process takes from now on."
  @spec act_for(Viewer.t() | nil) :: :ok
  def act_for(viewer) do
    Process.put(@key, of(viewer))
    :ok
  end

  @doc "Who this process's actions are recorded as."
  @spec ref() :: String.t()
  def ref, do: Process.get(@key, @local)
end
