defmodule Ryker.Waits.Inputs do
  @moduledoc """
  Resumes waits from admitted inputs, identically for ordinary admission and
  publication feedback. The input keeps its source, time and destination;
  waking an approval never grants it.
  """
  alias Ryker.Episodes
  alias Ryker.Ingress
  alias Ryker.Publication
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Waits.EventSubscriptions
  require Logger

  @doc "Waiting requests whose retained input or lifecycle observation can resume them."
  def pending(limit, retry_before \\ nil) do
    (queued_pending() ++ Publication.Followups.pending_waits(nil))
    |> Enum.filter(&retry_ready?(&1.episode, retry_before))
    |> Enum.uniq_by(& &1.episode.id)
    |> order_pending(retry_before)
    |> Enum.take(limit)
  end

  defp queued_pending do
    Episodes.Episode.Query.waiting_with_queued_inputs()
    |> Repo.all()
    |> Enum.flat_map(fn episode ->
      case fetch_resume(episode) do
        {:ok, resume} -> [%{episode: episode, resume: resume}]
        {:error, :not_found} -> []
      end
    end)
  end

  defp order_pending(rows, nil),
    do: Enum.sort_by(rows, &DateTime.to_unix(&1.resume.event.inserted_at, :microsecond), :desc)

  defp order_pending(rows, _retry_before),
    do: Enum.sort_by(rows, &DateTime.to_unix(&1.resume.event.occurred_at, :microsecond))

  @doc "The retained input or unadmitted check that can resume this wait."
  def fetch_pending(%Episodes.Episode{} = episode) do
    case fetch_resume(episode) do
      {:ok, resume} -> {:ok, resume}
      {:error, :not_found} -> pending_publication_input(episode)
    end
  end

  def fetch_pending(_episode), do: {:error, :not_found}

  defp pending_publication_input(episode) do
    case Publication.Followups.pending_waits(1, episode.id) do
      [%{resume: resume}] -> {:ok, resume}
      [] -> {:error, :not_found}
    end
  end

  # The earliest queued input that can resume this exact wait.
  defp fetch_resume(%Episodes.Episode{} = episode) do
    found =
      episode.id
      |> Episodes.Event.Query.by_episode_id()
      |> Episodes.Event.Query.admitted_inputs(episode.queued_input_refs)
      |> Episodes.Event.Query.ordered_by_occurred_at()
      |> Repo.all()
      |> Enum.find_value(fn event ->
        with {:ok, input} <- restore_input(event),
             true <- resumable?(episode, input) do
          %{event: event, input: input}
        else
          _not_resumable -> nil
        end
      end)

    if found, do: {:ok, found}, else: {:error, :not_found}
  end

  defp fetch_resume(_episode), do: {:error, :not_found}

  @doc "Reconciles retained inputs stranded by an earlier admission path, once per wait."
  def reconcile do
    retry_before = EventSubscriptions.failure_retried_before(Repo.now!())
    {:ok, Enum.reduce(pending(100, retry_before), 0, &reconcile_one/2)}
  end

  defp retry_ready?(_episode, nil), do: true

  defp retry_ready?(episode, retry_before) do
    case Repo.fetch(Records.Record.Query.by_ref(episode.owner_ref)) do
      {:ok, %Records.Record{wait_error: "resume_failed", updated_at: failed_at}} ->
        DateTime.compare(failed_at, retry_before) != :gt

      _other ->
        true
    end
  end

  defp reconcile_one(
         %{episode: episode, resume: %{event: %Publication.LifecycleEvent{} = event}},
         count
       ) do
    case Publication.Followups.resume_retained_wait(event.ref) do
      {:ok, %Publication.LifecycleEvent{}} ->
        count + 1

      {:ok, :idle} ->
        count

      {:error, reason} ->
        report_resume_failure(episode, reason)
        count
    end
  end

  defp reconcile_one(%{episode: episode}, count) do
    case Repo.transaction(fn -> resume_retained(episode) end) do
      {:ok, resumed} ->
        count + length(resumed)

      {:error, reason} ->
        report_resume_failure(episode, reason)

        count
    end
  end

  defp report_resume_failure(episode, reason) do
    Logger.error("retained input could not resume wait #{episode.owner_ref}: #{inspect(reason)}")
    mark_event_wait_failed(episode.owner_ref)
  end

  defp mark_event_wait_failed(ref) do
    case Repo.fetch(Records.Record.Query.by_ref(ref)) do
      {:ok, %Records.Record{kind: "event_wait"} = record} ->
        EventSubscriptions.fail(record.id, "resume_failed")

      _question_or_approval ->
        :ok
    end
  end

  defp resume_retained(episode) do
    destination = %{
      transport: episode.destination_transport,
      conversation_ref: episode.destination_conversation_ref
    }

    with :ok <- Episodes.ConversationLock.lock(destination),
         {:ok, current} <- Episodes.fetch_and_lock_current_in_transaction(episode.key) do
      case fetch_resume(current) do
        {:ok, %{input: input, event: event}} ->
          resume_retained_input(current, input, event)

        {:error, :not_found} ->
          []
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp resume_retained_input(episode, input, event) do
    case resume_in_transaction(episode, input, event, nil) do
      {:ok, transitions} -> transitions
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # These are the immutable input document's enums, never newly created atoms.
  defp restore_input(%Episodes.Event{payload: %{"payload" => document}} = event) do
    case document do
      %{"actor" => actor, "destination" => destination, "source" => source} ->
        Ingress.Input.new(%{
          actor: %{
            kind: Enum.find([:user, :app, :bot, :system], &(Atom.to_string(&1) == actor["kind"])),
            ref: actor["ref"]
          },
          content: document["content"],
          destination: %{
            transport: destination["transport"],
            conversation_ref: destination["conversation_ref"],
            thread_ref: destination["thread_ref"]
          },
          event_kind:
            Enum.find(
              [:message, :edit, :delete, :event],
              &(Atom.to_string(&1) == document["event_kind"])
            ),
          event_ref: document["event_ref"],
          native_input_id: document["native_input_id"],
          occurred_at: event.occurred_at,
          occurred_at_source:
            Enum.find(
              [:source, :ingress],
              &(Atom.to_string(&1) == document["occurred_at_source"])
            ),
          revision: document["revision"],
          source: %{kind: source["kind"], ref: source["ref"]},
          source_capabilities: document["source_capabilities"] || %{},
          source_item_ref: document["source_item_ref"]
        })

      _other ->
        {:error, :not_found}
    end
  end

  defp restore_input(_event), do: {:error, :not_found}

  @doc "Whether this input can release the episode's own wait, without changing it."
  @spec resumable?(Episodes.Episode.t(), Ingress.Input.t()) :: boolean()
  def resumable?(%Episodes.Episode{} = episode, %Ingress.Input{} = input) do
    waiting?(episode) and input_after_wait?(episode, input.occurred_at) and
      (Records.user_resumable_wait?(episode.owner_ref, input) or
         person_wakes_approval?(input, episode) or Records.matching_side_watch?(episode, input))
  end

  def resumable?(_episode, _input), do: false

  @doc """
  Answers matching watches and resumes an eligible wait under the caller's
  episode lock. Returns the resume transitions, or an error. `entry` is the
  ordinary inbox entry when there is one, for typed-answer provenance.
  """
  def resume_in_transaction(
        %Episodes.Episode{} = episode,
        %Ingress.Input{} = input,
        %Episodes.Event{} = event,
        entry
      ) do
    with {:ok, met} <- Records.answer_met_watches_in_transaction(episode, input) do
      resume_matching(episode, input, event, entry, met)
    end
  end

  def resume_in_transaction(_episode, _input, _event, _entry),
    do: {:error, :invalid_wait_input}

  defp resume_matching(episode, input, event, entry, met) do
    cond do
      not waiting?(episode) or not input_after_wait?(episode, input.occurred_at) ->
        {:ok, []}

      Records.user_resumable_wait?(episode.owner_ref, input) ->
        answer_and_resume(episode, input, event, entry)

      person_wakes_approval?(input, episode) ->
        resume(episode, input, event)

      met != [] and Records.open_event_wait?(episode.id, episode.owner_ref) ->
        resume(episode, input, event)

      true ->
        {:ok, []}
    end
  end

  defp answer_and_resume(episode, input, event, entry) do
    with :ok <- Records.InputRequests.associate_in_transaction(episode, entry),
         {:ok, transitions} <- resume(episode, input, event),
         :ok <- Records.resolve_wait_in_transaction(episode.owner_ref, input.event_kind) do
      {:ok, transitions}
    end
  end

  defp resume(episode, input, event) do
    Episodes.apply_batch_in_transaction([
      %Episodes.Command.ResumeWait{
        episode_key: episode.key,
        expected_wait: %{kind: episode.owner_kind, ref: episode.owner_ref},
        occurred_at: input.occurred_at,
        resolution_ref: event.dedupe_key,
        turn_ref: event.payload["turn_ref"]
      }
    ])
  end

  defp person_wakes_approval?(%Ingress.Input{actor: %{kind: :user}}, episode),
    do: Records.open_approval_wait?(episode.id, episode.owner_ref)

  defp person_wakes_approval?(_input, _episode), do: false

  defp waiting?(%Episodes.Episode{state: state})
       when state in [:waiting_for_input, :waiting_for_event],
       do: true

  defp waiting?(_episode), do: false

  defp input_after_wait?(episode, occurred_at) do
    wait_mark =
      episode.id
      |> Episodes.Event.Query.by_episode_id()
      |> Episodes.Event.Query.wait_marks(episode.owner_ref)
      |> Episodes.Event.Query.ordered_by_sequence_desc()
      |> Episodes.Event.Query.limit_to(1)
      |> Repo.fetch()

    case wait_mark do
      {:error, :not_found} -> false
      {:ok, event} -> DateTime.compare(occurred_at, event.occurred_at) == :gt
    end
  end
end
