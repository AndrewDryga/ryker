defmodule Responder.ControlPlane.UsageProjection do
  @moduledoc "Comparable usage breakdowns from the same deduplicated execution ledger."
  import Ecto.Query
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Repo
  alias Responder.Work.{Measurement, Turn}

  @filters %{
    "usage_profile" => :profile,
    "usage_provider" => :provider,
    "usage_model" => :model,
    "usage_target" => :execution_target,
    "usage_channel" => :conversation_ref,
    "usage_transport" => :transport,
    "usage_repository" => :repository_ref,
    "usage_work_kind" => :work_kind,
    "usage_actor" => :actor,
    "usage_workspace" => :workspace,
    "usage_source" => :source
  }

  def filter_keys, do: Map.keys(@filters) ++ ["usage_window"]
  def filtered?(params), do: Enum.any?(Map.keys(@filters), &Map.has_key?(params, &1))

  def link_params(params),
    do: Map.filter(params, fn {_key, value} -> is_binary(value) and byte_size(value) <= 512 end)

  def window(value) when value in ~w(24h 7d 30d all), do: value
  def window(_), do: "7d"

  def filter_activity(query, params) do
    if filtered?(params) do
      mode = if params["mode"] in ~w(shadow all), do: params["mode"], else: "live"

      executions =
        Responder.Accounting.Query.executions(
          since(params["usage_window"]),
          mode
        )
        |> dimensions()

      ids =
        Enum.reduce(@filters, executions, fn {key, field}, selected ->
          filter_dimension(selected, field, Map.fetch(params, key))
        end)

      episode_ids = from(e in ids, select: e.episode_id)
      admission_ids = from(e in ids, where: e.kind == "admission", select: e.source_id)

      from(row in query,
        where:
          (row.kind == "episode" and row.id in subquery(episode_ids)) or
            (row.kind == "admission" and row.id in subquery(admission_ids))
      )
    else
      query
    end
  end

  defp filter_dimension(query, field, {:ok, ""}),
    do: from(e in query, where: is_nil(field(e, ^field)))

  defp filter_dimension(query, field, {:ok, value})
       when is_binary(value) and byte_size(value) <= 512,
       do: from(e in query, where: field(e, ^field) == ^value)

  defp filter_dimension(query, _field, :error), do: query
  defp filter_dimension(query, _field, _invalid), do: from(e in query, where: false)

  defp since("all"), do: nil
  defp since("24h"), do: DateTime.add(DateTime.utc_now(), -24, :hour)
  defp since("30d"), do: DateTime.add(DateTime.utc_now(), -30, :day)
  defp since(_), do: DateTime.add(DateTime.utc_now(), -7, :day)

  def snapshot(query) do
    query = dimensions(query)

    targets =
      groups(query, [:execution_target])
      |> Enum.map(fn row ->
        row
        |> Map.put(:target, row.execution_target)
        |> Map.merge(Measurement.target_parts(row.execution_target))
      end)

    profiles =
      groups(query, [:provider, :profile])
      |> Enum.map(fn row ->
        models =
          Enum.filter(
            targets,
            &(&1.provider == row.provider and profile(&1.target) == row.profile)
          )

        row |> Map.put(:models, models) |> Map.put(:models_truncated, length(targets) > 500)
      end)

    %{
      totals: totals(query),
      profiles: profiles,
      targets: targets,
      models: groups(query, [:provider, :model]),
      channels: groups(query, [:transport, :conversation_ref]),
      repositories: groups(query, [:repository_ref]),
      kinds: groups(query, [:work_kind]),
      users: groups(query, [:source, :workspace, :actor]),
      days: days(query)
    }
  end

  def totals(query), do: query |> aggregate() |> Repo.one!() |> finish()

  # A configured account ladder is not evidence that its first credential ran.
  # Missing/ambiguous historic targets stay unattributed instead of guessing.
  def profile(target) when is_binary(target) do
    case String.split(target, "@") do
      [_head, account] when account != "" ->
        if String.contains?(account, ","), do: nil, else: account

      _ ->
        nil
    end
  end

  def profile(_), do: nil

  def dimensions(query) do
    from(e in query,
      left_join: turn in Turn,
      on: e.kind == "work" and turn.id == e.source_id,
      left_join: entry in Entry,
      on:
        (e.kind == "admission" and entry.id == e.source_id) or
          (e.kind == "work" and turn.turn_ref == fragment("'ingress-turn:' || ?::text", entry.id)),
      select_merge: %{
        source: entry.source_kind,
        workspace: entry.source_ref,
        actor: entry.actor_ref,
        provider:
          fragment(
            "COALESCE(NULLIF(split_part(split_part(split_part(?, '@', 1), '/', 1), ':', 1), ''), 'unrecorded')",
            e.execution_target
          ),
        model:
          fragment(
            "NULLIF(split_part(split_part(split_part(?, '@', 1), '/', 1), ':', 2), '')",
            e.execution_target
          ),
        profile:
          fragment(
            "CASE WHEN ? LIKE '%@%' AND ? NOT LIKE '%@%@%' AND split_part(?, '@', 2) NOT LIKE '%,%' THEN NULLIF(split_part(?, '@', 2), '') END",
            e.execution_target,
            e.execution_target,
            e.execution_target,
            e.execution_target
          ),
        work_kind:
          fragment(
            "CASE WHEN ? = 'admission' THEN 'admission' ELSE COALESCE(?::jsonb ->> 'work_class', 'unclassified') END",
            e.kind,
            entry.decision_document
          ),
        conversation_ref:
          fragment(
            "CASE WHEN ? = 'control_plane' THEN 'control-plane:lab:' ELSE ? END",
            e.transport,
            e.conversation_ref
          )
      }
    )
    |> subquery()
  end

  defp groups(query, fields) do
    query
    |> group_by([e], ^fields)
    |> aggregate()
    |> select_merge([e], map(e, ^fields))
    |> order_by([e],
      desc:
        fragment(
          "COALESCE(SUM(?), 0) + COALESCE(SUM(?), 0) + COALESCE(SUM(?), 0)",
          e.usage_input_tokens,
          e.usage_cached_input_tokens,
          e.usage_output_tokens
        )
    )
    |> order_by(^fields)
    |> limit(501)
    |> Repo.all()
    |> Enum.map(&finish/1)
    |> Enum.sort_by(&{-&1.tokens, -&1.attempts, inspect(Map.take(&1, fields))})
  end

  defp days(query) do
    query
    |> group_by([e], fragment("date(?)", e.recorded_at))
    |> aggregate()
    |> select_merge([e], %{date: type(fragment("date(?)", e.recorded_at), :date)})
    |> order_by([e], desc: fragment("date(?)", e.recorded_at))
    |> limit(366)
    |> Repo.all()
    |> Enum.map(&finish/1)
    |> Enum.sort_by(&Date.to_gregorian_days(&1.date))
  end

  defp aggregate(query) do
    from(e in query,
      select: %{
        attempts: count(e.id),
        episodes: count(e.episode_id, :distinct),
        admission: fragment("COUNT(*) FILTER (WHERE ? = 'admission')", e.kind),
        work: fragment("COUNT(*) FILTER (WHERE ? = 'work')", e.kind),
        unsuccessful:
          fragment(
            "COUNT(*) FILTER (WHERE ? IN ('failed', 'interrupted', 'budget_exhausted', 'cancelled'))",
            e.status
          ),
        input_tokens:
          type(fragment("COALESCE(SUM(?), 0)::bigint", e.usage_input_tokens), :integer),
        cached_input_tokens:
          type(fragment("COALESCE(SUM(?), 0)::bigint", e.usage_cached_input_tokens), :integer),
        output_tokens:
          type(fragment("COALESCE(SUM(?), 0)::bigint", e.usage_output_tokens), :integer),
        reasoning_tokens:
          type(fragment("COALESCE(SUM(?), 0)::bigint", e.usage_reasoning_tokens), :integer),
        cost_usd: fragment("COALESCE(SUM(?), 0)", e.usage_cost_usd),
        estimated_cost_usd: fragment("COALESCE(SUM(?), 0)", e.estimated_cost_usd),
        estimated: count(e.estimated_cost_usd),
        costed: fragment("COUNT(*) FILTER (WHERE ?)", e.usage_cost_recorded),
        usage_measured: fragment("COUNT(*) FILTER (WHERE ?)", e.usage_recorded),
        measurement_errors: count(e.measurement_error_code),
        timed: fragment("COUNT(*) FILTER (WHERE ?)", e.timing_recorded),
        queued_ms: type(fragment("COALESCE(SUM(?), 0)::bigint", e.usage_queued_ms), :integer),
        provider_ms: type(fragment("COALESCE(SUM(?), 0)::bigint", e.usage_provider_ms), :integer),
        host_ms: type(fragment("COALESCE(SUM(?), 0)::bigint", e.usage_host_ms), :integer)
      }
    )
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
  defp ratio(n, d), do: Float.round(n / d, 4)
  defp average(_, 0), do: nil
  defp average(n, d), do: div(n, d)
end
