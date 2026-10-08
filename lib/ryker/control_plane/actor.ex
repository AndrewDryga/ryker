defmodule Ryker.ControlPlane.Actor do
  @moduledoc """
  Who a console action is recorded as: the person Tailscale Serve or Cloudflare
  Access named (`Ryker.ControlPlane.Viewer`), or the local console when nobody
  was named. A person's references say which of the two named them, so a
  Cloudflare sign-in never reads as a tailnet one.

  The console hands every action the person who took it, the viewer its page
  or request has: nobody is read from the process running it. A viewer of nil
  is the local console.

  A person is recorded in the form each record keeps: a change made on a page
  under `of/1`, and a Chat message, reaction or answer under `chat_ref/1`, the
  actor a Chat input carries. `person_ref/1` is the person a turn is for, the
  form a preference kept for one person is scoped to.
  `Ryker.ControlPlane.ConsolePeople.person/1` names any of them, and `login/1`
  reads the person out of any of them.
  """
  alias Ryker.ControlPlane.Viewer

  @local "control-plane:local"
  # The services that name a person to the console (`Viewer`).
  @sources ~w(tailscale cloudflare)
  @maximum_login_bytes 200

  @doc "What `viewer`'s actions are recorded as."
  @spec of(Viewer.t() | nil) :: String.t()
  def of(%{login: login, via: via}), do: "control-plane:#{via}:" <> login
  def of(nil), do: @local

  @doc """
  The actor of a Chat message, reaction or answer from `viewer`: their login
  as the service that named them gave it, or the local console's one operator.
  """
  @spec chat_ref(Viewer.t() | nil) :: String.t()
  def chat_ref(%{login: login, via: via}), do: "#{via}:" <> login
  def chat_ref(nil), do: "local-operator"

  @doc """
  The person a Chat actor (`chat_ref/1`) is: whom a turn is for, and whom a
  reaction is recorded under.
  """
  @spec person_ref(String.t()) :: String.t()
  def person_ref(chat_ref) when is_binary(chat_ref), do: "control_plane:user:" <> chat_ref

  @doc """
  The login of the person any of these references names (a page change, a
  Chat actor, the person a turn is for, a Chat reaction's), or nil for the
  local console and for anything that is not a console person's.
  """
  @spec login(term()) :: String.t() | nil
  def login("control_plane:user:" <> ref), do: login(ref)
  def login("control-plane:" <> ref), do: source_login(ref)
  def login(ref) when is_binary(ref), do: source_login(ref)
  def login(_ref), do: nil

  @doc "Whether `ref` is a Chat actor a named person is recorded as (`chat_ref/1`)."
  @spec chat_ref?(term()) :: boolean()
  def chat_ref?(ref) when is_binary(ref), do: is_binary(source_login(ref))

  def chat_ref?(_ref), do: false

  defp source_login(ref) do
    with [source, login] when source in @sources <- String.split(ref, ":", parts: 2),
         true <- byte_size(login) in 1..@maximum_login_bytes and String.valid?(login) do
      login
    else
      _other -> nil
    end
  end
end
