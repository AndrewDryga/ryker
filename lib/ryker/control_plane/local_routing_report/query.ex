defmodule Ryker.ControlPlane.LocalRoutingReport.Query do
  @moduledoc """
  What the local routing page reads (`Ryker.ControlPlane.LocalRoutingProjection`):
  the comparisons of a period and scope for one model, their figures, the
  answers compared with what each decided, and the groups the page's three
  tables count with each group's newest row.
  """
  import Ecto.Query
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.LocalRouting.Comparison

  # What a decision has Ryker do, as the kinds the page names
  # (`Ryker.ControlPlane.LocalRoutingProjection`).
  defmacrop decision_kind(document) do
    quote do
      fragment(
        """
        CASE ?->>'action'
          WHEN 'start_episode' THEN
            CASE WHEN ?->>'work_class' = 'deep' THEN 'start_deep' ELSE 'start' END
          WHEN 'continue_episode' THEN
            CASE WHEN ?->>'work_class' = 'deep' THEN 'continue_deep' ELSE 'continue' END
          WHEN 'reply' THEN 'reply'
          WHEN 'quick_reply' THEN 'quick_reply'
          WHEN 'react' THEN 'react'
          WHEN 'ignore' THEN 'ignore'
          ELSE 'unreadable'
        END
        """,
        unquote(document),
        unquote(document),
        unquote(document)
      )
    end
  end

  # An answer as JSON when it is JSON; any other text reads as unreadable.
  defmacrop answer_document(text) do
    quote do
      fragment(
        "CASE WHEN pg_input_is_valid(?, 'jsonb') THEN ?::jsonb END",
        unquote(text),
        unquote(text)
      )
    end
  end

  @doc """
  The comparisons since `since` (nil for all time) in `scope` (`live`,
  `shadow` or `all`) for `model`: a model tried earlier is another model's
  record.
  """
  def comparisons(since, scope, model) do
    Comparison.Query.all() |> in_period(since) |> in_scope(scope) |> of_model(model)
  end

  defp in_period(query, nil), do: query
  defp in_period(query, since), do: where(query, [c], c.inserted_at >= ^since)

  defp in_scope(query, "all"), do: query
  defp in_scope(query, "shadow"), do: where(query, [c], c.execution_mode == :shadow)
  defp in_scope(query, _live), do: where(query, [c], c.execution_mode == :live)

  defp of_model(query, nil), do: query
  defp of_model(query, model), do: where(query, [c], c.local_model == ^model)

  @doc "The figures of `comparisons`: counts, median times and what the provider spent."
  def figures(comparisons) do
    from(c in comparisons,
      select: %{
        compared: filter(count(c.id), c.status == :compared),
        valid: filter(count(c.id), c.status == :compared and c.valid),
        agreed: filter(count(c.id), c.status == :compared and c.agrees),
        waiting: filter(count(c.id), c.status == :pending),
        failed: filter(count(c.id), c.status == :failed),
        local_ms:
          fragment(
            "percentile_cont(0.5) WITHIN GROUP (ORDER BY ?) FILTER (WHERE ? = 'compared')",
            c.local_ms,
            c.status
          ),
        provider_ms:
          fragment(
            "percentile_cont(0.5) WITHIN GROUP (ORDER BY ?) FILTER (WHERE ? = 'compared')",
            c.provider_ms,
            c.status
          ),
        provider_cost: filter(sum(c.provider_cost_usd), c.status == :compared),
        agreed_cost: filter(sum(c.provider_cost_usd), c.status == :compared and c.agrees),
        estimated:
          fragment(
            "COALESCE(bool_or(?) FILTER (WHERE ? = 'compared'), false)",
            c.provider_cost_estimated,
            c.status
          )
      }
    )
  end

  @doc "The comparison of `comparisons` that settled last, compared or given up."
  def last_settled(comparisons) do
    from(c in comparisons,
      where: c.status != :pending,
      order_by: [desc: c.updated_at, desc: c.id],
      limit: 1,
      select: %{status: c.status, last_error: c.last_error}
    )
  end

  @doc """
  The compared answers of `comparisons`, each with what the provider decided
  and what the local model decided, as kinds.
  """
  def compared(comparisons) do
    from(c in comparisons,
      join: entry in Entry,
      on: entry.id == c.input_id,
      where: c.status == :compared,
      select: %{
        id: c.id,
        at: c.compared_at,
        input_id: c.input_id,
        generation: c.generation,
        valid: c.valid,
        agrees: c.agrees,
        differing: c.differing_fields,
        invalid_reason: c.invalid_reason,
        kind: decision_kind(fragment("?::jsonb", entry.decision_document)),
        local_kind: decision_kind(answer_document(c.local_answer))
      }
    )
  end

  @doc """
  What the local model chose instead, when its answer was usable but not the
  provider's, as `{kind, local_kind, count}`.
  """
  def instead(compared) do
    from(c in subquery(compared),
      where: c.valid and not c.agrees,
      group_by: [c.kind, c.local_kind],
      select: {c.kind, c.local_kind, count()}
    )
  end

  @doc "By what the provider decided: how many answers, how many usable, how many matched."
  def decisions(compared) do
    from(c in subquery(compared),
      group_by: c.kind,
      select: %{
        kind: c.kind,
        messages: count(),
        valid: filter(count(), c.valid),
        agreed: filter(count(), c.valid and c.agrees)
      }
    )
  end

  @doc """
  Each field a usable answer got differently, one row a field, and whether it
  was the only difference.
  """
  def differing_fields(compared) do
    from(c in subquery(compared),
      inner_lateral_join: field in fragment("SELECT unnest(?) AS name", c.differing),
      on: true,
      where: c.valid and not c.agrees,
      select: %{
        id: c.id,
        at: c.at,
        input_id: c.input_id,
        generation: c.generation,
        field: field.name,
        only: c.differing == fragment("ARRAY[?]", field.name)
      }
    )
  end

  @doc "How many answers got each field differently, and how often it was the only difference."
  def field_counts(fields) do
    from(f in subquery(fields),
      group_by: f.field,
      select: %{field: f.field, answers: count(), only: filter(count(), f.only)}
    )
  end

  @doc "The compared answers routing could not use."
  def refused(compared), do: from(c in subquery(compared), where: not c.valid)

  @doc "How many refused answers each reason holds, as `{invalid_reason, count}`."
  def refusal_counts(refused),
    do: from(c in refused, group_by: c.invalid_reason, select: {c.invalid_reason, count()})

  @doc """
  Each `group` of `rows`' newest row, by when it was compared: the message a
  table row opens, as `{group, %{id, at, input_id, generation}}`.
  """
  def latest(rows, group) do
    from(row in subquery(rows),
      distinct: field(row, ^group),
      order_by: [asc: field(row, ^group), desc: row.at, desc: row.id],
      select:
        {field(row, ^group),
         %{id: row.id, at: row.at, input_id: row.input_id, generation: row.generation}}
    )
  end
end
