defmodule Responder.Work.SubmissionBuilder do
  @moduledoc """
  Compiles one self-contained first briefing or compact same-session delta.

  The resulting `Submission` is frozen before any Coop mutation. Retries read
  its exact prompt and schema bytes from PostgreSQL rather than rebuilding them
  after code or configuration changes.
  """

  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.Episodes.{Episode, Event}
  alias Responder.Repo
  alias Responder.Work.{Final, Prompt, Session, Submission, Turn}

  @maximum_inputs 40
  @maximum_context_bytes 160 * 1_024
  @input_content_bytes 1_024
  @continuity_content_bytes 256
  @previous_delivery_bytes 2_048
  @truncation_marker "...<truncated>..."

  @spec build(%{episode: Episode.t(), session: Session.t(), turn: Turn.t()}) ::
          {:ok, Submission.t()} | {:error, term()}
  def build(%{episode: %Episode{} = episode, session: %Session{} = session, turn: %Turn{} = turn}) do
    with :ok <- active_ref_count_fits(episode.active_input_refs),
         snapshot <- input_snapshot(episode),
         :ok <- active_inputs_present(snapshot.active, episode.active_input_refs),
         previous <- previous_turn(episode.id, turn.id),
         {:ok, context} <- submission_context(episode, session, snapshot, previous) do
      Submission.new(context, Prompt.build(context), Final.json_schema(), "work-final-v1")
    end
  end

  def build(_claim), do: {:error, {:invalid_work_submission_builder, :claim}}

  defp submission_context(episode, _session, snapshot, nil),
    do: full_context(episode, snapshot, nil)

  defp submission_context(episode, session, snapshot, %{session_id: session_id} = previous)
       when session_id == session.id,
       do: continuation_context(episode, snapshot, previous)

  defp submission_context(episode, _session, snapshot, previous),
    do: full_context(episode, snapshot, previous)

  defp full_context(episode, snapshot, previous) do
    fit_full_context(
      episode,
      snapshot.active,
      snapshot.historical,
      snapshot.total_count,
      previous
    )
  end

  defp fit_full_context(episode, active, historical, total_count, previous) do
    selected =
      (active ++ historical)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(& &1.sequence)

    context = %{
      "destination" => destination(episode),
      "inputs" => %{
        "items" => Enum.map(selected, &input_document(&1, episode)),
        "omitted_count" => total_count - length(selected)
      },
      "linked_history_ref" => episode.linked_episode_id,
      "mode" => "full",
      "records" => []
    }

    context =
      if previous do
        Map.put(context, "prior_outcome", %{
          "delivery" => compact_value(previous.delivery_document, @previous_delivery_bytes),
          "submission_ref" => previous.submission_fingerprint
        })
      else
        context
      end

    context_bytes = context |> CanonicalJSON.encode!() |> byte_size()

    cond do
      context_bytes <= @maximum_context_bytes ->
        {:ok, context}

      historical != [] ->
        fit_full_context(episode, active, tl(historical), total_count, previous)

      true ->
        {:error, {:work_active_input_bytes_overflow, context_bytes, @maximum_context_bytes}}
    end
  end

  defp continuation_context(episode, snapshot, previous) do
    context = %{
      "continuity" => %{
        "first_input" => continuity_input(snapshot.first),
        "host_continuation" => %{
          "requested" => previous.continuation,
          "resume_cause" => resume_cause(episode, previous)
        },
        "previous_delivery" =>
          compact_value(previous.delivery_document, @previous_delivery_bytes),
        "prior_input_count" => snapshot.total_count
      },
      "current_inputs" => %{
        "items" => Enum.map(snapshot.active, &input_document(&1, episode)),
        "omitted_count" => 0
      },
      "destination" => destination(episode),
      "mode" => "continuation",
      "parent_submission_ref" => previous.submission_fingerprint,
      "records" => []
    }

    context_bytes = context |> CanonicalJSON.encode!() |> byte_size()

    if context_bytes <= @maximum_context_bytes,
      do: {:ok, context},
      else: {:error, {:work_active_input_bytes_overflow, context_bytes, @maximum_context_bytes}}
  end

  defp resume_cause(%Episode{active_input_refs: [_first | _rest]}, _previous), do: "new_input"

  defp resume_cause(
         %Episode{active_input_refs: []},
         %Turn{continuation: %{"kind" => "wait", "wait_kind" => "event"}}
       ),
       do: "deadline_elapsed"

  defp resume_cause(_episode, _previous), do: "host_continuation"

  defp input_snapshot(episode) do
    base =
      from(event in Event,
        where:
          event.episode_id == ^episode.id and event.kind == :input_admitted and
            event.sequence < ^episode.next_sequence
      )

    active_refs = Enum.uniq(episode.active_input_refs)
    queued_refs = Enum.uniq(episode.queued_input_refs)
    historical_slots = @maximum_inputs - length(active_refs)

    visible =
      if queued_refs == [] do
        base
      else
        from(event in base, where: event.dedupe_key not in ^queued_refs)
      end

    active =
      if active_refs == [] do
        []
      else
        Repo.all(
          from(event in visible,
            where: event.dedupe_key in ^active_refs,
            order_by: [asc: event.sequence]
          )
        )
      end

    historical =
      if historical_slots == 0 do
        []
      else
        query =
          if active_refs == [] do
            visible
          else
            from(event in visible, where: event.dedupe_key not in ^active_refs)
          end

        query
        |> order_by([event], desc: event.sequence)
        |> limit(^historical_slots)
        |> Repo.all()
        |> Enum.reverse()
      end

    %{
      active: active,
      first: Repo.one(from(event in visible, order_by: [asc: event.sequence], limit: 1)),
      historical: historical,
      total_count: Repo.aggregate(visible, :count)
    }
  end

  defp previous_turn(episode_id, turn_id) do
    Repo.one(
      from(turn in Turn,
        where:
          turn.episode_id == ^episode_id and turn.id != ^turn_id and
            not is_nil(turn.result_ref),
        order_by: [desc: turn.inserted_at, desc: turn.id],
        limit: 1
      )
    )
  end

  defp active_ref_count_fits(active_refs) do
    active_count = active_refs |> MapSet.new() |> MapSet.size()

    if active_count <= @maximum_inputs,
      do: :ok,
      else: {:error, {:work_active_input_overflow, active_count, @maximum_inputs}}
  end

  defp active_inputs_present(events, active_refs) do
    event_refs = MapSet.new(events, & &1.dedupe_key)

    if MapSet.equal?(event_refs, MapSet.new(active_refs)),
      do: :ok,
      else: {:error, :work_active_input_missing}
  end

  defp input_document(event, episode) do
    command = event.payload
    current = event.dedupe_key in episode.active_input_refs

    %{
      "actor_ref" => command["actor_ref"],
      "content" =>
        if(current,
          do: command["payload"],
          else: compact_value(command["payload"], @input_content_bytes)
        ),
      "current" => current,
      "occurred_at" => DateTime.to_iso8601(event.occurred_at),
      "revision" => command["revision"]
    }
  end

  defp continuity_input(nil), do: nil

  defp continuity_input(event) do
    %{
      "actor_ref" => event.payload["actor_ref"],
      "content" => compact_value(event.payload["payload"], @continuity_content_bytes),
      "occurred_at" => DateTime.to_iso8601(event.occurred_at)
    }
  end

  defp destination(episode) do
    %{
      "conversation_ref" => episode.destination_conversation_ref,
      "thread_ref" => episode.destination_thread_ref,
      "transport" => episode.destination_transport
    }
  end

  defp compact_value(nil, _maximum), do: nil

  defp compact_value(value, maximum) do
    encoded = CanonicalJSON.encode!(value)

    if byte_size(encoded) <= maximum do
      value
    else
      %{
        "json_preview" => bounded_preview(encoded, maximum),
        "original_bytes" => byte_size(encoded),
        "sha256" => digest(encoded),
        "truncated" => true
      }
    end
  end

  defp bounded_preview(encoded, maximum) do
    available = maximum - byte_size(@truncation_marker)
    head_bytes = div(available, 2)
    tail_bytes = available - head_bytes

    String.byte_slice(encoded, 0, head_bytes) <>
      @truncation_marker <> String.byte_slice(encoded, -tail_bytes, tail_bytes)
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
