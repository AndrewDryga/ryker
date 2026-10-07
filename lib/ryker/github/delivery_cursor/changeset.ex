defmodule Ryker.GitHub.DeliveryCursor.Changeset do
  @moduledoc "Writes where the GitHub delivery poller stopped."
  import Ecto.Changeset
  alias Ryker.GitHub.DeliveryCursor

  @fields [:app_id, :through_delivery_id, :updated_at]

  def put(attrs) do
    %DeliveryCursor{}
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_number(:app_id, greater_than: 0)
    |> validate_number(:through_delivery_id, greater_than_or_equal_to: 0)
    |> check_constraint(:through_delivery_id, name: :github_delivery_cursor_valid)
  end
end
