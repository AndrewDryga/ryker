defmodule Ryker.Settings.EmisarConnection.Query do
  @moduledoc "Emisar accounts Ryker is connected to, for every read of `emisar_connection_settings`."
  import Ecto.Query
  alias Ryker.Settings.EmisarConnection

  def all, do: from(rows in EmisarConnection, as: :emisar_connection_settings)

  def ordered_by_ref(queryable), do: order_by(queryable, [emisar_connection_settings: c], c.ref)

  @doc "Each account as `{ref, monitoring_enabled}`."
  def select_monitoring(queryable),
    do: select(queryable, [emisar_connection_settings: c], {c.ref, c.monitoring_enabled})
end
