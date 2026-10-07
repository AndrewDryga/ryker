defmodule Ryker.Settings.PricingRateQuery do
  @moduledoc "Saved model prices (Settings › Model prices), for every read of `pricing_rates`."
  import Ecto.Query
  alias Ryker.Settings.PricingRate

  def all, do: from(rates in PricingRate, as: :pricing_rates)

  @doc "The saved price in effect for one call to `target` on `day` (`covering/2`)."
  def in_effect(target, %Date{} = day) when is_binary(target),
    do: covering(dynamic(type(^target, :string)), dynamic(type(^day, :date)))

  @doc """
  The one rule for which saved price covers a call to `target` on `day`, both
  dynamic expressions: the price saved for its provider and model, without
  `/effort` or `@account`, with the latest effective day on or before `day`.
  """
  def covering(target, day) do
    model = dynamic(fragment("split_part(split_part(?, '@', 1), '/', 1)", ^target))

    all()
    |> where(
      ^dynamic([pricing_rates: p], p.execution_target == ^model and p.effective_from <= ^day)
    )
    |> order_by([pricing_rates: p], desc: p.effective_from)
    |> limit(1)
  end

  def by_ids(queryable \\ all(), ids_query),
    do: where(queryable, [pricing_rates: p], p.id in subquery(ids_query))

  def ordered_by_target(queryable),
    do: order_by(queryable, [pricing_rates: p], [p.execution_target, p.effective_from])
end
