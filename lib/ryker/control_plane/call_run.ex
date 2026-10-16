defmodule Ryker.ControlPlane.CallRun do
  @moduledoc """
  What one model call cost and where its time went, from what the call itself
  recorded: the model, the tokens the provider reported, the price (reported,
  or estimated from the price saved in Settings › Model prices for the day
  the call started when the provider sent none), whether Ryker's checks
  passed and on which attempt, each answer Ryker sent back on the way, and
  the time from the call starting to its result being saved.

  Everything here was known when the call ended. Nothing reaches forward to
  work that came after it; the timeline's later cards say that.

  `table/1` draws it the one way the timeline's model cards and a
  repository's knowledge runs both show it; `groups/1` draws the same run as
  three groups for a review of a request people were unhappy with.
  """
  use Phoenix.Component
  alias Ryker.Accounting
  alias Ryker.ControlPlane.Units
  alias Ryker.Wording
  alias Ryker.Work

  @type segment :: %{
          kind: :prepare | :model | :save,
          label: String.t(),
          short: String.t(),
          ms: non_neg_integer()
        }
  @typedoc "The provider's token counts one by one, input with what was read from cache."
  @type usage :: %{
          input: non_neg_integer(),
          output: non_neg_integer(),
          reasoning: non_neg_integer() | nil
        }
  @typedoc "An answer Ryker sent back, and the card on the timeline that shows it."
  @type correction :: %{attempt: pos_integer(), href: String.t()}
  @type t :: %{
          target: String.t() | nil,
          tokens: String.t() | nil,
          usage: usage() | nil,
          cost: String.t() | nil,
          checks: String.t() | nil,
          corrections: [correction()],
          segments: [segment()],
          total_ms: non_neg_integer() | nil
        }

  @doc "A routing call's run, from its admission attempt."
  @spec from_attempt(map() | nil) :: t() | nil
  def from_attempt(nil), do: nil

  def from_attempt(attempt) do
    measured = attempt.measurements || %{}
    usage = attempt_usage(measured)
    target = attempt.execution_target || measured["execution_target"]
    timing = attempt_timing(attempt.milestones || %{}, measured)

    %{
      target: target,
      tokens: tokens(usage),
      usage: usage_counts(usage),
      cost: cost(usage, target, attempt.inserted_at),
      checks: routing_checks(attempt.response),
      # Routing's own corrections happen inside one call and have no card.
      corrections: [],
      segments: segments(timing.before, timing.model, timing.after_model, "Checking and saving"),
      total_ms: timing.total_ms
    }
  end

  defp attempt_usage(measured) do
    %{
      recorded: measured["usage_recorded"] == true,
      input: integer(measured["usage_input_tokens"]),
      cached: integer(measured["usage_cached_input_tokens"]),
      output: integer(measured["usage_output_tokens"]),
      reasoning: integer(measured["usage_reasoning_tokens"]),
      cost_recorded: measured["usage_cost_recorded"] == true,
      cost: measured["usage_cost_usd"]
    }
  end

  # The model's own duration is the worker's measurement; everything around
  # it is read from Ryker's clock, so the parts never mix two clocks.
  defp attempt_timing(milestones, measured) do
    started = time(milestones["context_prepared"])
    received = time(milestones["response_received"])
    saved = time(milestones["committed"])
    model = integer(measured["usage_provider_ms"])
    queued = integer(measured["usage_queued_ms"]) || 0

    %{
      model: model,
      before:
        if(started && received && model,
          do: max(DateTime.diff(received, started, :millisecond) - model - queued, 0)
        ),
      after_model:
        if(received && saved, do: max(DateTime.diff(saved, received, :millisecond), 0)),
      total_ms: if(started && saved, do: DateTime.diff(saved, started, :millisecond))
    }
  end

  @doc "A work call's run, from its turn."
  @spec from_turn(map()) :: t()
  def from_turn(turn) do
    model = turn.usage_provider_ms

    # A turn starts when routing hands it over; waiting for a worker and
    # building the request are part of what the person waited for.
    before =
      if turn.remote_started_at,
        do: max(DateTime.diff(turn.remote_started_at, turn.inserted_at, :millisecond), 0)

    after_model =
      if turn.remote_finished_at && turn.accepted_at,
        do: max(DateTime.diff(turn.accepted_at, turn.remote_finished_at, :millisecond), 0)

    usage = %{
      recorded: turn.usage_recorded == true,
      input: turn.usage_input_tokens,
      cached: turn.usage_cached_input_tokens,
      output: turn.usage_output_tokens,
      reasoning: turn.usage_reasoning_tokens,
      cost_recorded: turn.usage_cost_recorded == true,
      cost: turn.usage_cost_usd
    }

    %{
      target: turn.execution_target,
      tokens: tokens(usage),
      usage: usage_counts(usage),
      cost: cost(usage, turn.execution_target, turn.inserted_at),
      checks: work_checks(turn),
      corrections: work_corrections(turn),
      segments: segments(before, model, after_model, "Checking the answer"),
      total_ms:
        if(turn.accepted_at, do: DateTime.diff(turn.accepted_at, turn.inserted_at, :millisecond))
    }
  end

  @doc """
  A background attempt's run — learning, or the self-analysis of a request a
  person was unhappy with — from the attempt and the execution ledger row its
  worker's report was metered into. The ledger outlives retention, so a pruned
  attempt still says what it spent.

  The worker measures how long the turn waited in its queue and how long the
  model ran; Ryker's clock measures the attempt from its start to the moment
  it applied the result or recorded that the worker's run stopped. What is
  left of that is Ryker's own share. The two clocks are never subtracted from
  each other.
  """
  @spec from_background(map(), map() | nil) :: t()
  def from_background(run, execution) do
    execution = ledger_row(execution)
    started = run.started_at || run.inserted_at
    target = execution[:execution_target] || get_in(run.producer || %{}, ["target"])
    usage = ledger_usage(execution)
    total = attempt_ms(started, Map.get(run, :applied_at) || run.remote_stopped_at)
    measured = worker_ms(execution)

    %{
      target: target,
      tokens: tokens(usage),
      usage: usage_counts(usage),
      cost: cost(usage, target, started),
      checks: background_checks(run),
      corrections: [],
      segments: background_segments(execution, total, measured),
      # The attempt cannot have taken less than the parts its worker measured.
      total_ms: total && max(total, measured)
    }
  end

  defp ledger_row(nil), do: %{}
  defp ledger_row(execution) when is_struct(execution), do: Map.from_struct(execution)
  defp ledger_row(execution), do: execution

  defp attempt_ms(_started, nil), do: nil
  defp attempt_ms(started, ended), do: max(DateTime.diff(ended, started, :millisecond), 0)

  defp worker_ms(execution),
    do: (execution[:usage_queued_ms] || 0) + (execution[:usage_provider_ms] || 0)

  defp ledger_usage(execution) do
    %{
      recorded: execution[:usage_recorded] == true,
      input: execution[:usage_input_tokens],
      cached: execution[:usage_cached_input_tokens],
      output: execution[:usage_output_tokens],
      reasoning: execution[:usage_reasoning_tokens],
      cost_recorded: execution[:usage_cost_recorded] == true,
      cost: execution[:usage_cost_usd]
    }
  end

  defp background_segments(execution, total, measured) do
    ryker = if total && measured > 0 && total > measured, do: total - measured

    [
      {:prepare, "Waiting in the worker's queue", "Worker queue", execution[:usage_queued_ms]},
      {:model, "Model", "Model", execution[:usage_provider_ms]},
      {:save, "Ryker preparing, checking and saving", "Prepare, check, save", ryker}
    ]
    |> measured_segments()
  end

  defp measured_segments(segments) do
    Enum.flat_map(segments, fn
      {kind, label, short, ms} when is_integer(ms) ->
        [%{kind: kind, label: label, short: short, ms: ms}]

      _unmeasured ->
        []
    end)
  end

  attr(:run, :map, required: true)

  slot :fact, doc: "A row the caller adds after the cost and checks, before the time rows" do
    attr(:label, :string, required: true)
  end

  @doc """
  What the call cost and where its time went, as recorded when it ended: a
  short two-column table a reader scans top to bottom.
  """
  def table(assigns) do
    ~H"""
    <dl class="call-run" aria-label="How this call ran">
      <div :if={@run.target}>
        <dt>Model</dt>
        <dd>{model_words(@run.target)}</dd>
      </div>
      <div :if={@run.tokens}>
        <dt>Tokens</dt>
        <dd>{@run.tokens}</dd>
      </div>
      <div :if={@run.cost}>
        <dt>Cost</dt>
        <dd title={cost_title(@run.cost)}>{@run.cost}</dd>
      </div>
      <div :if={@run.checks}>
        <dt>Checks</dt>
        <dd>
          {@run.checks}
          <span :if={@run.corrections != []} class="call-run-corrections">
            <a :for={correction <- @run.corrections} href={correction.href}>
              Attempt {correction.attempt} was sent back to be fixed ↑
            </a>
          </span>
        </dd>
      </div>
      <div :for={fact <- @fact}>
        <dt>{fact.label}</dt>
        <dd>{render_slot(fact)}</dd>
      </div>
      <div :for={segment <- @run.segments}>
        <dt>{segment.label}</dt>
        <dd>{Units.duration(segment.ms)}</dd>
      </div>
    </dl>
    """
  end

  attr(:run, :map, required: true)

  attr(:attempts, :map,
    default: nil,
    doc: "%{count:, href:}: every attempt at this call, counted from its own records"
  )

  @doc """
  The same run as three groups side by side, stacked on a narrow screen: the
  model and how many attempts there were, where the time went, and the
  tokens and what they cost (Andrew, 2026-10-15). A table that alternated
  unrelated figures was hard to read. A value nobody recorded is left out,
  never shown as zero.
  """
  def groups(assigns) do
    assigns =
      assigns
      |> assign(:model, assigns.run.target && Work.target_parts(assigns.run.target))
      |> assign(:times, times(assigns.run))
      |> assign(:usage, assigns.run[:usage])

    ~H"""
    <div class="run-groups">
      <section class="run-group" aria-label="Model and attempts">
        <h4>Model &amp; attempts</h4>
        <p :if={@model} class="run-model">{@model.model}</p>
        <p :if={@model && @model[:effort]} class="run-note">
          {String.capitalize(@model.effort)} reasoning
        </p>
        <p :if={!@model && @run.target} class="run-model">{@run.target}</p>
        <p :if={!@run.target} class="run-note">Not recorded</p>
        <p :if={@attempts} class="run-attempts">
          <span>{Wording.count(@attempts.count, "attempt")}</span>
          <a :if={@attempts[:href]} href={@attempts.href} class="inline-link"><span>View all attempts
          <span aria-hidden="true">→</span></span></a>
        </p>
      </section>
      <section class="run-group" aria-label="Timing">
        <h4>Timing</h4>
        <dl :if={@times != []} class="run-values">
          <div :for={{label, ms, total?} <- @times} class={total? && "run-total"}>
            <dt>{label}</dt>
            <dd>{Units.duration(ms)}</dd>
          </div>
        </dl>
        <p :if={@times == []} class="run-note">Not recorded</p>
      </section>
      <section class="run-group" aria-label="Tokens and cost">
        <h4>Tokens &amp; cost</h4>
        <dl :if={@usage || @run.cost} class="run-values">
          <div :if={@usage}>
            <dt>Input tokens</dt>
            <dd>{Wording.number(@usage.input)}</dd>
          </div>
          <div :if={@usage}>
            <dt>Output tokens</dt>
            <dd>{Wording.number(@usage.output)}</dd>
          </div>
          <div :if={@usage && is_integer(@usage.reasoning) && @usage.reasoning > 0}>
            <dt>Reasoning tokens</dt>
            <dd>{Wording.number(@usage.reasoning)}</dd>
          </div>
          <div :if={@run.cost} class="run-total">
            <dt>{cost_label(@run.cost)}</dt>
            <dd title={cost_title(@run.cost)}>{@run.cost}</dd>
          </div>
        </dl>
        <p :if={!@usage && !@run.cost} class="run-note">Not recorded</p>
      </section>
    </div>
    """
  end

  @doc "How long a run took and what it cost, for a line that names the run: \"25.7 s · ≈ $0.11\"."
  @spec summary(t()) :: String.t() | nil
  def summary(run) do
    [run.total_ms && Units.duration(run.total_ms), run.cost]
    |> Enum.filter(&is_binary/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  # The whole first, then the model's own time, Ryker's, and the queue.
  defp times(run) do
    parts =
      for kind <- [:model, :save, :prepare],
          %{short: label, ms: ms} <- Enum.filter(run.segments, &(&1.kind == kind)),
          do: {label, ms, false}

    if is_integer(run.total_ms), do: [{"Total", run.total_ms, true} | parts], else: parts
  end

  defp cost_label("≈" <> _rest), do: "Estimated cost"
  defp cost_label(_cost), do: "Cost"

  @doc "A model target in words: \"gpt-5.6-sol · medium reasoning\"."
  @spec model_words(String.t()) :: String.t()
  def model_words(target) do
    case Work.target_parts(target) do
      %{model: model, effort: effort} when is_binary(effort) -> "#{model} · #{effort} reasoning"
      %{model: model} -> model
      nil -> target
    end
  end

  defp cost_title("≈" <> _rest),
    do: "Estimated from the model's price per token; the provider did not report a cost."

  defp cost_title(_cost), do: "Reported by the provider."

  @doc """
  A text's size in tokens, estimated from its length: "≈ 1,204 tokens". A
  provider's own counts are measured separately; this is only a reader's
  sense of how long a part is.
  """
  @spec estimated_tokens(String.t() | {:bytes, non_neg_integer()}) :: String.t()
  def estimated_tokens({:bytes, bytes}) do
    count = ceil(bytes / 4)
    "≈ #{Wording.number(count)} #{Wording.word(count, "token")}"
  end

  def estimated_tokens(text) when is_binary(text), do: estimated_tokens({:bytes, byte_size(text)})

  defp segments(before, model, after_model, saving) do
    measured_segments([
      {:prepare, "Preparing and waiting for the worker", "Prepare and queue", before},
      {:model, "Model", "Model", model},
      {:save, saving, "Check and save", after_model}
    ])
  end

  # Codex reports fresh input and cache reads separately, so the prompt the
  # model read is their sum and the cached share is the part it did not pay
  # full price for.
  defp tokens(%{recorded: true, input: input, cached: cached, output: output} = usage)
       when is_integer(input) and is_integer(output) do
    cached = cached || 0
    read = input + cached

    [
      "#{Wording.number(read)} in",
      if(cached > 0 and read > 0, do: "#{round(cached * 100 / read)}% cached"),
      "#{Wording.number(output)} out",
      if(is_integer(usage.reasoning) and usage.reasoning > 0,
        do: "#{Wording.number(usage.reasoning)} reasoning"
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp tokens(_usage), do: nil

  defp usage_counts(%{recorded: true, input: input, cached: cached, output: output} = usage)
       when is_integer(input) and is_integer(output),
       do: %{input: input + (cached || 0), output: output, reasoning: usage.reasoning}

  defp usage_counts(_usage), do: nil

  defp cost(%{cost_recorded: true, cost: cost}, _target, _started) when not is_nil(cost),
    do: Units.money(Decimal.new(cost))

  # Priced as Usage & cost prices it: the saved price in effect on the UTC day
  # the call started. A model no saved price covers stays unpriced.
  defp cost(
         %{recorded: true, input: input, output: output} = usage,
         target,
         %DateTime{} = started
       )
       when is_integer(input) and is_integer(output) and is_binary(target) do
    case Accounting.fetch_price_in_effect(target, DateTime.to_date(started)) do
      {:ok, price} -> Units.money(Decimal.new(Accounting.estimate_cost(price, usage)), true)
      {:error, :not_found} -> nil
    end
  end

  defp cost(_usage, _target, _started), do: nil

  # Andrew, 2026-09-27, of "Checks · Passed first time": "it's unclear how
  # that will look like if they did not pass first time?" A call that needed
  # corrections says on which attempt it passed and how many corrections that
  # took, in the same words whichever model made the call.
  defp routing_checks(%{"state" => "completed", "validation_attempt" => attempt}),
    do: passed(attempt)

  defp routing_checks(_response), do: nil

  defp work_checks(%{accepted_at: %DateTime{}, candidate_attempt: attempt}), do: passed(attempt)

  defp work_checks(%{validation_history: [_ | _] = history}) do
    case List.last(history) do
      %{"verdict" => "reject"} -> "Sent back to be fixed"
      _other -> nil
    end
  end

  defp work_checks(_turn), do: nil

  # A learning result is checked by Ryker, confirmed by the worker, then
  # applied. Applied is the proof it passed; a rejected or stale attempt whose
  # answer came back did not.
  defp background_checks(%{status: :applied, candidate_attempt: attempt})
       when is_integer(attempt),
       do: passed(attempt)

  defp background_checks(%{status: :applied}), do: "Passed"

  defp background_checks(%{status: status, result_sha256: digest})
       when status in [:rejected, :stale] and is_binary(digest),
       do: "Did not pass"

  defp background_checks(_run), do: nil

  defp passed(1), do: "Passed first time"

  defp passed(attempt) when is_integer(attempt) and attempt > 1,
    do: "Passed on attempt #{attempt} · #{corrections(attempt - 1)}"

  defp passed(_attempt), do: nil

  defp corrections(1), do: "1 correction"
  defp corrections(count), do: "#{count} corrections"

  # Each answer a work turn sent back is its own card on the timeline, so the
  # line that says a call needed corrections leads to each one.
  defp work_corrections(%{id: id, validation_history: history})
       when is_binary(id) and is_list(history) do
    for %{"verdict" => "reject", "candidate_attempt" => attempt} <- history,
        is_integer(attempt),
        do: %{attempt: attempt, href: "#event-turn-#{id}-validation-#{attempt}"}
  end

  defp work_corrections(_turn), do: []

  defp time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> time
      _invalid -> nil
    end
  end

  defp time(_value), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: nil
end
