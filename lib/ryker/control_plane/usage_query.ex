defmodule Ryker.ControlPlane.UsageQuery do
  @moduledoc """
  What the Usage page reads of the execution ledger
  (`Ryker.ControlPlane.UsageProjection`): each execution with the dimensions
  the page breaks it down by, the breakdowns, the days, and the totals.
  """
  import Ecto.Query
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Work.Turn

  # Each execution beside the message it answered: routing's names the
  # message itself, and a Work turn names the message that started it as
  # `ingress-turn:<message id>` (`Ryker.Admission`). One equality on the
  # message's id reads it through its key; two ORed conditions, one on a
  # reference built from every message, read the whole inbox for each
  # execution (2026-10-04 review).
  def dimensions(query) do
    from(e in query,
      left_join: turn in Turn,
      on: e.kind == "work" and turn.id == e.source_id,
      left_join: entry in Entry,
      on:
        entry.id ==
          fragment(
            "CASE WHEN ? = 'admission' THEN ? WHEN ? ~ '^ingress-turn:[0-9a-f-]{36}$' THEN substr(?, 14)::uuid END",
            e.kind,
            e.source_id,
            turn.turn_ref,
            turn.turn_ref
          ),
      select_merge: %{
        source: entry.source_kind,
        workspace: entry.source_ref,
        actor: entry.actor_ref,
        actor_kind: type(entry.actor_kind, :string),
        corrections:
          fragment(
            "CASE WHEN ? = 'work' AND (? = ? OR (? IS NULL AND ? = ?)) THEN (SELECT count(*) FROM jsonb_array_elements(COALESCE(?::jsonb, '[]'::jsonb)) AS v WHERE v->>'verdict' = 'reject') ELSE 0 END",
            e.kind,
            e.remote_ref,
            turn.coop_turn_id,
            e.remote_ref,
            e.id,
            turn.id,
            turn.validation_history
          ),
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
        effort:
          fragment(
            "NULLIF(split_part(split_part(?, '@', 1), '/', 2), '')",
            e.execution_target
          ),
        # Account ladders are configuration, not evidence of which credential ran.
        profile:
          fragment(
            "CASE WHEN ? LIKE '%@%' AND ? NOT LIKE '%@%@%' AND split_part(?, '@', 2) NOT LIKE '%,%' THEN NULLIF(split_part(?, '@', 2), '') END",
            e.execution_target,
            e.execution_target,
            e.execution_target,
            e.execution_target
          ),
        # Follow-on Work turns (continuations, resumes, tasks, waits, schedules,
        # publication checks, approvals) carry no admission decision. Their turn
        # family is the work type an operator can act on; "unclassified" hid
        # most of the spend on the live page behind one unopenable row.
        work_kind:
          fragment(
            "CASE WHEN ? = 'admission' THEN 'admission' WHEN ? = 'learning' THEN 'learning' WHEN ? = 'improvement' THEN 'self_analysis' WHEN ? = 'knowledge' THEN 'repository_knowledge' WHEN ? LIKE 'turn:after:%' THEN 'continuation' WHEN ? LIKE 'turn:resume-%' THEN 'resumed' WHEN ? LIKE 'turn:task:%' THEN 'task' WHEN ? LIKE 'turn:event-wait:%' THEN 'event_wait' WHEN ? LIKE 'turn:schedule:%' THEN 'schedule' WHEN ? LIKE 'turn:publication-%' THEN 'publication' WHEN ? LIKE 'turn:emisar-approval:%' THEN 'approval' ELSE COALESCE(?::jsonb ->> 'work_class', 'unclassified') END",
            e.kind,
            e.kind,
            e.kind,
            e.kind,
            turn.turn_ref,
            turn.turn_ref,
            turn.turn_ref,
            turn.turn_ref,
            turn.turn_ref,
            turn.turn_ref,
            turn.turn_ref,
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

  @doc "The executions whose dimension `field` is `value`; an empty value means unset."
  def with_dimension(query, field, ""), do: where(query, [e], is_nil(field(e, ^field)))
  def with_dimension(query, field, value), do: where(query, [e], field(e, ^field) == ^value)

  @doc "No executions: a filter that names no valid value matches nothing."
  def none(query), do: where(query, false)

  def in_slack(query), do: where(query, [e], e.transport == "slack")

  @doc """
  The executions a person asked for. Someone in Chat is a person once
  Tailscale or Cloudflare Access named them (`Ryker.ControlPlane.Actor.chat_ref/1`);
  the console reached without either has one shared operator, who is nobody
  in particular. Apps, bots, hooks and missing senders still count toward
  every overall total.
  """
  def people(query) do
    where(
      query,
      [e],
      e.actor_kind == "user" and not is_nil(e.actor) and e.actor != "" and
        (e.source != "control_plane" or like(e.actor, "tailscale:%") or
           like(e.actor, "cloudflare:%"))
    )
  end

  @doc """
  The executions grouped by `fields`, each group with the totals and its
  values, the most tokens first, at most 501.
  """
  def grouped(query, fields) do
    query
    |> group_by([e], ^fields)
    |> aggregate()
    |> correction_counts(fields)
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
  end

  defp correction_counts(query, [:work_kind, :provider, :model, :effort]) do
    select_merge(query, [e], %{
      corrections: type(fragment("COALESCE(SUM(?), 0)::bigint", e.corrections), :integer)
    })
  end

  defp correction_counts(query, _fields), do: query

  @doc "The executions grouped by UTC day, the latest year at most."
  def by_day(query) do
    query
    |> group_by([e], fragment("date(?)", e.recorded_at))
    |> aggregate()
    |> select_merge([e], %{date: type(fragment("date(?)", e.recorded_at), :date)})
    |> order_by([e], desc: fragment("date(?)", e.recorded_at))
    |> limit(366)
  end

  @doc "Each place and person the executions came from, for the filters, `limit` at most."
  def filter_options(query, limit) do
    from(e in query,
      distinct: true,
      select: map(e, [:source, :workspace, :actor, :actor_kind, :transport, :conversation_ref]),
      order_by: [e.source, e.workspace, e.actor, e.conversation_ref],
      limit: ^limit
    )
  end

  @doc "The totals of the executions, as one row."
  def aggregate(query) do
    from(e in query,
      select: %{
        attempts: count(e.id),
        # The requests Activity lists for these executions: each episode, and
        # each message routing read that never became one. Learning belongs
        # to no request.
        requests:
          fragment(
            "COUNT(DISTINCT COALESCE(?, CASE WHEN ? = 'admission' THEN ? END))",
            e.episode_id,
            e.kind,
            e.source_id
          ),
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
end
