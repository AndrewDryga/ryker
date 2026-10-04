defmodule Ryker.Runtime.Child do
  @moduledoc """
  The processes one runtime key runs, under a supervisor of their own.

  `Ryker.Runtime.Owner` starts one per key in `Ryker.Runtime.Supervisor` and
  stops the key by stopping this supervisor, so a child it restarted after a
  crash is stopped with it: the owner never has to know a child's current pid.
  It is a temporary child of the dynamic supervisor. A key that crashes past its
  own restart limit ends here, and the owner, which monitors it, starts it again
  later, so one failing runtime never spends the restart budget every other
  runtime shares.
  """

  use Supervisor

  @doc "The dynamic supervisor's child spec for `key` running `specs`."
  @spec child_spec({atom(), [Supervisor.child_spec() | {module(), term()} | module()]}) ::
          Supervisor.child_spec()
  def child_spec({key, specs}) when is_atom(key) and is_list(specs) do
    %{
      id: {__MODULE__, key},
      start: {__MODULE__, :start_link, [specs]},
      restart: :temporary,
      shutdown: :infinity,
      type: :supervisor
    }
  end

  @spec start_link([Supervisor.child_spec() | {module(), term()} | module()]) ::
          Supervisor.on_start()
  def start_link(specs), do: Supervisor.start_link(__MODULE__, specs)

  @impl true
  def init(specs), do: Supervisor.init(specs, strategy: :one_for_one)
end
