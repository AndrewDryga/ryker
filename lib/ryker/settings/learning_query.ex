defmodule Ryker.Settings.LearningQuery do
  @moduledoc "How Ryker learns from conversations, for every read of `learning_settings`."
  import Ecto.Query
  alias Ryker.Settings.Learning

  def all, do: from(rows in Learning, as: :learning_settings)

  def by_id(queryable \\ all(), id), do: where(queryable, [learning_settings: l], l.id == ^id)

  @doc "Whether learning was turned on, from the one settings row."
  def select_enabled(queryable \\ all()),
    do: queryable |> select([learning_settings: l], l.enabled) |> limit(1)
end
