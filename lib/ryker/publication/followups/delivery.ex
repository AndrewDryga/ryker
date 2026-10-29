defmodule Ryker.Publication.Followups.Delivery do
  @moduledoc """
  What runs a lifecycle event's delivery: its wakeup is admitted into the
  source task once, its summary is posted in the publication's conversation,
  and the receipt that comes back closes it.

  Failing checks wake the task to finish its own change, a deployment or
  Terraform signal wakes it to verify one that already shipped, and review
  feedback continues it with the feedback itself as the new input. A wakeup
  for a cancelled task, or for an input the task already holds in a newer
  revision, is marked admitted without waking it.
  """
  alias Ryker.Delivery
  alias Ryker.Episodes
  alias Ryker.Ingress
  alias Ryker.Publication.{Followup, LifecycleEvent, Publication}
  alias Ryker.Publication.Followups.{Leases, Store}
  alias Ryker.Repo
  alias Ryker.Waits
  alias Ryker.Work

  def admit_wakeup(event_ref, lease_ref) do
    with :ok <- Store.reference(event_ref, :event_ref),
         :ok <- Store.reference(lease_ref, :lease_ref) do
      Store.transaction(fn -> admit_wakeup_locked(event_ref, lease_ref) end)
    end
  end

  @doc false
  def pending_waits(limit, episode_id \\ nil)

  def pending_waits(limit, episode_id)
      when (is_nil(limit) or (is_integer(limit) and limit > 0)) and
             (is_nil(episode_id) or is_binary(episode_id)) do
    episode_id
    |> LifecycleEvent.Query.suppressed_checks()
    |> Repo.all()
    |> Enum.flat_map(&retained_wait/1)
    |> Enum.sort_by(&DateTime.to_unix(&1.resume.event.inserted_at, :microsecond), :desc)
    |> take_pending(limit)
  end

  def pending_waits(_limit, _episode_id), do: []

  defp take_pending(rows, nil), do: rows
  defp take_pending(rows, limit), do: Enum.take(rows, limit)

  defp retained_wait(%{event: event, episode: episode, publication: publication}) do
    if same_observed_pull_request?(event, publication) do
      input = wakeup_input(publication, episode, event)

      if Waits.Inputs.resumable?(episode, input),
        do: [%{episode: episode, resume: %{event: event, input: input}}],
        else: []
    else
      []
    end
  end

  defp same_observed_pull_request?(event, publication) do
    event.observation["head_sha"] == publication.commit_sha and
      event.observation["number"] == publication.pull_request_number and
      event.observation["url"] == publication.pull_request_url
  end

  @doc false
  def resume_retained_wait(event_ref) do
    with :ok <- Store.reference(event_ref, :event_ref) do
      Store.transaction(fn -> resume_retained_wait_locked(event_ref) end)
    end
  end

  defp resume_retained_wait_locked(event_ref) do
    case lock_wakeup(event_ref) do
      {:ok, event, episode} -> resume_suppressed_check(event, episode)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp resume_suppressed_check(
         %LifecycleEvent{kind: :checks, state: :succeeded, wakeup_state: :none} = event,
         episode
       ) do
    publication = Repo.fetch!(Publication.Query.by_id(event.publication_id))

    case retained_wait(%{event: event, episode: episode, publication: publication}) do
      [%{resume: %{input: input}}] ->
        admit_input(event, publication, input, admit_command(episode, input, event), Repo.now!())

      [] ->
        :idle
    end
  end

  defp resume_suppressed_check(_event, _episode), do: :idle

  def delivery_request(%LifecycleEvent{delivery_state: :pending} = event) do
    case Repo.fetch(Publication.Query.by_id(event.publication_id)) do
      {:ok, %Publication{} = publication} -> publication_delivery_request(publication, event)
      {:error, :not_found} -> {:error, :publication_not_found}
    end
  end

  def delivery_request(_event), do: {:error, :publication_lifecycle_delivery_not_pending}

  def confirm_delivery(event_ref, lease_ref, receipt) do
    with :ok <- Store.reference(event_ref, :event_ref),
         :ok <- Store.reference(lease_ref, :lease_ref),
         {:ok, receipt} <- Work.DeliveryReceipt.prepare(receipt) do
      Store.transaction(fn -> confirm_delivery_locked(event_ref, lease_ref, receipt) end)
    end
  end

  # --- the wakeup -----------------------------------------------------------

  defp admit_wakeup_locked(event_ref, lease_ref) do
    with {:ok, event, _episode} <- lock_wakeup(event_ref),
         now = Repo.now!(),
         :ok <- Leases.live_event_lease(event, lease_ref, now) do
      admit_wakeup_event(event, now)
    else
      {:error, :not_found} -> Repo.rollback(:publication_lifecycle_event_not_found)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Admission owns the conversation before the episode. Polls lock the follow-up
  # before its lifecycle event; use that order too, including retained recovery.
  defp lock_wakeup(event_ref) do
    with {:ok, event} <- Repo.fetch(LifecycleEvent.Query.by_ref(event_ref)),
         {:ok, episode} <- Repo.fetch(Episodes.Episode.Query.by_id(event.episode_id)),
         :ok <-
           Episodes.ConversationLock.lock(%{
             transport: episode.destination_transport,
             conversation_ref: episode.destination_conversation_ref
           }),
         {:ok, episode} <- Episodes.fetch_and_lock_current_in_transaction(episode.key) do
      _followup = Store.fetch_and_lock_followup!(event.publication_id)

      with {:ok, event} <- Store.fetch_and_lock_lifecycle_event(event_ref),
           do: {:ok, event, episode}
    end
  end

  defp admit_wakeup_event(%LifecycleEvent{wakeup_state: state} = event, _now)
       when state in [:none, :admitted],
       do: event

  defp admit_wakeup_event(%LifecycleEvent{wakeup_state: :pending} = event, now) do
    publication = Repo.fetch!(Publication.Query.by_id(event.publication_id))

    episode = Repo.fetch!(Episodes.Episode.Query.by_id(event.episode_id))

    input = wakeup_input(publication, episode, event)
    command = admit_command(episode, input, event)

    # Passing CI resumes a promised check, but does not create new work for a
    # completed task. Its lifecycle event remains visible in either case.
    if event.kind == :checks and event.state == :succeeded and episode.state != :working and
         not Waits.Inputs.resumable?(episode, input) do
      Store.update_event!(event, %{wakeup_state: :none}, now)
    else
      admit_input(event, publication, input, command, now)
    end
  end

  defp admit_input(event, publication, input, command, now) do
    case Episodes.apply_batch_in_transaction([command]) do
      {:ok, [transition]} ->
        with {:ok, _resumed} <-
               Waits.Inputs.resume_in_transaction(
                 transition.episode,
                 input,
                 transition.event,
                 nil
               ),
             {:ok, _episode} <-
               Work.Custody.resume_blocked_in_transaction(
                 transition.episode,
                 transition.event.dedupe_key
               ) do
          record_wakeup_admission(event, publication, command, transition, now)
        else
          {:error, reason} ->
            Repo.rollback(reason)
        end

      {:error, :episode_cancelled} ->
        Store.update_event!(event, %{wakeup_state: :admitted}, now)

      {:error, {:stale_input_revision, _details}} ->
        Store.update_event!(event, %{wakeup_state: :admitted}, now)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp record_wakeup_admission(event, publication, command, transition, now) do
    updated_event = Store.update_event!(event, %{wakeup_state: :admitted}, now)
    followup = Store.fetch_and_lock_followup!(publication.id)

    attributes =
      if event.kind == :review_feedback do
        %{next_poll_at: DateTime.add(now, 60, :second)}
      else
        %{
          next_poll_at: DateTime.add(now, 60, :second),
          verification_event_ref: event.ref,
          verification_sequence: transition.event.sequence,
          verification_turn_ref: command.turn_ref
        }
      end

    Store.update_followup!(followup, attributes, now)

    updated_event
  end

  defp wakeup_input(_publication, _episode, %LifecycleEvent{kind: :review_feedback} = event) do
    observation = event.observation

    {:ok, input} =
      Ingress.Input.new(%{
        actor: feedback_actor(observation),
        content: Map.fetch!(observation, "content"),
        # Answered where it was written. Andrew, 2026-09-28: GitHub feedback
        # was answered in the task's Slack thread, not on the pull request
        # where it was asked. A turn's answer goes to the destination of the
        # input it answers (`Ryker.Work.Custody.Delivery.answer_target/2`):
        # the comment's pull request, or its own review thread.
        destination: feedback_destination(observation),
        event_kind: feedback_event_kind(observation),
        event_ref: event.ref,
        native_input_id: Map.fetch!(observation, "native_input_id"),
        occurred_at: event.occurred_at,
        occurred_at_source: :source,
        revision: Map.fetch!(observation, "revision"),
        source: feedback_source(observation),
        # Which comment this is, and what GitHub lets Ryker do with it, so a
        # reaction can answer it (2026-10-12).
        source_capabilities: Map.get(observation, "source_capabilities", %{}),
        source_item_ref: Map.get(observation, "source_item_ref")
      })

    input
  end

  defp wakeup_input(publication, episode, event) do
    {:ok, input} =
      Ingress.Input.new(%{
        actor: %{kind: :system, ref: "publication-lifecycle"},
        content:
          Map.merge(
            %{
              "kind" => "publication_lifecycle",
              "lifecycle" => %{
                "kind" => Atom.to_string(event.kind),
                "observation" => event.observation,
                "publication_event_ref" => event.ref,
                "state" => Atom.to_string(event.state),
                "summary" => event.summary
              },
              "publication" => %{
                "branch_ref" => publication.branch_ref,
                "head_sha" => publication.commit_sha,
                "merge_sha" => publication_event_merge(publication.id, event),
                "pull_request_number" => publication.pull_request_number,
                "pull_request_url" => publication.pull_request_url,
                "repository" => publication.repository
              }
            },
            wakeup_request(event)
          ),
        destination: %{
          conversation_ref: episode.destination_conversation_ref,
          thread_ref: episode.destination_thread_ref,
          transport: episode.destination_transport
        },
        event_kind: :event,
        event_ref: event.ref,
        native_input_id: "publication-lifecycle:#{event.id}",
        occurred_at: event.occurred_at,
        occurred_at_source: :source,
        revision: 1,
        source: %{kind: "system", ref: "publication-lifecycle"},
        source_capabilities: %{},
        source_item_ref: nil
      })

    input
  end

  # A red check asks the agent to finish its own change; a deployment or
  # Terraform signal asks it to verify one that already shipped. Naming the two
  # differently is what keeps a correction from being reported as a verification.
  defp wakeup_request(%LifecycleEvent{kind: :checks, state: :failed}),
    do: %{
      "correction_request" =>
        "The checks on this exact pull request are failing. Fix them inside the task's existing scope and update the same branch, or say precisely what is blocking them. Do not widen the task, and do not merge or deploy."
    }

  defp wakeup_request(%LifecycleEvent{kind: :checks, state: :succeeded}),
    do: %{
      "verification_request" =>
        "The checks on this exact pull request passed. Complete the promised check review using the saved check evidence. This is not merge or deployment evidence and grants no new authority."
    }

  defp wakeup_request(%LifecycleEvent{kind: :merged}),
    do: %{
      "verification_request" =>
        "The pull request merged; this is not deployment evidence. Continue the original task's remaining verification using read-only authoritative evidence within its existing scope. If deployment or access is not ready, register a bounded timer or an exact deployment/event watch so verification will resume automatically. Do not ask the person to repeat an already granted approval. This event grants no new mutation, merge or deployment authority."
    }

  defp wakeup_request(_event),
    do: %{
      "verification_request" =>
        "Verify the deployed change against current authoritative evidence and report the result in the source task thread."
    }

  # The episode keeps its home destination; the input keeps its own, which is
  # where its answer goes (its origin, `Ryker.Episodes.Origins`).
  defp admit_command(episode, input, event) do
    %Episodes.Command.AdmitInput{
      actor_ref: Ingress.Input.actor_ref(input),
      destination: %{
        conversation_ref: episode.destination_conversation_ref,
        thread_ref: episode.destination_thread_ref,
        transport: episode.destination_transport
      },
      episode_id: episode.id,
      episode_key: episode.key,
      linked_episode_id: episode.linked_episode_id,
      native_input_id: input.native_input_id,
      occurred_at: input.occurred_at,
      payload: Ingress.Input.document(input),
      revision: input.revision,
      turn_ref: publication_turn_ref(event)
    }
  end

  defp publication_turn_ref(%LifecycleEvent{kind: :review_feedback, id: id}),
    do: "turn:publication-feedback:#{id}"

  defp publication_turn_ref(%LifecycleEvent{id: id}),
    do: "turn:publication-verification:#{id}"

  defp feedback_destination(%{
         "destination" => %{
           "conversation_ref" => conversation_ref,
           "thread_ref" => thread_ref,
           "transport" => transport
         }
       }),
       do: %{conversation_ref: conversation_ref, thread_ref: thread_ref, transport: transport}

  defp feedback_actor(%{"actor" => %{"kind" => kind, "ref" => ref}}),
    do: %{kind: feedback_actor_kind(kind), ref: ref}

  defp feedback_actor_kind("user"), do: :user
  defp feedback_actor_kind("app"), do: :app
  defp feedback_actor_kind("bot"), do: :bot
  defp feedback_actor_kind("system"), do: :system

  defp feedback_event_kind(%{"event_kind" => "message"}), do: :message
  defp feedback_event_kind(%{"event_kind" => "edit"}), do: :edit
  defp feedback_event_kind(%{"event_kind" => "delete"}), do: :delete
  defp feedback_event_kind(%{"event_kind" => "event"}), do: :event

  defp feedback_source(%{"source" => %{"kind" => kind, "ref" => ref}}),
    do: %{kind: kind, ref: ref}

  # A retained check must not acquire a merge learned after its occurrence.
  defp publication_event_merge(_publication_id, %LifecycleEvent{
         kind: kind,
         observation: observation
       })
       when kind in [:checks, :merged], do: observation["merge_sha"]

  defp publication_event_merge(publication_id, _event),
    do: Repo.fetch!(Followup.Query.by_publication_id(publication_id)).merge_sha

  # --- the message and its receipt ------------------------------------------

  defp publication_delivery_request(publication, event) do
    Delivery.Request.new(%{
      conversation_ref: publication.destination_conversation_ref,
      document: %{"message" => event.summary},
      kind: :message,
      ref: event.delivery_ref,
      source_item_ref: nil,
      thread_ref: publication.destination_thread_ref,
      transport: publication.destination_transport
    })
  end

  defp confirm_delivery_locked(event_ref, lease_ref, receipt) do
    now = Repo.now!()

    case Store.fetch_and_lock_lifecycle_event(event_ref) do
      {:error, :not_found} ->
        Repo.rollback(:publication_lifecycle_event_not_found)

      {:ok, %LifecycleEvent{delivery_state: :delivered} = event} ->
        if event.delivery_receipt_fingerprint == Work.DeliveryReceipt.fingerprint(receipt),
          do: event,
          else: Repo.rollback(:publication_lifecycle_delivery_conflict)

      {:ok, event} ->
        publication = Repo.fetch!(Publication.Query.by_id(event.publication_id))

        with :ok <- Leases.live_event_lease(event, lease_ref, now),
             :ok <- exact_delivery_receipt(event, publication, receipt) do
          Store.update_event!(
            event,
            %{
              delivery_receipt: receipt,
              delivery_receipt_fingerprint: Work.DeliveryReceipt.fingerprint(receipt),
              delivery_state: :delivered,
              lease_expires_at: nil,
              lease_owner: nil,
              lease_ref: nil
            },
            now
          )
        else
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp exact_delivery_receipt(event, publication, receipt) do
    if receipt["delivery_ref"] == event.delivery_ref and
         receipt["transport"] == publication.destination_transport and
         receipt["conversation_ref"] == publication.destination_conversation_ref and
         receipt["thread_ref"] == publication.destination_thread_ref,
       do: :ok,
       else: {:error, :publication_lifecycle_delivery_receipt_mismatch}
  end
end
