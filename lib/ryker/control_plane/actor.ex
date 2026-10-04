defmodule Ryker.ControlPlane.Actor do
  @moduledoc """
  Who a console action is recorded as: the tailnet user Tailscale Serve named
  (`Ryker.ControlPlane.Viewer`), or the local console when nobody was named.

  A page's process takes its person once, when it connects (`act_for/1`), and
  every action it runs reads them here instead of each callback taking one
  more argument. A process that never took one, such as a background job or
  a test, acts as the local console.

  A person is recorded in the form each record keeps: a change made on a page
  under `ref/0`, and a Chat message, reaction or answer under `chat_ref/0`,
  the actor a Chat input carries. `person_ref/0` is the person a turn is for,
  the form a preference kept for one person is scoped to.
  `Ryker.ControlPlane.TailnetPeople.person/1` names any of them.
  """

  alias Ryker.ControlPlane.Viewer

  @local "control-plane:local"
  @tailnet "control-plane:tailscale:"
  @key {__MODULE__, :viewer}

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
    Process.put(@key, viewer)
    :ok
  end

  @doc "Who this process's actions are recorded as."
  @spec ref() :: String.t()
  def ref, do: of(Process.get(@key))

  @doc """
  The actor of a Chat message, reaction or answer from `viewer`: their
  tailnet login, or the local console's one operator.
  """
  @spec chat_ref(Viewer.t() | nil) :: String.t()
  def chat_ref(%{login: login}), do: "tailscale:" <> login
  def chat_ref(nil), do: "local-operator"

  @doc "The actor of a Chat message, reaction or answer this process sends."
  @spec chat_ref() :: String.t()
  def chat_ref, do: chat_ref(Process.get(@key))

  @doc "The person a turn this process's Chat message starts is for."
  @spec person_ref() :: String.t()
  def person_ref, do: "control_plane:user:" <> chat_ref()
end
