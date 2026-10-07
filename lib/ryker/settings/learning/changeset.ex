defmodule Ryker.Settings.Learning.Changeset do
  @moduledoc "Turning background learning on or off (`Ryker.Settings.Learning`)."
  @behaviour Ryker.Settings.Section.Changeset
  use Ryker, :changeset
  alias Ryker.Settings.Learning

  @fields ~w(enabled)a

  @impl true
  def fields, do: @fields

  @impl true
  def update(%Learning{} = learning, attributes, _snapshot),
    do: learning |> cast(attributes, @fields) |> validate_required(@fields)
end
