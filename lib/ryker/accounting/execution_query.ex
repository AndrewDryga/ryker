defmodule Ryker.Accounting.ExecutionQuery do
  @moduledoc """
  The execution ledger, as every read of `execution_usage` composes it.

  Every execution has its `execution_usage` row before it reaches Coop: Work
  records `requested` before the turn is submitted, admission and learning
  record inside the transaction that owns their attempt. Nothing is read from
  the turn's own usage columns here; those are the turn's snapshot, not the
  ledger.
  """
  import Ecto.Query
  alias Ryker.Accounting.Execution
  alias Ryker.Settings.PricingRateQuery

  @fields Execution.__schema__(:fields) -- [:inserted_at, :updated_at]

  def all, do: from(executions in Execution, as: :execution_usage)

  @doc "The ledger rows of executions of `kind` made for `source_ids`."
  def of_sources(queryable \\ all(), kind, source_ids),
    do: where(queryable, [execution_usage: e], e.kind == ^kind and e.source_id in ^source_ids)

  @doc """
  The priced ledger since `since` (all of it for nil) in `mode` ("live",
  "shadow" or "all"), one map an execution.
  """
  def ledger(since, mode \\ "live") do
    all()
    |> select([execution_usage: e], map(e, ^@fields))
    |> recorded_since(since)
    |> in_mode(mode)
    |> priced()
  end

  def recorded_since(queryable, nil), do: queryable

  def recorded_since(queryable, since),
    do: where(queryable, [execution_usage: e], e.recorded_at >= ^since)

  def in_mode(queryable, "all"), do: queryable

  def in_mode(queryable, mode),
    do: where(queryable, [execution_usage: e], e.execution_mode == ^mode)

  @doc """
  The ledger with each execution's estimate (`estimated_cost_usd`) and the
  saved price in effect for it (`pricing_rate_id`), by `Ryker.Accounting.Pricing`'s
  rule. The estimate is nil when the provider reported a cost, no usage was
  recorded, a token count is negative or missing, or no saved price covers
  the model on that day.
  """
  def priced(queryable) do
    price =
      PricingRateQuery.covering(
        dynamic(parent_as(:execution_usage).execution_target),
        dynamic(fragment("(?)::date", parent_as(:execution_usage).recorded_at))
      )

    # Input, cache reads and output at their prices, per million tokens.
    # Reasoning is charged only at a reasoning price of its own: Codex and
    # Claude count it in output, so their prices leave it empty.
    priced =
      from([execution_usage: e] in queryable,
        left_lateral_join: p in subquery(price),
        on: true,
        select_merge: %{
          estimated_cost_usd:
            fragment(
              "CASE WHEN ? IS NOT NULL AND ? AND NOT ? AND ? >= 0 AND ? >= 0 AND ? >= 0 AND (? IS NULL OR ? >= 0) THEN (? * ? + ? * ? + ? * ? + COALESCE(? * ?, 0)) / 1000000 END",
              p.id,
              e.usage_recorded,
              e.usage_cost_recorded,
              e.usage_input_tokens,
              e.usage_cached_input_tokens,
              e.usage_output_tokens,
              p.reasoning_usd_per_million,
              e.usage_reasoning_tokens,
              e.usage_input_tokens,
              p.input_usd_per_million,
              e.usage_cached_input_tokens,
              p.cached_input_usd_per_million,
              e.usage_output_tokens,
              p.output_usd_per_million,
              e.usage_reasoning_tokens,
              p.reasoning_usd_per_million
            ),
          pricing_rate_id: p.id
        }
      )

    from(e in subquery(priced), as: :ledger)
  end

  def recorded_before(ledger, to), do: where(ledger, [ledger: e], e.recorded_at < ^to)

  @doc "Every execution of conversation `conversation_ref` on `transport`."
  def in_conversation(ledger, transport, conversation_ref) do
    where(
      ledger,
      [ledger: e],
      e.transport == ^transport and e.conversation_ref == ^conversation_ref
    )
  end

  @doc "Every execution of request `episode_id`."
  def of_episode(ledger, episode_id), do: where(ledger, [ledger: e], e.episode_id == ^episode_id)

  @doc "Every routing call made for message `input_id`."
  def admission_calls(ledger, input_id),
    do: where(ledger, [ledger: e], e.kind == "admission" and e.source_id == ^input_id)

  @doc "The routing call for generation `generation` of message `input_id`, with what it cost and how long it took."
  def admission_call(ledger, input_id, generation) do
    ledger
    |> where(
      [ledger: e],
      e.kind == "admission" and e.source_id == ^input_id and e.generation == ^generation
    )
    |> limit(1)
    |> select([ledger: e], %{
      recorded: e.usage_cost_recorded,
      reported: e.usage_cost_usd,
      estimate: e.estimated_cost_usd,
      ms: e.usage_provider_ms
    })
  end

  @doc """
  How many calls the ledger holds and what they cost: what providers reported,
  Ryker's estimates, and how many of each.
  """
  def select_cost_totals(ledger) do
    select(ledger, [ledger: e], %{
      calls: count(e.id),
      reported: fragment("COALESCE(SUM(?), 0)", e.usage_cost_usd),
      estimated: fragment("COALESCE(SUM(?), 0)", e.estimated_cost_usd),
      priced: fragment("COUNT(*) FILTER (WHERE ?)", e.usage_cost_recorded),
      estimates: count(e.estimated_cost_usd)
    })
  end

  @doc "The saved prices that made at least one estimate in a priced ledger."
  def priced_rate_ids(ledger),
    do: from(e in ledger, where: not is_nil(e.estimated_cost_usd), select: e.pricing_rate_id)

  def by_execution(queryable \\ all(), kind, source_id, generation) do
    where(
      queryable,
      [execution_usage: e],
      e.kind == ^kind and e.source_id == ^source_id and e.generation == ^generation
    )
  end

  # An admission's execution before its message joined a request.
  def unattached_admission(queryable \\ all(), entry_id) do
    where(
      queryable,
      [execution_usage: e],
      e.kind == "admission" and e.source_id == ^entry_id and is_nil(e.episode_id)
    )
  end

  def select_rows(queryable), do: select(queryable, [execution_usage: e], e)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
