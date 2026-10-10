defmodule Ryker.Emisar do
  @moduledoc """
  Emisar, where Ryker's infrastructure actions run under policy and approval.

  What the console shows of a run names its runner and pack as people know
  them; the rest of each reference is Emisar's own id.
  """
  alias Ryker.Emisar.ApprovalStatus

  @doc "A runner as people know it: the part of Emisar's runner reference before `~`."
  @spec runner_name(String.t() | nil) :: String.t() | nil
  defdelegate runner_name(ref), to: ApprovalStatus

  @doc "A pack as people know it: its name and version, without the content digest."
  @spec pack_name(String.t() | nil) :: String.t() | nil
  defdelegate pack_name(ref), to: ApprovalStatus
end
