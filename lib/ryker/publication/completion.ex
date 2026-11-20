defmodule Ryker.Publication.Completion do
  @moduledoc "Returns a task's actual publication outcome to Work at the request's reply destination."
  alias Ryker.Episodes
  alias Ryker.Ingress
  alias Ryker.Publication.Publication
  alias Ryker.Repo
  alias Ryker.Work

  @source "publication-result"

  def task?(%Publication{review_request_ref: "task-readiness:" <> _}), do: true
  def task?(_publication), do: false

  @doc "The unchanged workspace a publication-outcome turn is reporting."
  def report_source(%Work.Turn{} = turn) do
    refs = report_input_refs(turn)

    payloads =
      turn.episode_id
      |> Episodes.Event.Query.by_episode_id()
      |> Episodes.Event.Query.admitted_inputs(refs)
      |> Episodes.Event.Query.select_payloads()
      |> Repo.all()

    same_episode_turn(candidate_id(payloads), turn.episode_id)
  end

  @doc "Frozen publication sources for a bounded set of historical turns; never uses current inputs."
  def report_sources(turns) do
    inputs = Enum.flat_map(turns, &(&1.selected_input_refs || []))
    episodes = Enum.map(turns, & &1.episode_id) |> Enum.uniq()

    admissions =
      episodes
      |> Episodes.Event.Query.by_episode_ids()
      |> Episodes.Event.Query.admitted_inputs(inputs)
      |> Episodes.Event.Query.select_admissions()
      |> Repo.all()
      |> Map.new(fn {episode, ref, payload} -> {{episode, ref}, payload} end)

    pairs =
      Enum.flat_map(turns, fn turn ->
        payloads =
          Enum.map(turn.selected_input_refs || [], &Map.get(admissions, {turn.episode_id, &1}))

        case Ecto.UUID.cast(candidate_id(payloads)) do
          {:ok, id} -> [{turn.id, turn.episode_id, id}]
          :error -> []
        end
      end)

    sources =
      pairs
      |> Enum.map(&elem(&1, 2))
      |> Work.Turn.Query.by_ids()
      |> Work.Turn.Query.select_artifact_evidence()
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Map.new(
      Enum.flat_map(pairs, fn {reply, episode, id} ->
        with %Work.Turn{episode_id: ^episode, operational_pruned_at: nil} = source <- sources[id],
             true <-
               match?(%DateTime{}, source.accepted_at) or
                 Work.Custody.completion_matches?(source, source.completion_receipt) do
          [{reply, source}]
        else
          _missing -> []
        end
      end)
    )
  end

  defp candidate_id([
         %{
           "payload" => %{
             "actor" => %{"kind" => "system", "ref" => @source},
             "source" => %{"kind" => "system", "ref" => @source},
             "content" => %{"kind" => "publication_result", "candidate_turn_id" => id}
           }
         }
       ]),
       do: id

  defp candidate_id(_payloads), do: nil

  defp report_input_refs(%Work.Turn{selected_input_refs: refs}) when is_list(refs) and refs != [],
    do: refs

  defp report_input_refs(%Work.Turn{episode_id: episode_id}) do
    case Repo.fetch(Episodes.Episode.Query.by_id(episode_id)) do
      {:ok, episode} -> episode.active_input_refs
      {:error, :not_found} -> []
    end
  end

  # Admission locks the conversation and episode before publication custody.
  def lock_task_in_transaction(publication_ref) do
    with {:ok, publication} <- Repo.fetch(Publication.Query.by_ref(publication_ref)),
         {:ok, episode} <- Repo.fetch(Episodes.Episode.Query.by_id(publication.episode_id)),
         :ok <- Episodes.ConversationLock.lock(episode_destination(episode)),
         {:ok, _episode} <- Episodes.fetch_and_lock_current_in_transaction(episode.key) do
      :ok
    else
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def reply_destination(publication, episode) do
    turn_destination(source_turn(publication), episode)
  end

  defp turn_destination(%Work.Turn{delivery_target: %{} = target}, _episode),
    do: %{
      conversation_ref: target["conversation_ref"],
      thread_ref: target["thread_ref"],
      transport: target["transport"]
    }

  defp turn_destination(_turn, episode), do: episode_destination(episode)

  # A new input, never an edit to an accepted reply. Its stable identity makes
  # a repeated receipt/retry inert and its origin follows GitHub feedback back
  # to GitHub instead of silently moving the answer to the task's Slack home.
  def resume_in_transaction(publication, now) do
    with true <- task?(publication),
         %Work.Turn{} = turn <- source_turn(publication) do
      resume(publication, turn, now, report_content(publication))
    else
      _no_task -> :ok
    end
  end

  # Drain one destination only after the prior reply settles. Admitting all
  # pending threads together lets Work coalesce them into one GitHub reply.
  # The query is durable; episode changes wake the publication worker, whose
  # safety poll also recovers a restart between delivery and this admission.
  def resume_pending(conflicts) do
    with {publication, _turn} <- Repo.peek(Publication.Query.pending_reply(conflicts)),
         {:ok, :ok} <-
           Repo.transaction(fn -> resume_pending_locked(publication.ref, conflicts) end) do
      :ok
    else
      nil -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp resume_pending_locked(ref, conflicts) do
    locked = ref |> Publication.Query.by_ref() |> Publication.Query.lock_for_update()
    pending = ref |> Publication.Query.by_ref() |> Publication.Query.pending_reply(conflicts)

    with :ok <- lock_task_in_transaction(ref),
         {:ok, _publication} <- Repo.fetch(locked),
         {current, turn} <- Repo.peek(pending) do
      resume(current, turn, Repo.now!(), report_content(current))
    else
      nil -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  def reject_candidate_in_transaction(publication, turn, code) do
    outcome =
      content(publication)
      |> Map.put("status", "not_published")
      |> Map.put("error_code", code)
      |> Map.put("published_revision", %{})

    resume(publication, turn, Repo.now!(), outcome)
  end

  def resume_superseded_in_transaction(publication, latest, now) do
    with %Work.Turn{} = original <- source_turn(publication),
         %Work.Turn{} = baseline <- source_turn(latest),
         {:ok, episode} <- Repo.fetch(Episodes.Episode.Query.by_id(publication.episode_id)),
         false <- turn_destination(original, episode) == turn_destination(baseline, episode) do
      outcome =
        content(publication)
        |> Map.put("candidate_turn_id", baseline.id)
        |> Map.put("superseded_by_review_generation", latest.review_generation)

      resume(publication, original, now, outcome)
    else
      _same_destination -> :ok
    end
  end

  defp resume(publication, %Work.Turn{episode_id: episode_id} = turn, now, outcome)
       when episode_id == publication.episode_id do
    with {:ok, %Work.Result{delivery: :reply}} <-
           Work.ValidationIntent.result(turn.validation_intent),
         {:ok, episode} <- Repo.fetch(Episodes.Episode.Query.by_id(publication.episode_id)),
         false <- episode.state == :cancelled or not is_nil(episode.history_pruned_at) do
      admit(publication, episode, turn, now, Map.put_new(outcome, "candidate_turn_id", turn.id))
    else
      _no_reply -> :ok
    end
  end

  defp admit(publication, episode, turn, now, outcome) do
    identity =
      "#{@source}:#{publication.id}:g#{publication.review_generation}:#{turn.id}:#{outcome["status"]}"

    existing =
      episode.id
      |> Episodes.Origin.Query.by_episode_id()
      |> Episodes.Origin.Query.by_native_input_id(identity)

    if Repo.exists?(existing), do: :ok, else: admit_once(episode, turn, identity, now, outcome)
  end

  defp admit_once(episode, turn, identity, now, outcome) do
    with {:ok, input} <-
           Ingress.Input.new(%{
             actor: %{kind: :system, ref: @source},
             content: outcome,
             destination: turn_destination(turn, episode),
             event_kind: :event,
             event_ref: identity,
             native_input_id: identity,
             occurred_at: now,
             occurred_at_source: :source,
             revision: 1,
             source: %{kind: "system", ref: @source},
             source_capabilities: %{},
             source_item_ref: nil
           }),
         {:ok, _transitions} <-
           Episodes.apply_batch_in_transaction([
             %Episodes.Command.AdmitInput{
               actor_ref: Ingress.Input.actor_ref(input),
               destination: episode_destination(episode),
               episode_id: episode.id,
               episode_key: episode.key,
               execution_mode: episode.execution_mode,
               linked_episode_id: episode.linked_episode_id,
               native_input_id: input.native_input_id,
               occurred_at: now,
               payload: Ingress.Input.document(input),
               revision: 1,
               turn_ref: "turn:#{identity}"
             }
           ]) do
      :ok
    end
  end

  defp report_content(publication) do
    query =
      Work.Turn.Query.latest_publication_candidate(publication.episode_id, publication.repository)

    baseline =
      case Repo.peek(query) do
        {turn, _session} -> turn
        nil -> source_turn(publication)
      end

    Map.put(content(publication), "candidate_turn_id", baseline.id)
  end

  defp content(publication) do
    %{
      "kind" => "publication_result",
      "publication_ref" => publication.ref,
      "review_generation" => publication.review_generation,
      "review" =>
        Map.take(publication.review_document || %{}, ~w(gate rebase not_publishable_reasons)),
      "status" => Atom.to_string(publication.status),
      "discarded_reason" =>
        publication.discarded_reason && Atom.to_string(publication.discarded_reason),
      "published_revision" =>
        Map.take(
          publication.publication_receipt || %{},
          ~w(commit_sha pull_request_url target_observation)
        ),
      "error_code" => publication.last_error_code,
      "request" =>
        "Continue the original request using this publication outcome. Read get_work_state for the saved review and receipt, then explain the actual result in your own words. Do not change files merely to report the outcome."
    }
  end

  defp source_turn(%Publication{
         episode_id: episode_id,
         review_request_ref: "task-readiness:" <> id
       }) do
    same_episode_turn(id, episode_id)
  end

  defp source_turn(_publication), do: nil

  defp same_episode_turn(id, episode_id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Work.Turn{episode_id: ^episode_id} = turn <- Repo.peek(Work.Turn.Query.by_id(id)) do
      turn
    else
      _invalid -> nil
    end
  end

  def episode_destination(episode),
    do: %{
      conversation_ref: episode.destination_conversation_ref,
      thread_ref: episode.destination_thread_ref,
      transport: episode.destination_transport
    }
end
