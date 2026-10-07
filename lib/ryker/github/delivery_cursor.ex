defmodule Ryker.GitHub.DeliveryCursor do
  @moduledoc """
  Where `Ryker.GitHub.DeliveryPoller` stopped reading an App's deliveries:
  every delivery up to `through_delivery_id` was taken or is not taken again.
  """

  use Ecto.Schema

  @primary_key {:app_id, :integer, autogenerate: false}

  schema "github_delivery_cursors" do
    field(:through_delivery_id, :integer)
    field(:updated_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          app_id: pos_integer(),
          through_delivery_id: non_neg_integer(),
          updated_at: DateTime.t()
        }
end
