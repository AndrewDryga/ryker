defmodule Ryker.Emisar.ApprovalQuery do
  @moduledoc "Emisar approvals Ryker asked a person for, for every read of `episode_emisar_approvals`."
  import Ecto.Query
  alias Ryker.Emisar.Approval

  def all, do: from(approvals in Approval, as: :episode_emisar_approvals)

  def by_connection(queryable \\ all(), connection_ref),
    do: where(queryable, [episode_emisar_approvals: a], a.connection_ref == ^connection_ref)
end
