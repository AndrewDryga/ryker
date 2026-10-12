defmodule Ryker.Emisar.API do
  @moduledoc """
  Narrow port used to supervise one already-created Emisar run.

  Ryker never receives an API here that can approve or repeat the governed
  action. It reads the exact run named by the durable approval record, at once
  (`0`) or once it changes, waiting at most the given seconds; and it withdraws
  that run while it still waits for a review or a runner, once no task waits
  for it. Emisar asks a client to do that rather than leave the request open
  until someone decides or it expires, and a withdrawn run never reaches a
  runner.
  """
  alias Ryker.Emisar.RunState

  @callback wait_for_run(term(), String.t(), 0..60) ::
              {:ok, RunState.t()} | {:error, term()}

  @callback cancel_run(term(), String.t(), String.t()) ::
              {:ok, RunState.t()} | {:error, term()}
end
