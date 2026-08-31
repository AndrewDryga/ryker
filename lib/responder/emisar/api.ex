defmodule Responder.Emisar.API do
  @moduledoc """
  Narrow read-only port used to supervise one already-created Emisar run.

  Responder never receives an API here that can approve or repeat the governed
  action. The only capability is reading the exact run named by the durable
  approval record.
  """

  alias Responder.Emisar.RunState

  @callback wait_for_run(term(), String.t()) ::
              {:ok, RunState.t()} | {:error, term()}
end
