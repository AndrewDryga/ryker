defmodule Ryker.CoopFleet.CommandQuery do
  @moduledoc "Commands Ryker queued for its workers, for every read of `coop_worker_commands`."
  import Ecto.Query
  alias Ryker.CoopFleet.Command

  def all, do: from(commands in Command, as: :coop_worker_commands)

  def queued(queryable \\ all()),
    do: where(queryable, [coop_worker_commands: c], c.status == :queued)

  def select_oldest_insert(queryable),
    do: select(queryable, [coop_worker_commands: c], min(c.inserted_at))
end
