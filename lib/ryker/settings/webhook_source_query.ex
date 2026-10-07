defmodule Ryker.Settings.WebhookSourceQuery do
  @moduledoc "Webhook sources, for every read of `webhook_source_settings`."
  import Ecto.Query
  alias Ryker.Settings.WebhookSource

  def all, do: from(rows in WebhookSource, as: :webhook_source_settings)

  def ordered_by_name(queryable), do: order_by(queryable, [webhook_source_settings: w], w.name)
end
