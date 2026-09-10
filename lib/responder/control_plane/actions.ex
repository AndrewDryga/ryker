defmodule Responder.ControlPlane.Actions do
  @moduledoc false

  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.ControlPlane.{CardLabDelivery, CardLabFeedback, ConversationLab}
  alias Responder.ControlPlane.InstructionSettings
  alias Responder.Episodes
  alias Responder.Episodes.{Command, Episode}
  alias Responder.Ingress.WorkProfile
  alias Responder.Operator.{EpisodeReviews, Failures}
  alias Responder.Publication.Custody, as: PublicationCustody
  alias Responder.Publication.{Followups, Operator, Publication}
  alias Responder.Repo
  alias Responder.Retention.Operator, as: RetentionOperator
  alias Responder.Slack.{WorkDiff, WorkRecord}

  alias Responder.State.{
    Automations,
    Behaviors,
    InputRequests,
    Memories,
    Record,
    Schedule,
    Schedules,
    SlackPostOffers,
    TaskOffers
  }

  alias Responder.Work.{Custody, Session, Turn}

  @actor_ref "control-plane:local"
  @lab_actor_ref "local-operator"

  @spec callbacks(WorkProfile.t() | nil, map(), map(), (Schedule.t() -> term()) | nil) :: map()
  def callbacks(
        work_profile \\ nil,
        task_policies \\ %{},
        work_view_options \\ %{},
        schedule_policy_resolver \\ nil
      ) do
    %{
      act_on_lab_record: lab_record_action(work_profile, task_policies),
      delete_lab_message: lab_message_deleter(work_profile),
      discard_retention: &discard_retention/1,
      edit_lab_message: lab_message_editor(work_profile),
      forget_memory: &Memories.forget/1,
      resolve_episode: &resolve_episode/1,
      resolve_memory_review: &resolve_memory_review/3,
      rearm_admission: &retry_failure("admission", &1),
      rearm_delivery: &retry_failure("delivery", &1),
      rearm_emisar: &retry_failure("emisar", &1),
      rearm_retention: &retry_failure("retention", &1),
      rearm_slack_incident: &retry_failure("slack_incident", &1),
      rearm_slack_interaction: &retry_failure("slack_interaction", &1),
      react_to_lab_message: &ConversationLab.react_to_message/4,
      record_card_feedback: &CardLabFeedback.record/4,
      describe_card_slack_target: &CardLabDelivery.describe_target/2,
      post_card_to_slack: &CardLabDelivery.enqueue/5,
      transition_card_slack_post: &CardLabDelivery.transition/3,
      retry_card_slack_post: &CardLabDelivery.retry/2,
      retry_work: &retry_work/2,
      review_episode: &EpisodeReviews.review(&1, @actor_ref),
      run_schedule: run_schedule(schedule_policy_resolver),
      send_lab_message: lab_sender(work_profile),
      set_behavior_status: &Behaviors.set_status/2,
      save_instructions: &InstructionSettings.save/3,
      set_schedule_status: &Schedules.set_status/2,
      view_lab_task_record: lab_task_record_view(work_view_options)
    }
  end

  defp run_schedule(policy_resolver) when is_function(policy_resolver, 1) do
    fn schedule_ref ->
      case Repo.get_by(Schedule, ref: schedule_ref) do
        %{revision: revision} ->
          action_ref = "control-plane:run-schedule:#{schedule_ref}:#{revision}"
          Schedules.run_now_for_operator(schedule_ref, @actor_ref, action_ref, policy_resolver)

        nil ->
          {:error, :schedule_not_found}
      end
    end
  end

  defp run_schedule(_policy_resolver) do
    fn _schedule_ref -> {:error, :schedule_policy_unavailable} end
  end

  defp resolve_memory_review(review_ref, action, replacement) do
    case Repo.one(
           from(review in Responder.State.MemoryReviewItem, where: review.ref == ^review_ref)
         ) do
      %Responder.State.MemoryReviewItem{workspace_ref: workspace_ref} ->
        Memories.resolve_review(review_ref, action, @actor_ref, workspace_ref, replacement)

      nil ->
        {:error, :memory_review_not_found}
    end
  end

  defp retry_failure(kind, ref) do
    Failures.retry(kind, ref,
      action_ref: "control-plane:retry:#{Ecto.UUID.generate()}",
      actor_ref: @actor_ref
    )
  end

  defp retry_work(ref, expected_recovery) do
    Failures.retry("work", ref,
      action_ref: "control-plane:retry:#{Ecto.UUID.generate()}",
      actor_ref: @actor_ref,
      expected_recovery: expected_recovery
    )
  end

  defp resolve_episode(episode_key) do
    episode_key
    |> then(&Repo.get_by(Episode, key: &1))
    |> resolve_episode_record()
  end

  defp resolve_episode_record(
         %Episode{state: :working, owner_kind: :turn, owner_ref: turn_ref} = episode
       ) do
    episode.id
    |> then(&Repo.get_by(Turn, episode_id: &1, turn_ref: turn_ref))
    |> resolve_blocked_episode(episode, turn_ref)
  end

  defp resolve_episode_record(
         %Episode{state: state, owner_kind: owner_kind, owner_ref: owner_ref} = episode
       )
       when state in [:waiting_for_input, :waiting_for_event] and owner_kind in [:input, :event] do
    %Command.CancelEpisode{
      cancel_ref: resolve_action_ref(),
      episode_key: episode.key,
      expected_owner: %{kind: owner_kind, ref: owner_ref},
      occurred_at: now(),
      reason: "Closed by the local operator as no longer needed."
    }
    |> Episodes.apply()
    |> resolved_episode_result()
  end

  defp resolve_episode_record(%Episode{}), do: {:error, :episode_not_resolvable}
  defp resolve_episode_record(nil), do: {:error, :episode_not_found}

  defp resolve_blocked_episode(%Turn{status: :blocked}, episode, turn_ref) do
    Custody.request_cancel(
      episode.id,
      episode.key,
      turn_ref,
      resolve_action_ref(),
      "Closed by the local operator as no longer needed."
    )
  end

  defp resolve_blocked_episode(_not_blocked, _episode, _turn_ref),
    do: {:error, :episode_not_resolvable}

  defp resolved_episode_result({:ok, transition}), do: {:ok, transition.episode}
  defp resolved_episode_result({:error, _reason} = error), do: error
  defp resolve_action_ref, do: "control-plane:resolve:#{Ecto.UUID.generate()}"

  defp lab_task_record_view(work_view_options) do
    fn conversation_id, record_ref, view, params ->
      with {:ok, conversation_ref} <- ConversationLab.conversation_ref(conversation_id),
           {:ok, record, target} <- lab_record_context(conversation_ref, record_ref),
           %Record{kind: "task_offer", status: :confirmed} <- record,
           {:ok, episode} <- task_episode(record, target) do
        build_lab_task_record(record, episode, view, params, work_view_options)
      else
        %Record{} -> {:error, :conversation_lab_task_mismatch}
        {:error, _reason} = error -> error
      end
    end
  end

  defp build_lab_task_record(record, episode, view, params, _options)
       when view in [:timeline, :evidence, :handoff, :postmortem] and params == %{} do
    with {:ok, %{"message" => body}} <- WorkRecord.build_episode(record, episode, view) do
      {:ok,
       %{
         body: body,
         kind: view,
         navigation: [],
         title: lab_task_record_title(view)
       }}
    end
  end

  defp build_lab_task_record(record, episode, :diff, params, options) do
    with {:ok, %{offset: offset, snapshot_digest: expected_digest}} <- diff_params(params),
         {:ok, coop_api, coop_client} <- work_view_options(options),
         %Session{coop_session_id: session_id} when is_binary(session_id) <-
           latest_bound_session(episode.id),
         {:ok, changes} <-
           coop_api.get_changes_page(coop_client, session_id, offset, WorkDiff.page_bytes()),
         :ok <- exact_snapshot(expected_digest, offset, changes["patch_digest"]),
         {:ok, %{"work_diff" => diff}} <- WorkDiff.render(record.ref, changes) do
      {:ok,
       %{
         body: diff["message"],
         kind: :diff,
         navigation: diff_navigation(diff),
         title: "Workspace diff"
       }}
    else
      nil -> {:error, :conversation_lab_work_changes_not_available}
      {:error, _reason} = error -> error
      _invalid -> {:error, :conversation_lab_work_changes_not_available}
    end
  end

  defp build_lab_task_record(_record, _episode, _view, _params, _options),
    do: {:error, :conversation_lab_task_view_invalid}

  defp lab_task_record_title(:timeline), do: "Task timeline"
  defp lab_task_record_title(:evidence), do: "Task evidence"
  defp lab_task_record_title(:handoff), do: "Task handoff"
  defp lab_task_record_title(:postmortem), do: "Incident postmortem"

  defp latest_bound_session(episode_id) do
    Repo.one(
      from(session in Session,
        where: session.episode_id == ^episode_id and not is_nil(session.coop_session_id),
        order_by: [desc: session.generation],
        limit: 1
      )
    )
  end

  defp work_view_options(%{coop_api: api, coop_client: client})
       when is_atom(api) and not is_nil(client) do
    if Code.ensure_loaded?(api) and function_exported?(api, :get_changes_page, 4),
      do: {:ok, api, client},
      else: {:error, :conversation_lab_work_changes_not_configured}
  end

  defp work_view_options(_options),
    do: {:error, :conversation_lab_work_changes_not_configured}

  defp diff_params(%{offset: offset, snapshot_digest: digest})
       when is_integer(offset) and offset in 0..1_073_741_824 and
              (is_nil(digest) or is_binary(digest)),
       do: {:ok, %{offset: offset, snapshot_digest: digest}}

  defp diff_params(_params), do: {:error, :conversation_lab_task_view_invalid}

  defp exact_snapshot(nil, 0, digest) when is_binary(digest), do: :ok
  defp exact_snapshot(digest, _offset, digest) when is_binary(digest), do: :ok
  defp exact_snapshot(_expected, _offset, _actual), do: {:error, :work_diff_snapshot_changed}

  defp diff_navigation(diff) do
    previous = max(diff["patch_offset"] - WorkDiff.page_bytes(), 0)

    []
    |> maybe_diff_page(diff["patch_offset"] > 0, "Previous", previous, diff["patch_digest"])
    |> maybe_diff_page(
      diff["patch_has_more"],
      "Next",
      diff["patch_next_offset"],
      diff["patch_digest"]
    )
  end

  defp maybe_diff_page(pages, true, label, offset, digest),
    do: pages ++ [%{label: label, offset: offset, snapshot_digest: digest}]

  defp maybe_diff_page(pages, false, _label, _offset, _digest), do: pages

  defp lab_record_action(work_profile, task_policies) when is_map(task_policies) do
    fn conversation_id, record_ref, action, choice_index ->
      with {:ok, conversation_ref} <- ConversationLab.conversation_ref(conversation_id),
           {:ok, record, target} <- lab_record_context(conversation_ref, record_ref),
           :ok <- lab_action_arguments(action, choice_index) do
        perform_lab_record_action(
          record,
          target,
          action,
          choice_index,
          work_profile,
          task_policies,
          lab_action_ref(conversation_id, record_ref, action, choice_index)
        )
      end
    end
  end

  defp lab_record_context(conversation_ref, record_ref) do
    case fetch_lab_record(record_ref) do
      {%Record{} = record, %Episode{} = episode, %Turn{} = turn} ->
        lab_record_target(record, episode, turn, conversation_ref)

      nil ->
        {:error, :conversation_lab_record_not_found}
    end
  end

  defp fetch_lab_record(record_ref) do
    Repo.one(
      from(record in Record,
        join: episode in Episode,
        on: episode.id == record.episode_id,
        join: turn in Turn,
        on: turn.id == record.turn_id and turn.episode_id == record.episode_id,
        where: record.ref == ^record_ref,
        select: {record, episode, turn}
      )
    )
  end

  defp lab_record_target(
         %Record{} = record,
         %Episode{} = episode,
         %Turn{
           status: :settled,
           external_receipt: receipt,
           delivery_document: document
         } = turn,
         conversation_ref
       )
       when is_map(receipt) and is_map(document) do
    record_refs = get_in(document, ["outcome", "record_refs"])

    if lab_record_destination?(episode, turn, receipt, conversation_ref) and
         is_list(record_refs) and record.ref in record_refs do
      {:ok, record, lab_target(receipt, conversation_ref)}
    else
      {:error, :conversation_lab_record_mismatch}
    end
  end

  defp lab_record_target(_record, _episode, _turn, _conversation_ref),
    do: {:error, :conversation_lab_record_mismatch}

  defp lab_record_destination?(episode, turn, receipt, conversation_ref) do
    episode.destination_transport == "control_plane" and
      episode.destination_conversation_ref == conversation_ref and
      episode.destination_thread_ref == conversation_ref and
      receipt["delivery_ref"] == turn.delivery_ref and
      exact_lab_receipt?(receipt, conversation_ref)
  end

  defp lab_action_arguments(:answer_input, choice_index)
       when is_integer(choice_index) and choice_index in 0..9,
       do: :ok

  defp lab_action_arguments(action, %{generation: generation, publication_ref: publication_ref})
       when action in [
              :retry_task_publication,
              :update_task_publication,
              :discard_task_publication
            ] and is_integer(generation) and generation > 0 and is_binary(publication_ref) and
              byte_size(publication_ref) in 1..1_024,
       do: :ok

  defp lab_action_arguments(action, %{publication_ref: publication_ref})
       when action in [:approve_task_publication, :check_task_publication] and
              is_binary(publication_ref) and byte_size(publication_ref) in 1..1_024,
       do: :ok

  defp lab_action_arguments(action, nil)
       when action in [
              :confirm_task,
              :open_incident,
              :confirm_memory,
              :confirm_behavior,
              :confirm_schedule,
              :confirm_automation,
              :confirm_post,
              :review_publication,
              :stop_task,
              :close_task,
              :approve_publication,
              :check_publication
            ],
       do: :ok

  defp lab_action_arguments(_action, _choice_index),
    do: {:error, :conversation_lab_record_action_invalid}

  defp perform_lab_record_action(
         %Record{kind: "task_offer", payload: %{"kind" => "engineering"} = payload} = record,
         target,
         :confirm_task,
         nil,
         _work_profile,
         task_policies,
         action_ref
       ) do
    case Map.fetch(task_policies, payload["repository"]) do
      {:ok, %{name: name, digest: digest} = policy} ->
        TaskOffers.confirm(%{
          actor_ref: @actor_ref,
          confirmation_ref: action_ref,
          occurred_at: now(),
          policy:
            %{name: name, digest: digest}
            |> maybe_put(:repository_ref, Map.get(policy, :repository_ref))
            |> maybe_put(:repository_context, Map.get(policy, :repository_context)),
          record_ref: record.ref,
          target: target
        })

      :error ->
        {:error, :conversation_lab_task_policy_not_configured}
    end
  end

  defp perform_lab_record_action(
         %Record{kind: "task_offer", payload: %{"kind" => "incident"} = payload} = record,
         target,
         :open_incident,
         nil,
         %WorkProfile{} = work_profile,
         _task_policies,
         action_ref
       ) do
    if is_nil(payload["repository"]) or payload["repository"] == context_ref(work_profile) do
      TaskOffers.confirm(%{
        actor_ref: @actor_ref,
        confirmation_ref: action_ref,
        occurred_at: now(),
        policy:
          %{
            name: work_profile.policy,
            digest: work_profile.policy_digest,
            repository_ref: work_profile.repository_ref
          }
          |> maybe_put(
            :repository_context,
            WorkProfile.repository_context_document(work_profile.repository_context)
          ),
        record_ref: record.ref,
        target: target
      })
    else
      {:error, :conversation_lab_incident_repository_mismatch}
    end
  end

  defp perform_lab_record_action(
         %Record{kind: "task_offer", payload: %{"kind" => "incident"}},
         _target,
         :open_incident,
         nil,
         _work_profile,
         _task_policies,
         _action_ref
       ),
       do: {:error, :conversation_lab_not_configured}

  defp perform_lab_record_action(
         %Record{kind: "memory_offer"} = record,
         target,
         :confirm_memory,
         nil,
         _work_profile,
         _task_policies,
         action_ref
       ),
       do: confirm_record(Memories, record, target, action_ref)

  defp perform_lab_record_action(
         %Record{kind: kind} = record,
         target,
         :confirm_behavior,
         nil,
         _work_profile,
         _task_policies,
         action_ref
       )
       when kind in ["preference_offer", "guidance_offer", "standing_assignment_offer"],
       do: confirm_record(Behaviors, record, target, action_ref)

  defp perform_lab_record_action(
         %Record{kind: "schedule_offer"} = record,
         target,
         :confirm_schedule,
         nil,
         _work_profile,
         _task_policies,
         action_ref
       ),
       do: confirm_record(Schedules, record, target, action_ref)

  defp perform_lab_record_action(
         %Record{kind: "automation_change_offer"} = record,
         target,
         :confirm_automation,
         nil,
         _work_profile,
         _task_policies,
         action_ref
       ),
       do: confirm_record(Automations, record, target, action_ref)

  defp perform_lab_record_action(
         %Record{kind: "slack_post_offer"} = record,
         target,
         :confirm_post,
         nil,
         _work_profile,
         _task_policies,
         action_ref
       ) do
    SlackPostOffers.confirm(%{
      actor_ref: @actor_ref,
      confirmation_ref: action_ref,
      occurred_at: now(),
      record_ref: record.ref,
      target: target
    })
  end

  defp perform_lab_record_action(
         %Record{kind: "publication_offer"} = record,
         target,
         :review_publication,
         nil,
         _work_profile,
         _task_policies,
         action_ref
       ) do
    PublicationCustody.request_review(%{
      actor_ref: @actor_ref,
      occurred_at: now(),
      record_ref: record.ref,
      request_ref: action_ref,
      target: target
    })
  end

  defp perform_lab_record_action(
         %Record{kind: "input_request"} = record,
         target,
         :answer_input,
         choice_index,
         _work_profile,
         _task_policies,
         action_ref
       ) do
    InputRequests.answer(%{
      actor_ref: @lab_actor_ref,
      choice_index: choice_index,
      occurred_at: now(),
      record_ref: record.ref,
      response_ref: action_ref,
      target: target
    })
  end

  defp perform_lab_record_action(
         %Record{kind: "task_offer", status: :confirmed} = record,
         target,
         :stop_task,
         nil,
         _work_profile,
         _task_policies,
         action_ref
       ) do
    with {:ok, episode} <- task_episode(record, target),
         true <- episode.state == :working and episode.owner_kind == :turn,
         {:ok, result} <-
           Custody.request_stop(
             episode.id,
             episode.key,
             episode.owner_ref,
             action_ref,
             "The local operator stopped the current run. Reply in this Lab conversation to continue."
           ) do
      {:ok, result}
    else
      false -> {:error, :conversation_lab_task_control_stale}
      {:error, _reason} = error -> error
    end
  end

  defp perform_lab_record_action(
         %Record{kind: "task_offer", status: :confirmed} = record,
         target,
         action,
         %{generation: expected_generation, publication_ref: publication_ref},
         _work_profile,
         _task_policies,
         action_ref
       )
       when action in [
              :retry_task_publication,
              :update_task_publication,
              :discard_task_publication
            ] do
    recovery_action =
      case action do
        :retry_task_publication -> :retry
        :update_task_publication -> :update
        :discard_task_publication -> :discard
      end

    with {:ok, episode} <- task_episode(record, target),
         %Publication{} = publication <- task_publication(episode.id, publication_ref) do
      Operator.recover(publication.ref, recovery_action, expected_generation,
        actor_ref: @actor_ref,
        action_ref: action_ref
      )
    else
      nil -> {:error, :conversation_lab_publication_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp perform_lab_record_action(
         %Record{kind: "publication_offer"} = record,
         target,
         :approve_publication,
         nil,
         _work_profile,
         _task_policies,
         action_ref
       ) do
    with {:ok, publication, review_target} <-
           lab_publication(record, target, :reviewed, :review) do
      PublicationCustody.approve(%{
        actor_ref: @actor_ref,
        approval_ref: action_ref,
        occurred_at: now(),
        publication_ref: publication.ref,
        target: review_target
      })
    end
  end

  defp perform_lab_record_action(
         %Record{kind: "publication_offer"} = record,
         target,
         :check_publication,
         nil,
         _work_profile,
         _task_policies,
         action_ref
       ) do
    with {:ok, publication, _published_target} <-
           lab_publication(record, target, :published, :published) do
      Followups.request_check(publication.ref, action_ref)
    end
  end

  defp perform_lab_record_action(
         %Record{kind: "task_offer", status: :confirmed} = record,
         target,
         :approve_task_publication,
         %{publication_ref: publication_ref},
         _work_profile,
         _task_policies,
         action_ref
       ) do
    with {:ok, episode} <- task_episode(record, target),
         {:ok, publication, review_target} <-
           lab_task_publication(episode.id, publication_ref, target, :reviewed, :review) do
      PublicationCustody.approve(%{
        actor_ref: @actor_ref,
        approval_ref: action_ref,
        occurred_at: now(),
        publication_ref: publication.ref,
        target: review_target
      })
    end
  end

  defp perform_lab_record_action(
         %Record{kind: "task_offer", status: :confirmed} = record,
         target,
         :check_task_publication,
         %{publication_ref: publication_ref},
         _work_profile,
         _task_policies,
         action_ref
       ) do
    with {:ok, episode} <- task_episode(record, target),
         {:ok, publication, _published_target} <-
           lab_task_publication(episode.id, publication_ref, target, :published, :published) do
      Followups.request_check(publication.ref, action_ref)
    end
  end

  defp perform_lab_record_action(
         %Record{kind: "task_offer", status: :confirmed} = record,
         target,
         :close_task,
         nil,
         _work_profile,
         _task_policies,
         action_ref
       ) do
    case task_episode(record, target) do
      {:ok, episode} -> close_task_episode(episode, action_ref)
      {:error, _reason} = error -> error
    end
  end

  defp perform_lab_record_action(
         _record,
         _target,
         _action,
         _choice_index,
         _work_profile,
         _task_policies,
         _action_ref
       ),
       do: {:error, :conversation_lab_record_action_mismatch}

  defp confirm_record(module, record, target, action_ref) do
    module.confirm(%{
      actor_ref: @actor_ref,
      confirmation_ref: action_ref,
      occurred_at: now(),
      record_ref: record.ref,
      target: target
    })
  end

  defp task_episode(%Record{} = record, target) do
    case Repo.get(Episode, record.confirmed_episode_id) do
      %Episode{} = episode ->
        exact =
          episode.linked_episode_id == record.episode_id and
            episode.destination_transport == target.transport and
            episode.destination_conversation_ref == target.conversation_ref and
            episode.destination_thread_ref == target.thread_ref

        if exact,
          do: {:ok, episode},
          else: {:error, :conversation_lab_task_mismatch}

      nil ->
        {:error, :conversation_lab_task_not_found}
    end
  end

  defp close_task_episode(%Episode{state: state} = episode, _action_ref)
       when state in [:complete, :cancelled],
       do: {:ok, %{episode: episode, status: :settled}}

  defp close_task_episode(
         %Episode{state: :working, owner_kind: :turn, owner_ref: turn_ref} = episode,
         action_ref
       ) do
    Custody.request_cancel(
      episode.id,
      episode.key,
      turn_ref,
      action_ref,
      "Closed by the local operator from the exact Conversation Lab task card."
    )
  end

  defp close_task_episode(
         %Episode{state: state, owner_kind: owner_kind, owner_ref: owner_ref} = episode,
         action_ref
       )
       when state in [:waiting_for_input, :waiting_for_event] and owner_kind in [:input, :event] do
    command = %Command.CancelEpisode{
      cancel_ref: action_ref,
      episode_key: episode.key,
      expected_owner: %{kind: owner_kind, ref: owner_ref},
      occurred_at: now(),
      reason: "Closed by the local operator from the exact Conversation Lab task card."
    }

    case Episodes.apply(command) do
      {:ok, transition} -> {:ok, %{episode: transition.episode, status: :settled}}
      {:error, _reason} = error -> error
    end
  end

  defp close_task_episode(_episode, _action_ref),
    do: {:error, :conversation_lab_task_control_stale}

  defp lab_publication(record, source_target, expected_status, receipt_kind) do
    case Repo.get_by(Publication, record_id: record.id) do
      %Publication{status: ^expected_status} = publication ->
        lab_publication_target(publication, source_target, receipt_kind)

      %Publication{} ->
        {:error, :conversation_lab_publication_not_ready}

      nil ->
        {:error, :conversation_lab_publication_not_found}
    end
  end

  defp lab_task_publication(
         episode_id,
         publication_ref,
         source_target,
         expected_status,
         receipt_kind
       ) do
    publication = task_publication(episode_id, publication_ref)

    case publication do
      %Publication{status: ^expected_status} ->
        lab_publication_target(publication, source_target, receipt_kind)

      %Publication{} ->
        {:error, :conversation_lab_publication_not_ready}

      nil ->
        {:error, :conversation_lab_publication_not_found}
    end
  end

  defp task_publication(episode_id, publication_ref) do
    Repo.get_by(Publication, episode_id: episode_id, ref: publication_ref)
  end

  defp lab_publication_target(publication, source_target, receipt_kind) do
    receipt = publication_receipt(publication, receipt_kind)

    if lab_publication_destination?(publication, source_target, receipt) do
      {:ok, publication, lab_target(receipt, receipt["thread_ref"])}
    else
      {:error, :conversation_lab_publication_mismatch}
    end
  end

  defp publication_receipt(publication, :review), do: publication.review_delivery_receipt
  defp publication_receipt(publication, :published), do: publication.published_delivery_receipt

  defp lab_publication_destination?(publication, source_target, receipt) do
    is_map(receipt) and publication.destination_transport == "control_plane" and
      publication.destination_transport == source_target.transport and
      publication.destination_conversation_ref == source_target.conversation_ref and
      publication.destination_thread_ref == source_target.thread_ref and
      exact_lab_receipt?(receipt, publication.destination_conversation_ref)
  end

  defp exact_lab_receipt?(receipt, conversation_ref) do
    receipt["transport"] == "control_plane" and
      receipt["conversation_ref"] == conversation_ref and
      receipt["thread_ref"] == conversation_ref and is_binary(receipt["message_ref"])
  end

  defp lab_target(receipt, thread_ref) do
    %{
      conversation_ref: receipt["conversation_ref"],
      message_ref: receipt["message_ref"],
      thread_ref: thread_ref,
      transport: receipt["transport"]
    }
  end

  defp lab_action_ref(conversation_id, record_ref, action, choice_index) do
    action_context = canonical_lab_action_context(choice_index)

    digest =
      CanonicalJSON.digest([
        "conversation-lab-action",
        conversation_id,
        record_ref,
        Atom.to_string(action),
        action_context
      ])

    "control-plane-action:#{digest}"
  end

  defp canonical_lab_action_context(%{generation: generation, publication_ref: publication_ref}),
    do: %{"generation" => generation, "publication_ref" => publication_ref}

  defp canonical_lab_action_context(%{publication_ref: publication_ref}),
    do: %{"publication_ref" => publication_ref}

  defp canonical_lab_action_context(other), do: other

  defp now do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
  end

  defp lab_sender(%WorkProfile{} = work_profile) do
    fn conversation_id, message, attachments ->
      ConversationLab.send_message(conversation_id, message, work_profile,
        attachments: attachments
      )
    end
  end

  defp lab_sender(_work_profile) do
    fn _conversation_id, _message, _attachments ->
      {:error, :conversation_lab_not_configured}
    end
  end

  defp lab_message_editor(%WorkProfile{} = work_profile) do
    fn conversation_id, item_id, message ->
      ConversationLab.edit_message(conversation_id, item_id, message, work_profile)
    end
  end

  defp lab_message_editor(_work_profile) do
    fn _conversation_id, _item_id, _message ->
      {:error, :conversation_lab_not_configured}
    end
  end

  defp lab_message_deleter(%WorkProfile{} = work_profile) do
    fn conversation_id, item_id ->
      ConversationLab.delete_message(conversation_id, item_id, work_profile)
    end
  end

  defp lab_message_deleter(_work_profile) do
    fn _conversation_id, _item_id ->
      {:error, :conversation_lab_not_configured}
    end
  end

  defp discard_retention(ref) do
    RetentionOperator.discard_unmerged(ref, @actor_ref, action_ref(:discard_unmerged))
  end

  defp action_ref(action),
    do: "control-plane:retention:#{action}:#{Ecto.UUID.generate()}"

  defp context_ref(%WorkProfile{repository_context: %{context_ref: context_ref}}),
    do: context_ref

  defp context_ref(%WorkProfile{repository_ref: repository_ref}), do: repository_ref

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
