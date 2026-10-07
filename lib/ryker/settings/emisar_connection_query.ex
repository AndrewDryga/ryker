defmodule Ryker.Settings.EmisarConnectionQuery do
  @moduledoc "Emisar accounts Ryker is connected to, for every read of `emisar_connection_settings`."
  import Ecto.Query
  alias Ryker.Settings.EmisarConnection

  def all, do: from(rows in EmisarConnection, as: :emisar_connection_settings)

  def ordered_by_ref(queryable), do: order_by(queryable, [emisar_connection_settings: c], c.ref)
end
