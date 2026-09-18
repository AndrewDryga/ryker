defmodule Ryker.ControlPlane.EpisodeResponseMetrics do
  @moduledoc """
  Human-facing episode timing derived from durable message selections and outcomes.

  Review and bookkeeping timestamps are intentionally absent from this projection.
  A response exists only when a selected message reaches a delivered reply or an
  accepted result whose recorded delivery is intentionally silent.
  """

  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Work.Turn

  @terminal_states [:complete, :cancelled]

  @spec project(Episode.t(), [Entry.t()], [Turn.t()], map(), keyword()) :: map()
  def project(%Episode{} = episode, inputs, turns, input_by_ref, options \\ [])
      when is_list(inputs) and is_list(turns) and is_map(input_by_ref) do
    now = Keyword.get(options, :now, DateTime.utc_now())
    inputs_by_id = Map.new(inputs, &{&1.id, &1})
    references = local_references(inputs) |> Map.merge(input_by_ref)
    outcomes = Enum.flat_map(turns, &outcome/1)

    samples = samples(turns, inputs_by_id, references)
    received = length(inputs)
    sent = Enum.count(turns, &sent_message?/1)

    %{
      messages: %{received: received, sent: sent, total: received + sent},
      response: response(samples, received),
      wall: wall(episode, inputs, outcomes, now)
    }
  end

  defp local_references(inputs) do
    inputs
    |> Enum.flat_map(fn input ->
      [
        {input.id, input.id},
        {input.dedupe_key, input.id},
        {"ingress-turn:#{input.id}", input.id}
      ]
    end)
    |> Enum.reject(fn {reference, _id} -> is_nil(reference) end)
    |> Map.new()
  end

  defp samples(turns, inputs_by_id, references) do
    turns
    |> Enum.reduce(%{}, &measure_turn(&1, &2, inputs_by_id, references))
    |> Map.values()
  end

  defp measure_turn(%Turn{selected_input_refs: refs} = turn, measured, inputs, references)
       when is_list(refs) do
    case outcome(turn) do
      [finished_at] ->
        Enum.reduce(refs, measured, &measure_reference(&1, &2, finished_at, inputs, references))

      _pending ->
        measured
    end
  end

  defp measure_turn(_turn, measured, _inputs, _references), do: measured

  defp measure_reference(reference, measured, finished_at, inputs, references) do
    with input_id when is_binary(input_id) <- references[reference],
         %{occurred_at: %DateTime{} = started_at} <- inputs[input_id],
         milliseconds when milliseconds >= 0 <-
           DateTime.diff(finished_at, started_at, :millisecond) do
      Map.put_new(measured, input_id, milliseconds)
    else
      _unknown_or_invalid -> measured
    end
  end

  defp response([], expected) do
    %{
      average_ms: nil,
      expected: expected,
      maximum_ms: nil,
      measured: 0,
      minimum_ms: nil
    }
  end

  defp response(samples, expected) do
    %{
      average_ms: round(Enum.sum(samples) / length(samples)),
      expected: expected,
      maximum_ms: Enum.max(samples),
      measured: length(samples),
      minimum_ms: Enum.min(samples)
    }
  end

  defp wall(_episode, [], _outcomes, _now) do
    %{
      state: :unknown,
      milliseconds: nil,
      reason: "No conversation message was recorded for this episode."
    }
  end

  defp wall(episode, inputs, outcomes, now) do
    times = Enum.map(inputs, & &1.occurred_at)

    cond do
      Enum.any?(times, &is_nil/1) ->
        unknown_wall("The first message time was not recorded.")

      outcomes != [] ->
        started_at = Enum.min(times, DateTime)
        finished_at = Enum.max(outcomes, DateTime)
        milliseconds = DateTime.diff(finished_at, started_at, :millisecond)

        if milliseconds >= 0,
          do: %{state: :complete, milliseconds: milliseconds, reason: nil},
          else: unknown_wall("The recorded outcome precedes the first message.")

      episode.state not in @terminal_states ->
        milliseconds = DateTime.diff(now, Enum.min(times, DateTime), :millisecond)

        if milliseconds >= 0,
          do: %{state: :active, milliseconds: milliseconds, reason: nil},
          else: unknown_wall("The current time precedes the first message.")

      true ->
        unknown_wall("No accepted or delivered outcome time was recorded.")
    end
  end

  defp unknown_wall(reason), do: %{state: :unknown, milliseconds: nil, reason: reason}

  defp outcome(%Turn{delivered_at: %DateTime{} = at}), do: [at]

  defp outcome(%Turn{
         accepted_at: %DateTime{} = at,
         delivery_document: %{"delivery" => "none"}
       }),
       do: [at]

  defp outcome(_turn), do: []

  defp sent_message?(%Turn{
         delivered_at: %DateTime{},
         delivery_document: %{"delivery" => "reply", "message" => message}
       })
       when is_binary(message),
       do: true

  defp sent_message?(_turn), do: false
end
