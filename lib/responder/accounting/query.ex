defmodule Responder.Accounting.Query do
  @moduledoc "Ledger rows plus explicitly unreconciled legacy turn snapshots, without double counting."
  import Ecto.Query
  alias Responder.Accounting.Execution
  alias Responder.Episodes.Episode
  alias Responder.Work.{Session, Turn}

  def executions(since, mode \\ "live") do
    ledger =
      from(e in Execution,
        select: %{
          id: e.id,
          kind: e.kind,
          source_id: e.source_id,
          generation: e.generation,
          episode_id: e.episode_id,
          session_id: e.session_id,
          transport: e.transport,
          conversation_ref: e.conversation_ref,
          repository_ref: e.repository_ref,
          execution_mode: e.execution_mode,
          remote_ref: e.remote_ref,
          status: e.status,
          recorded_at: e.recorded_at,
          execution_target: e.execution_target,
          usage_recorded: e.usage_recorded,
          usage_cost_recorded: e.usage_cost_recorded,
          usage_cost_usd: e.usage_cost_usd,
          timing_recorded: e.timing_recorded,
          measurement_error_code: e.measurement_error_code,
          usage_input_tokens: e.usage_input_tokens,
          usage_cached_input_tokens: e.usage_cached_input_tokens,
          usage_output_tokens: e.usage_output_tokens,
          usage_reasoning_tokens: e.usage_reasoning_tokens,
          usage_queued_ms: e.usage_queued_ms,
          usage_provider_ms: e.usage_provider_ms,
          usage_host_ms: e.usage_host_ms,
          remote_queued_at: e.remote_queued_at,
          remote_started_at: e.remote_started_at,
          remote_finished_at: e.remote_finished_at
        }
      )

    # Match the column order in both sides of the UNION, including types.
    legacy =
      from(t in Turn,
        as: :legacy,
        join: s in Session,
        on: s.id == t.session_id,
        as: :session,
        join: p in Episode,
        on: p.id == t.episode_id,
        where: not is_nil(t.coop_turn_id) or not is_nil(t.accepted_at),
        where:
          not exists(
            from(e in Execution,
              where:
                e.kind == "work" and e.source_id == parent_as(:legacy).id and
                  e.generation ==
                    fragment(
                      "?::text || ':' || ?::text",
                      parent_as(:session).generation,
                      parent_as(:legacy).submit_generation
                    ),
              select: 1
            )
          ),
        select: %{
          id: t.id,
          kind: "work",
          source_id: t.id,
          generation: fragment("?::text || ':' || ?::text", s.generation, t.submit_generation),
          episode_id: t.episode_id,
          session_id: t.session_id,
          transport: p.destination_transport,
          conversation_ref: p.destination_conversation_ref,
          repository_ref: s.repository_ref,
          execution_mode: type(p.execution_mode, :string),
          remote_ref: t.coop_turn_id,
          status: type(t.status, :string),
          recorded_at:
            fragment("COALESCE(?, ?, ?)", t.remote_queued_at, t.accepted_at, t.inserted_at),
          execution_target: t.execution_target,
          usage_recorded: t.usage_recorded,
          usage_cost_recorded: t.usage_cost_recorded,
          usage_cost_usd: t.usage_cost_usd,
          timing_recorded: t.timing_recorded,
          measurement_error_code: t.measurement_error_code,
          usage_input_tokens: t.usage_input_tokens,
          usage_cached_input_tokens: t.usage_cached_input_tokens,
          usage_output_tokens: t.usage_output_tokens,
          usage_reasoning_tokens: t.usage_reasoning_tokens,
          usage_queued_ms: t.usage_queued_ms,
          usage_provider_ms: t.usage_provider_ms,
          usage_host_ms: t.usage_host_ms,
          remote_queued_at: t.remote_queued_at,
          remote_started_at: t.remote_started_at,
          remote_finished_at: t.remote_finished_at
        }
      )

    query = from(e in subquery(union_all(ledger, ^legacy)))
    query = if since, do: where(query, [e], e.recorded_at >= ^since), else: query
    if mode == "all", do: query, else: where(query, [e], e.execution_mode == ^mode)
  end
end
