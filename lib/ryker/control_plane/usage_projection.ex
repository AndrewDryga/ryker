defmodule Ryker.ControlPlane.UsageProjection do
  @moduledoc "Comparable usage breakdowns from the same deduplicated execution ledger."
  alias Ryker.Accounting
  alias Ryker.ControlPlane.{Activity, RepositoryNames, Usage}
  alias Ryker.Repo
  alias Ryker.Work

  @filters %{
    "usage_profile" => :profile,
    "usage_provider" => :provider,
    "usage_model" => :model,
    "usage_effort" => :effort,
    "usage_channel" => :conversation_ref,
    "usage_repository" => :repository_ref,
    "usage_work_kind" => :work_kind,
    "usage_actor" => :actor,
    "usage_actor_kind" => :actor_kind,
    "usage_workspace" => :workspace,
    "usage_source" => :source
  }

  def filter_keys, do: Map.keys(@filters) ++ ["usage_window"]
  def filtered?(params), do: Enum.any?(filter_keys(), &Map.has_key?(params, &1))

  def link_params(params),
    do: Map.filter(params, fn {_key, value} -> is_binary(value) and byte_size(value) <= 512 end)

  def window(value) when value in ~w(24h 7d 30d all), do: value
  def window(_), do: "7d"

  @doc """
  The Usage page: every breakdown for the requested window and execution mode.
  Like Activity, it opens on live work.
  """
  @spec page(term()) :: map()
  def page(params) when is_map(params) do
    window = window(params["window"])
    mode = if params["mode"] in ~w(all shadow), do: params["mode"], else: "live"

    window
    |> since()
    |> Accounting.Execution.Query.ledger(mode)
    |> snapshot()
    |> Map.merge(%{mode: mode, window: window})
  end

  def page(_params), do: page(%{})

  @doc """
  Narrows Activity's rows to the requests whose executions match the usage
  filters in `params`. A period applies only when the view carries one, as a
  link from Usage does; a filter chosen on Activity covers all history.
  """
  def filter_activity(query, params) do
    if filtered?(params) do
      mode = if params["mode"] in ~w(shadow all), do: params["mode"], else: "live"
      window = if Map.has_key?(params, "usage_window"), do: params["usage_window"], else: "all"

      executions =
        window
        |> since()
        |> Accounting.Execution.Query.ledger(mode)
        |> Usage.Query.dimensions()

      selected =
        Enum.reduce(@filters, executions, fn {key, field}, selected ->
          filter_dimension(selected, field, Map.fetch(params, key))
        end)

      Activity.Query.by_executions(query, selected)
    else
      query
    end
  end

  defp filter_dimension(query, field, {:ok, value})
       when is_binary(value) and byte_size(value) <= 512,
       do: Usage.Query.by_dimension(query, field, value)

  defp filter_dimension(query, _field, :error), do: query
  defp filter_dimension(query, _field, _invalid), do: Usage.Query.none(query)

  @doc "The start of a usage window, or nil for all time."
  @spec since(String.t()) :: DateTime.t() | nil
  def since("all"), do: nil
  def since("24h"), do: DateTime.add(DateTime.utc_now(), -24, :hour)
  def since("30d"), do: DateTime.add(DateTime.utc_now(), -30, :day)
  def since(_), do: DateTime.add(DateTime.utc_now(), -7, :day)

  def snapshot(query) do
    prices = Accounting.Pricing.used(query)
    query = Usage.Query.dimensions(query)

    targets =
      groups(query, [:execution_target])
      |> Enum.map(fn row ->
        row
        |> Map.put(:target, row.execution_target)
        |> Map.merge(Work.Measurement.target_parts(row.execution_target))
      end)

    %{
      totals: totals(query),
      profiles: groups(query, [:provider, :profile]),
      targets: targets,
      models: groups(query, [:provider, :model, :effort]),
      performance: groups(query, [:work_kind, :provider, :model, :effort]),
      channels: query |> Usage.Query.in_slack() |> groups([:transport, :conversation_ref]),
      repositories: query |> groups([:repository_ref]) |> named_repositories(),
      kinds: groups(query, [:work_kind]),
      users: query |> Usage.Query.people() |> groups([:source, :workspace, :actor]),
      days: days(query),
      prices: prices
    }
  end

  def totals(query), do: query |> Usage.Query.aggregate() |> Repo.one!() |> finish()

  # A repository row reads as owner/repo; its ref stays for the filter link.
  defp named_repositories(rows) do
    names = if Enum.any?(rows, & &1.repository_ref), do: RepositoryNames.all(), else: %{}
    Enum.map(rows, &Map.put(&1, :repository_name, RepositoryNames.name(names, &1.repository_ref)))
  end

  def filter_options do
    nil
    |> Accounting.Execution.Query.ledger("all")
    |> Usage.Query.dimensions()
    |> Usage.Query.filter_options(500)
    |> Repo.all()
  end

  defp groups(query, fields) do
    query
    |> Usage.Query.grouped(fields)
    |> Repo.all()
    |> Enum.map(&finish/1)
    |> Enum.sort_by(&{-&1.tokens, -&1.attempts, inspect(Map.take(&1, fields))})
  end

  defp days(query) do
    query
    |> Usage.Query.by_day()
    |> Repo.all()
    |> Enum.map(&finish/1)
    |> Enum.sort_by(&Date.to_gregorian_days(&1.date))
  end

  defp finish(row) do
    input = row.input_tokens + row.cached_input_tokens

    row
    |> Map.merge(%{
      tokens: input + row.output_tokens,
      measured: row.usage_measured,
      cache_hit_rate: ratio(row.cached_input_tokens, input),
      average_queued_ms: average(row.queued_ms, row.timed),
      average_provider_ms: average(row.provider_ms, row.timed),
      average_host_ms: average(row.host_ms, row.timed)
    })
  end

  defp ratio(_, 0), do: nil
  defp ratio(part, whole), do: Float.round(part / whole, 4)
  defp average(_, 0), do: nil
  defp average(total, count), do: div(total, count)
end
