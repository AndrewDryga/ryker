defmodule Ryker.ControlPlane.Actions do
  @moduledoc false
  alias Ryker.Adapter
  alias Ryker.Behaviors
  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.Actor
  alias Ryker.ControlPlane.ConversationLab
  alias Ryker.ControlPlane.FailureProjection
  alias Ryker.ControlPlane.InstructionSettings
  alias Ryker.ControlPlane.SettingsCommands
  alias Ryker.ControlPlane.WorkChanges
  alias Ryker.Episodes
  alias Ryker.Improvement
  alias Ryker.Ingress
  alias Ryker.IntegrationSetup
  alias Ryker.Maps
  alias Ryker.Memories
  alias Ryker.Operator
  alias Ryker.People
  alias Ryker.Publication
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Schedules
  alias Ryker.Slack
  alias Ryker.WeeklyReport
  alias Ryker.Work

  @current {__MODULE__, :current}

  @doc """
  The console's actions, each calling the callbacks that are current (`put_current/1`) when it
  is called. A settings change that gives Chat another environment, or tasks other policies,
  reaches open pages without restarting the console: a restart dropped every open page, and the
  one that had just connected an Emisar account reloaded on its empty form (mac-server,
  2026-10-01).
  """
  @spec live() :: map()
  def live do
    Map.new(callbacks(), fn {name, fun} ->
      {:arity, arity} = Function.info(fun, :arity)
      {name, delegate(name, arity)}
    end)
  end

  @doc "Makes `callbacks` what the console's live actions call from now on."
  @spec put_current(map()) :: :ok
  def put_current(callbacks) when is_map(callbacks), do: :persistent_term.put(@current, callbacks)

  defp current, do: :persistent_term.get(@current, nil) || callbacks()

  defp delegate(name, 0), do: fn -> current()[name].() end
  defp delegate(name, 1), do: fn a -> current()[name].(a) end
  defp delegate(name, 2), do: fn a, b -> current()[name].(a, b) end
  defp delegate(name, 3), do: fn a, b, c -> current()[name].(a, b, c) end
  defp delegate(name, 4), do: fn a, b, c, d -> current()[name].(a, b, c, d) end
  defp delegate(name, 5), do: fn a, b, c, d, e -> current()[name].(a, b, c, d, e) end

  # Chat's placements: the Work profile of every environment that can run
  # work, by ref, and the profile of work outside any environment. Each
  # conversation's messages run on the profile its own environment resolves
  # to (`ConversationLab.work_profile/2`).
  @spec callbacks(
          ConversationLab.placements() | nil,
          map(),
          map(),
          (Schedules.Schedule.t() -> term()) | nil
        ) ::
          map()
  def callbacks(
        placements \\ nil,
        task_policies \\ %{},
        work_view_options \\ %{},
        schedule_policy_resolver \\ nil
      ) do
    placements = placements || %{environments: %{}, fallback_work_profile: nil}

    %{
      act_on_lab_record: lab_record_action(placements, task_policies),
      delete_lab_message: lab_message_deleter(placements),
      discard_retention: &discard_retention/2,
      edit_lab_message: lab_message_editor(placements),
      drop_learning: &drop_learning/3,
      forget_memory: &Memories.forget/1,
      forget_knowledge: &Memories.Forgetting.forget_topic/1,
      forget_finding: &Records.Findings.forget/1,
      forget_case: &Memories.Cases.delete/1,
      forget_person: &People.forget_person/1,
      forget_person_fact: &People.forget_fact/1,
      accept_improvement: &Improvement.accept(&1, Actor.of(&2)),
      dismiss_improvement: &Improvement.dismiss(&1, Actor.of(&2)),
      mark_finding_explained: &Records.Findings.mark_explained/1,
      resolve_episode: &resolve_episode/2,
      resolve_memory_review: &resolve_memory_review/4,
      rearm_admission: &retry_failure("admission", &1, &2),
      rearm_delivery: &retry_failure("delivery", &1, &2),
      rearm_emisar: &retry_failure("emisar", &1, &2),
      rearm_retention: &retry_failure("retention", &1, &2),
      rearm_slack_incident: &retry_failure("slack_incident", &1, &2),
      close_incident_room: &Slack.IncidentRooms.request_close(&1, Actor.of(&2)),
      leave_failure: &leave_failure/3,
      rearm_slack_interaction: &retry_failure("slack_interaction", &1, &2),
      rearm_slack_task_card: &retry_failure("slack_task_card", &1, &2),
      rearm_slack_thread_status: &retry_failure("slack_thread_status", &1, &2),
      react_to_lab_message: &react_to_lab_message/5,
      retry_work: &retry_work/3,
      rate_episode: &Operator.EpisodeReviews.review(&1, Actor.of(&3), &2),
      run_schedule: run_schedule(schedule_policy_resolver),
      send_lab_message: lab_sender(placements),
      set_behavior_status: &Behaviors.set_status/2,
      save_instructions: &InstructionSettings.save(&1, &2, &3, Actor.of(&4)),
      # The outcome comes back to the page that asked, as a message.
      redraw_channel_welcome: &Slack.Runtime.redraw_welcome(&1, &2, self()),
      leave_channel: &Slack.Runtime.leave_channel/2,
      # What the GitHub App reaches, for Add repositories; it asks GitHub.
      github_repositories: fn -> IntegrationSetup.github_repositories() end,
      initialize_settings: &SettingsCommands.initialize(Actor.of(&1)),
      save_settings: &SettingsCommands.save(&1, &2, &3, Actor.of(&4)),
      put_settings_item: &SettingsCommands.put_item(&1, &2, &3, Actor.of(&4)),
      delete_settings_item: &SettingsCommands.delete_item(&1, &2, &3, Actor.of(&4)),
      preview_retention: &SettingsCommands.preview_retention/2,
      preview_webhook: &SettingsCommands.preview_webhook/2,
      send_weekly_report_preview: fn -> WeeklyReport.send_preview() end,
      set_schedule_status: &Schedules.set_status/2,
      view_lab_task_record: lab_task_record_view(work_view_options)
    }
  end

  defp run_schedule(policy_resolver) when is_function(policy_resolver, 1) do
    fn schedule_ref, viewer ->
      case Repo.one(Schedules.Schedule.Query.by_ref(schedule_ref)) do
        %{revision: revision} ->
          action_ref = "control-plane:run-schedule:#{schedule_ref}:#{revision}"

          Schedules.run_now_for_operator(
            schedule_ref,
            Actor.of(viewer),
            action_ref,
            policy_resolver
          )

        nil ->
          {:error, :schedule_not_found}
      end
    end
  end

  defp run_schedule(_policy_resolver) do
    fn _schedule_ref, _viewer -> {:error, :schedule_policy_unavailable} end
  end

  defp resolve_memory_review(review_ref, action, replacement, viewer) do
    case Repo.one(Memories.MemoryReviewItem.Query.by_ref(review_ref)) do
      %Memories.MemoryReviewItem{workspace_ref: workspace_ref} ->
        Memories.resolve_review(review_ref, action, Actor.of(viewer), workspace_ref, replacement)

      nil ->
        {:error, :memory_review_not_found}
    end
  end

  defp drop_learning(id, budget_version, viewer) do
    Operator.Learning.drop(
      id,
      budget_version,
      Actor.of(viewer),
      "control-plane:learning-drop:#{id}:#{budget_version}"
    )
  end

  # How the failure fails now, so failing some other way lists it again.
  defp leave_failure(kind, ref, viewer) do
    case FailureProjection.fetch(kind, ref) do
      {:ok, row} ->
        Operator.FailureDismissals.leave(row.kind, row.ref, row.summary, Actor.of(viewer))

      :not_found ->
        {:error, :failure_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retry_failure(kind, ref, viewer) do
    Operator.Failures.retry(kind, ref,
      action_ref: "control-plane:retry:#{Ecto.UUID.generate()}",
      actor_ref: Actor.of(viewer)
    )
  end

  defp retry_work(ref, expected_recovery, viewer) do
    Operator.Failures.retry("work", ref,
      action_ref: "control-plane:retry:#{Ecto.UUID.generate()}",
      actor_ref: Actor.of(viewer),
      expected_recovery: expected_recovery
    )
  end

  defp resolve_episode(episode_key, viewer) do
    episode_key
    |> Episodes.Episode.Query.by_key()
    |> Repo.one()
    |> resolve_episode_record("Closed by #{Actor.of(viewer)} as no longer needed.")
  end

  defp resolve_episode_record(
         %Episodes.Episode{state: :working, owner_kind: :turn, owner_ref: turn_ref} = episode,
         reason
       ) do
    episode.id
    |> Work.Turn.Query.by_episode_id()
    |> Work.Turn.Query.by_turn_ref(turn_ref)
    |> Repo.one()
    |> resolve_blocked_episode(episode, turn_ref, reason)
  end

  defp resolve_episode_record(
         %Episodes.Episode{state: state, owner_kind: owner_kind, owner_ref: owner_ref} = episode,
         reason
       )
       when state in [:waiting_for_input, :waiting_for_event] and owner_kind in [:input, :event] do
    %Episodes.Command.CancelEpisode{
      cancel_ref: resolve_action_ref(),
      episode_key: episode.key,
      expected_owner: %{kind: owner_kind, ref: owner_ref},
      occurred_at: DateTime.utc_now(),
      reason: reason
    }
    |> Episodes.apply()
    |> resolved_episode_result()
  end

  defp resolve_episode_record(%Episodes.Episode{}, _reason), do: {:error, :episode_not_resolvable}
  defp resolve_episode_record(nil, _reason), do: {:error, :episode_not_found}

  defp resolve_blocked_episode(%Work.Turn{status: :blocked}, episode, turn_ref, reason) do
    Work.Custody.request_cancel(episode.id, episode.key, turn_ref, resolve_action_ref(), reason)
  end

  defp resolve_blocked_episode(_not_blocked, _episode, _turn_ref, _reason),
    do: {:error, :episode_not_resolvable}

  defp resolved_episode_result({:ok, transition}), do: {:ok, transition.episode}
  defp resolved_episode_result({:error, reason}), do: {:error, reason}
  defp resolve_action_ref, do: "control-plane:resolve:#{Ecto.UUID.generate()}"

  defp lab_task_record_view(work_view_options) do
    fn conversation_id, record_ref, view, params ->
      with {:ok, conversation_ref} <- ConversationLab.conversation_ref(conversation_id),
           {:ok, record, target} <- lab_record_context(conversation_ref, record_ref),
           %Records.Record{kind: "task_offer", status: :confirmed} <- record,
           {:ok, episode} <- task_episode(record, target) do
        build_lab_task_record(record, episode, view, params, work_view_options)
      else
        %Records.Record{} -> {:error, :conversation_lab_task_mismatch}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp build_lab_task_record(record, episode, view, params, _options)
       when view in [:timeline, :evidence, :handoff, :postmortem] and params == %{} do
    with {:ok, %{"message" => body}} <- Slack.WorkRecord.build_episode(record, episode, view) do
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
         %Work.Session{coop_session_id: session_id} when is_binary(session_id) <-
           latest_bound_session(episode.id),
         {:ok, changes} <-
           coop_api.get_changes_page(coop_client, session_id, offset, WorkChanges.page_bytes()),
         :ok <- exact_snapshot(expected_digest, offset, changes["patch_digest"]),
         {:ok, diff} <- WorkChanges.render(record.ref, changes) do
      {:ok,
       %{
         body: diff["message"],
         kind: :diff,
         navigation: diff_navigation(diff),
         title: "Workspace diff"
       }}
    else
      nil -> {:error, :conversation_lab_work_changes_not_available}
      {:error, reason} -> {:error, reason}
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
    episode_id
    |> Work.Session.Query.by_episode_id()
    |> Work.Session.Query.bound()
    |> Work.Session.Query.ordered_by_generation_desc()
    |> Work.Session.Query.limit_to(1)
    |> Repo.one()
  end

  defp work_view_options(%{coop_api: api, coop_client: client})
       when is_atom(api) and not is_nil(client) do
    if Adapter.implements?(api, get_changes_page: 4),
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
    previous = max(diff["patch_offset"] - WorkChanges.page_bytes(), 0)

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

  defp lab_record_action(placements, task_policies) when is_map(task_policies) do
    fn conversation_id, record_ref, action, choice_index, viewer ->
      with {:ok, conversation_ref} <- ConversationLab.conversation_ref(conversation_id),
           {:ok, record, target} <- lab_record_context(conversation_ref, record_ref),
           :ok <- lab_action_arguments(action, choice_index) do
        perform_lab_record_action(record, target, action, choice_index, %{
          ref: lab_action_ref(conversation_id, record_ref, action, choice_index),
          task_policies: task_policies,
          viewer: viewer,
          work_profile: conversation_work_profile(conversation_id, placements)
        })
      end
    end
  end

  # The profile the conversation's environment resolves to, or nil when Chat
  # has nothing to run on; the actions that need one say so themselves.
  defp conversation_work_profile(conversation_id, placements) do
    case ConversationLab.work_profile(conversation_id, placements) do
      {:ok, %Ingress.WorkProfile{} = work_profile} -> work_profile
      {:error, _reason} -> nil
    end
  end

  # Task policies are keyed by environment, then by the repository each
  # places its task in. A task changes the repository it names, so it runs in
  # the conversation's own environment when that may change it, else in the
  # first environment (by ref) that may. One the conversation's environment
  # only reads is not changed from any environment.
  defp task_policy(task_policies, work_profile, repository) do
    case {read_only_here?(work_profile, repository),
          own_task_policy(task_policies, work_profile, repository)} do
      {true, _own} ->
        :error

      {false, %{} = own} ->
        {:ok, own}

      {false, nil} ->
        task_policies
        |> Enum.sort_by(fn {environment_ref, _policies} -> environment_ref end)
        |> Enum.find_value(:error, fn {_environment_ref, policies} ->
          environment_task_policy(policies, repository)
        end)
    end
  end

  defp read_only_here?(%Ingress.WorkProfile{} = profile, repository),
    do: repository in Ingress.WorkProfile.read_only_refs(profile)

  defp read_only_here?(_outside, _repository), do: false

  defp environment_task_policy(policies, repository) do
    case Map.get(policies, repository) do
      %{} = policy -> {:ok, policy}
      nil -> nil
    end
  end

  defp own_task_policy(task_policies, %Ingress.WorkProfile{environment_ref: ref}, repository)
       when is_binary(ref) and is_binary(repository),
       do: get_in(task_policies, [ref, repository])

  defp own_task_policy(_task_policies, _outside, _repository), do: nil

  defp lab_record_context(conversation_ref, record_ref) do
    case fetch_lab_record(record_ref) do
      {%Records.Record{} = record, %Episodes.Episode{} = episode, %Work.Turn{} = turn} ->
        lab_record_target(record, episode, turn, conversation_ref)

      nil ->
        {:error, :conversation_lab_record_not_found}
    end
  end

  defp fetch_lab_record(record_ref),
    do: Repo.one(Records.Record.Query.by_ref_with_origin_turn(record_ref))

  defp lab_record_target(
         %Records.Record{} = record,
         %Episodes.Episode{} = episode,
         %Work.Turn{
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
       when action == :approve_task_publication and is_binary(publication_ref) and
              byte_size(publication_ref) in 1..1_024,
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
              :approve_publication
            ],
       do: :ok

  defp lab_action_arguments(_action, _choice_index),
    do: {:error, :conversation_lab_record_action_invalid}

  defp perform_lab_record_action(
         %Records.Record{kind: "task_offer", payload: %{"kind" => "engineering"} = payload} =
           record,
         target,
         :confirm_task,
         nil,
         %{work_profile: work_profile, task_policies: task_policies} = request
       ) do
    case task_policy(task_policies, work_profile, payload["repository"]) do
      {:ok, %{name: name, digest: digest} = policy} ->
        pinned =
          %{name: name, digest: digest}
          |> Maps.put_present(:environment_ref, Map.get(policy, :environment_ref))
          |> Maps.put_present(:repository_ref, Map.get(policy, :repository_ref))
          |> Maps.put_present(:repository_context, Map.get(policy, :repository_context))

        Records.TaskOffers.confirm(%{
          actor_ref: Actor.of(request.viewer),
          confirmation_ref: request.ref,
          occurred_at: DateTime.utc_now(),
          policy: pinned,
          record_ref: record.ref,
          target: target
        })

      :error ->
        {:error, :conversation_lab_task_policy_not_configured}
    end
  end

  defp perform_lab_record_action(
         %Records.Record{kind: "task_offer", payload: %{"kind" => "incident"} = payload} = record,
         target,
         :open_incident,
         nil,
         %{work_profile: %Ingress.WorkProfile{} = work_profile} = request
       ) do
    # An incident names one repository of the conversation's environment, or
    # none for the default; it runs under that repository's conversation policy.
    case Ingress.WorkProfile.policy_for(work_profile, :conversational, payload["repository"]) do
      {:ok, policy} ->
        pinned =
          policy
          |> Map.take([:digest, :name, :repository_ref])
          |> Maps.put_present(:environment_ref, policy.environment_ref)
          |> Maps.put_present(:repository_context, Map.get(policy, :repository_context))

        Records.TaskOffers.confirm(%{
          actor_ref: Actor.of(request.viewer),
          confirmation_ref: request.ref,
          occurred_at: DateTime.utc_now(),
          policy: pinned,
          record_ref: record.ref,
          target: target
        })

      {:error, _reason} ->
        {:error, :conversation_lab_incident_repository_mismatch}
    end
  end

  defp perform_lab_record_action(
         %Records.Record{kind: "task_offer", payload: %{"kind" => "incident"}},
         _target,
         :open_incident,
         nil,
         _request
       ),
       do: {:error, :conversation_lab_not_configured}

  defp perform_lab_record_action(
         %Records.Record{kind: "memory_offer"} = record,
         target,
         :confirm_memory,
         nil,
         request
       ),
       do: confirm_record(Memories, record, target, request)

  defp perform_lab_record_action(
         %Records.Record{kind: kind} = record,
         target,
         :confirm_behavior,
         nil,
         request
       )
       when kind in ["preference_offer", "guidance_offer", "standing_assignment_offer"],
       do: confirm_behavior(record, target, request)

  defp perform_lab_record_action(
         %Records.Record{kind: "schedule_offer"} = record,
         target,
         :confirm_schedule,
         nil,
         request
       ),
       do: confirm_record(Schedules, record, target, request)

  defp perform_lab_record_action(
         %Records.Record{kind: "automation_change_offer"} = record,
         target,
         :confirm_automation,
         nil,
         request
       ),
       do: confirm_record(Behaviors.Automations, record, target, request)

  defp perform_lab_record_action(
         %Records.Record{kind: "slack_post_offer"} = record,
         target,
         :confirm_post,
         nil,
         request
       ) do
    Records.SlackPostOffers.confirm(%{
      actor_ref: Actor.person_ref(Actor.chat_ref(request.viewer)),
      confirmation_ref: request.ref,
      occurred_at: DateTime.utc_now(),
      record_ref: record.ref,
      target: target
    })
  end

  defp perform_lab_record_action(
         %Records.Record{kind: "publication_offer"} = record,
         target,
         :review_publication,
         nil,
         request
       ) do
    Publication.Custody.request_review(%{
      actor_ref: Actor.of(request.viewer),
      occurred_at: DateTime.utc_now(),
      record_ref: record.ref,
      request_ref: request.ref,
      target: target
    })
  end

  defp perform_lab_record_action(
         %Records.Record{kind: "input_request"} = record,
         target,
         :answer_input,
         choice_index,
         request
       ) do
    Records.InputRequests.answer(%{
      actor_ref: Actor.chat_ref(request.viewer),
      choice_index: choice_index,
      occurred_at: DateTime.utc_now(),
      record_ref: record.ref,
      response_ref: request.ref,
      target: target
    })
  end

  defp perform_lab_record_action(
         %Records.Record{kind: "task_offer", status: :confirmed} = record,
         target,
         :stop_task,
         nil,
         request
       ) do
    with {:ok, episode} <- task_episode(record, target),
         true <- episode.state == :working and episode.owner_kind == :turn,
         {:ok, result} <-
           Work.Custody.request_stop(
             episode.id,
             episode.key,
             episode.owner_ref,
             request.ref,
             "#{stopper(request.viewer)} stopped this run. Reply in this conversation to continue."
           ) do
      {:ok, result}
    else
      false -> {:error, :conversation_lab_task_control_stale}
      {:error, reason} -> {:error, reason}
    end
  end

  defp perform_lab_record_action(
         %Records.Record{kind: "task_offer", status: :confirmed} = record,
         target,
         action,
         %{generation: expected_generation, publication_ref: publication_ref},
         request
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
         %Publication.Publication{} = publication <- task_publication(episode.id, publication_ref) do
      Operator.Publication.recover(publication.ref, recovery_action, expected_generation,
        actor_ref: Actor.of(request.viewer),
        action_ref: request.ref
      )
    else
      nil -> {:error, :conversation_lab_publication_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp perform_lab_record_action(
         %Records.Record{kind: "publication_offer"} = record,
         target,
         :approve_publication,
         nil,
         request
       ) do
    with {:ok, publication, review_target} <-
           lab_publication(record, target, :reviewed, :review) do
      Publication.Custody.approve(%{
        actor_ref: Actor.of(request.viewer),
        approval_ref: request.ref,
        occurred_at: DateTime.utc_now(),
        publication_ref: publication.ref,
        target: review_target
      })
    end
  end

  defp perform_lab_record_action(
         %Records.Record{kind: "task_offer", status: :confirmed} = record,
         target,
         :approve_task_publication,
         %{publication_ref: publication_ref},
         request
       ) do
    with {:ok, episode} <- task_episode(record, target),
         {:ok, publication, review_target} <-
           approvable_lab_task_publication(episode.id, publication_ref, target) do
      Publication.Custody.approve(%{
        actor_ref: Actor.of(request.viewer),
        approval_ref: request.ref,
        occurred_at: DateTime.utc_now(),
        publication_ref: publication.ref,
        target: review_target
      })
    end
  end

  defp perform_lab_record_action(
         %Records.Record{kind: "task_offer", status: :confirmed} = record,
         target,
         :close_task,
         nil,
         request
       ) do
    case task_episode(record, target) do
      {:ok, episode} -> close_task_episode(episode, request)
      {:error, reason} -> {:error, reason}
    end
  end

  defp perform_lab_record_action(
         _record,
         _target,
         _action,
         _choice_index,
         _request
       ),
       do: {:error, :conversation_lab_record_action_mismatch}

  defp confirm_record(module, record, target, request) do
    module.confirm(%{
      actor_ref: Actor.of(request.viewer),
      confirmation_ref: request.ref,
      occurred_at: DateTime.utc_now(),
      record_ref: record.ref,
      target: target
    })
  end

  defp confirm_behavior(record, target, request) do
    actor_ref =
      case record do
        # The person a personal preference or rule is for, in the form the
        # turns they start carry, so it applies to them and only they may
        # confirm it.
        %Records.Record{kind: kind, payload: %{"scope" => "operator"}}
        when kind in ["preference_offer", "guidance_offer"] ->
          Actor.person_ref(Actor.chat_ref(request.viewer))

        _other ->
          Actor.of(request.viewer)
      end

    Behaviors.confirm(%{
      actor_ref: actor_ref,
      confirmation_ref: request.ref,
      occurred_at: DateTime.utc_now(),
      record_ref: record.ref,
      target: target
    })
  end

  defp task_episode(%Records.Record{} = record, target) do
    case Repo.one(Episodes.Episode.Query.by_id(record.confirmed_episode_id)) do
      %Episodes.Episode{} = episode ->
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

  defp close_task_episode(%Episodes.Episode{state: state} = episode, _request)
       when state in [:complete, :cancelled],
       do: {:ok, %{episode: episode, status: :settled}}

  defp close_task_episode(
         %Episodes.Episode{state: :working, owner_kind: :turn, owner_ref: turn_ref} = episode,
         request
       ) do
    Work.Custody.request_cancel(
      episode.id,
      episode.key,
      turn_ref,
      request.ref,
      close_task_reason(request.viewer)
    )
  end

  defp close_task_episode(
         %Episodes.Episode{state: state, owner_kind: owner_kind, owner_ref: owner_ref} = episode,
         request
       )
       when state in [:waiting_for_input, :waiting_for_event] and owner_kind in [:input, :event] do
    command = %Episodes.Command.CancelEpisode{
      cancel_ref: request.ref,
      episode_key: episode.key,
      expected_owner: %{kind: owner_kind, ref: owner_ref},
      occurred_at: DateTime.utc_now(),
      reason: close_task_reason(request.viewer)
    }

    case Episodes.apply(command) do
      {:ok, transition} -> {:ok, %{episode: transition.episode, status: :settled}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp close_task_episode(_episode, _request),
    do: {:error, :conversation_lab_task_control_stale}

  defp close_task_reason(viewer), do: "Closed by #{Actor.of(viewer)} from its task card in Chat."

  # A stopped task's card says who stopped it, by the name their sign-in gave
  # them; the console reached without one has nobody in particular.
  defp stopper(%{name: name}), do: name
  defp stopper(nil), do: "Someone"

  defp lab_publication(record, source_target, expected_status, receipt_kind) do
    case Repo.one(Publication.Publication.Query.by_record_id(record.id)) do
      %Publication.Publication{status: ^expected_status} = publication ->
        lab_publication_target(publication, source_target, receipt_kind)

      %Publication.Publication{} ->
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
      %Publication.Publication{status: ^expected_status} ->
        lab_publication_target(publication, source_target, receipt_kind)

      %Publication.Publication{} ->
        {:error, :conversation_lab_publication_not_ready}

      nil ->
        {:error, :conversation_lab_publication_not_found}
    end
  end

  # The drafts Slack's Create draft PR accepts (`Ryker.Slack.WorkControls`): a reviewed change,
  # or one whose checks could not run, offered as an unverified draft. Chat accepted only the
  # first while its card offered both (30 Sep: "Couldn't create the draft pull request").
  defp approvable_lab_task_publication(episode_id, publication_ref, target) do
    case task_publication(episode_id, publication_ref) do
      %Publication.Publication{status: :blocked} = publication ->
        if Publication.Review.draft_shareable?(publication.review_document),
          do: lab_publication_target(publication, target, :review),
          else: {:error, :conversation_lab_publication_not_ready}

      _reviewed_or_not ->
        lab_task_publication(episode_id, publication_ref, target, :reviewed, :review)
    end
  end

  defp task_publication(episode_id, publication_ref) do
    episode_id
    |> Publication.Publication.Query.by_episode_id()
    |> Publication.Publication.Query.by_ref(publication_ref)
    |> Repo.one()
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

  # Each message runs on the profile the conversation's environment resolves
  # to at that moment: the environment's while it can run work, else the one
  # outside any environment, else nothing can be sent.
  defp lab_sender(placements) do
    fn conversation_id, message, attachments, viewer ->
      with {:ok, work_profile} <- ConversationLab.work_profile(conversation_id, placements) do
        ConversationLab.send_message(conversation_id, message, work_profile,
          actor: Actor.chat_ref(viewer),
          attachments: attachments
        )
      end
    end
  end

  defp lab_message_editor(placements) do
    fn conversation_id, item_id, message, viewer ->
      with {:ok, work_profile} <- ConversationLab.work_profile(conversation_id, placements) do
        ConversationLab.edit_message(conversation_id, item_id, message, work_profile,
          actor: Actor.chat_ref(viewer)
        )
      end
    end
  end

  defp lab_message_deleter(placements) do
    fn conversation_id, item_id, viewer ->
      with {:ok, work_profile} <- ConversationLab.work_profile(conversation_id, placements) do
        ConversationLab.delete_message(conversation_id, item_id, work_profile,
          actor: Actor.chat_ref(viewer)
        )
      end
    end
  end

  # Who sends a Chat message, edits or deletes one, reacts or answers is the
  # person of the page or request doing it (`Actor.chat_ref/1`).
  defp react_to_lab_message(conversation_id, message_ref, action, emoji_name, viewer) do
    ConversationLab.react_to_message(conversation_id, message_ref, action, emoji_name,
      actor: Actor.chat_ref(viewer)
    )
  end

  defp discard_retention(ref, viewer) do
    Operator.Retention.discard_unmerged(ref, Actor.of(viewer), action_ref(:discard_unmerged))
  end

  defp action_ref(action),
    do: "control-plane:retention:#{action}:#{Ecto.UUID.generate()}"
end
