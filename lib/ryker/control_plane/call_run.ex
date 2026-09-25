defmodule Ryker.ControlPlane.CallRun do
  @moduledoc """
  What one model call cost and where its time went, from what the call itself
  recorded: the model, the tokens the provider reported, the price (reported,
  or estimated from the rate card when the provider sent none), whether
  Ryker's checks passed, and the time from the call starting to its result
  being saved.

  Everything here was known when the call ended. Nothing reaches forward to
  work that came after it; the timeline's later cards say that.
  """

  alias Ryker.Accounting.Pricing

  @type segment :: %{kind: :prepare | :model | :save, label: String.t(), ms: non_neg_integer()}
  @type t :: %{
          target: String.t() | nil,
          tokens: String.t() | nil,
          cost: String.t() | nil,
          checks: String.t() | nil,
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
      cost: cost(usage, target),
      checks: routing_checks(attempt.response),
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
      cost: cost(usage, turn.execution_target),
      checks: work_checks(turn),
      segments: segments(before, model, after_model, "Checking the answer"),
      total_ms:
        if(turn.accepted_at, do: DateTime.diff(turn.accepted_at, turn.inserted_at, :millisecond))
    }
  end

  @doc "A duration in the words the cards use: 850 ms, 16.5 s, 4 min 10 s, 2 h 5 min."
  @spec duration(non_neg_integer()) :: String.t()
  def duration(ms) when ms < 1_000, do: "#{ms} ms"
  def duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1_000, 1)} s"

  def duration(ms) when ms < 3_600_000 do
    seconds = div(ms, 1_000)
    minutes = div(seconds, 60)
    rest = rem(seconds, 60)
    if rest == 0, do: "#{minutes} min", else: "#{minutes} min #{rest} s"
  end

  def duration(ms) do
    minutes = div(ms, 60_000)
    hours = div(minutes, 60)
    rest = rem(minutes, 60)
    if rest == 0, do: "#{hours} h", else: "#{hours} h #{rest} min"
  end

  @doc "A whole number with thousands separators."
  @spec delimit(integer()) :: String.t()
  def delimit(number) when is_integer(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp segments(before, model, after_model, saving) do
    [
      {:prepare, "Preparing and waiting for the worker", before},
      {:model, "Model", model},
      {:save, saving, after_model}
    ]
    |> Enum.flat_map(fn
      {kind, label, ms} when is_integer(ms) -> [%{kind: kind, label: label, ms: ms}]
      _unmeasured -> []
    end)
  end

  # Codex reports fresh input and cache reads separately, so the prompt the
  # model read is their sum and the cached share is the part it did not pay
  # full price for.
  defp tokens(%{recorded: true, input: input, cached: cached, output: output} = usage)
       when is_integer(input) and is_integer(output) do
    cached = cached || 0
    read = input + cached

    [
      "#{delimit(read)} in",
      if(cached > 0 and read > 0, do: "#{round(cached * 100 / read)}% cached"),
      "#{delimit(output)} out",
      if(is_integer(usage.reasoning) and usage.reasoning > 0,
        do: "#{delimit(usage.reasoning)} reasoning"
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp tokens(_usage), do: nil

  defp cost(%{cost_recorded: true, cost: cost}, _target) when not is_nil(cost),
    do: "$" <> amount(cost)

  defp cost(%{recorded: true, input: input, cached: cached, output: output}, target)
       when is_integer(input) and is_integer(output) and is_binary(target) do
    model = target |> String.split("@") |> hd() |> String.split("/") |> hd()

    case Pricing.rates()[model] do
      {input_rate, cached_rate, output_rate} ->
        total =
          [
            {input, input_rate},
            {cached || 0, cached_rate},
            {output, output_rate}
          ]
          |> Enum.reduce(Decimal.new(0), fn {count, rate}, sum ->
            Decimal.add(sum, Decimal.mult(count, Decimal.new(rate)))
          end)
          |> Decimal.div(1_000_000)

        "≈ $" <> amount(total)

      nil ->
        nil
    end
  end

  defp cost(_usage, _target), do: nil

  defp amount(value) do
    value = Decimal.new(value)
    places = if Decimal.compare(value, Decimal.new("0.01")) == :lt, do: 4, else: 3
    value |> Decimal.round(places) |> Decimal.to_string(:normal)
  end

  defp routing_checks(%{"state" => "completed", "validation_attempt" => 1}),
    do: "passed first time"

  defp routing_checks(%{"state" => "completed", "validation_attempt" => attempt})
       when is_integer(attempt) and attempt > 1,
       do: "passed after #{corrections(attempt - 1)}"

  defp routing_checks(_response), do: nil

  defp work_checks(%{accepted_at: %DateTime{}, candidate_attempt: 1}), do: "passed first time"

  defp work_checks(%{accepted_at: %DateTime{}, candidate_attempt: attempt})
       when is_integer(attempt) and attempt > 1,
       do: "passed after #{corrections(attempt - 1)}"

  defp work_checks(%{validation_history: [_ | _] = history}) do
    case List.last(history) do
      %{"verdict" => "reject"} -> "returned for correction"
      _other -> nil
    end
  end

  defp work_checks(_turn), do: nil

  defp corrections(1), do: "1 correction"
  defp corrections(count), do: "#{count} corrections"

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
