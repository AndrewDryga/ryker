defmodule Ryker.Work.Executor.States do
  @moduledoc "Coop turn states shared by executor guards, without a compile dependency on its IO layer."

  def terminal, do: ~w(cancelled completed failed interrupted budget_exhausted)
  def waiting, do: ~w(queued starting running)
end
