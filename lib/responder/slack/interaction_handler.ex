defmodule Responder.Slack.InteractionHandler do
  @moduledoc """
  Applies authenticated Slack controls at host-owned authority boundaries.

  Membership, operator status, repository policy, delivered-message identity,
  and current record state are all re-read after the click. The button value
  alone grants nothing.
  """

  alias Responder.Slack.Interaction

  @invalid_offer_errors [
    :input_request_already_answered,
    :input_request_choice_invalid,
    :input_request_delivery_mismatch,
    :input_request_not_delivered,
    :input_request_not_found,
    :input_request_stale,
    :task_offer_delivery_mismatch,
    :task_offer_not_delivered,
    :task_offer_not_found,
    :task_offer_stale,
    :incident_offer_already_confirmed,
    :incident_offer_delivery_mismatch,
    :incident_offer_not_delivered,
    :incident_offer_not_found,
    :incident_offer_stale,
    :incident_offer_workspace_mismatch,
    :incident_room_capacity,
    :publication_not_found,
    :publication_not_publishable,
    :publication_not_reviewed,
    :publication_offer_already_requested,
    :publication_offer_delivery_mismatch,
    :publication_offer_not_delivered,
    :publication_offer_not_found,
    :publication_review_delivery_mismatch,
    :task_publication_mismatch,
    :task_publication_not_ready,
    :schedule_offer_already_confirmed,
    :schedule_offer_delivery_mismatch,
    :schedule_offer_not_delivered,
    :schedule_offer_not_found,
    :schedule_offer_stale,
    :schedule_not_found,
    :slack_post_offer_actor_mismatch,
    :slack_post_offer_confirmation_incomplete,
    :slack_post_offer_delivery_mismatch,
    :slack_post_offer_not_delivered,
    :slack_post_offer_not_found,
    :slack_post_offer_stale,
    :automation_busy,
    :automation_change_offer_delivery_mismatch,
    :automation_change_offer_invalid,
    :automation_change_offer_not_delivered,
    :automation_change_offer_not_found,
    :automation_change_offer_stale,
    :automation_not_found,
    :automation_not_future,
    :automation_status_conflict,
    :behavior_offer_delivery_mismatch,
    :behavior_offer_not_delivered,
    :behavior_offer_not_found,
    :behavior_offer_stale,
    :behavior_not_found,
    :memory_offer_delivery_mismatch,
    :memory_offer_not_delivered,
    :memory_offer_not_found,
    :memory_offer_stale,
    :memory_not_found,
    :work_changes_not_available,
    :work_changes_not_configured,
    :work_control_not_found,
    :work_control_stale,
    :work_control_target_mismatch,
    :work_delivery_must_settle,
    :work_diff_message_mismatch,
    :work_record_not_available
  ]
  @work_record_kinds ~w(timeline evidence handoff postmortem)

  @spec handle(Interaction.t(), map()) :: {:ok, map()} | {:error, term()}
  def handle(%Interaction{} = interaction, options) when is_map(options) do
    if Interaction.setup_action?(interaction.action_id) do
      handle_setup(interaction, options)
    else
      handle_record_action(interaction, options)
    end
  end

  def handle(_interaction, _options), do: {:error, {:invalid_slack_interaction, :input}}

  defp handle_setup(interaction, options) do
    with {:ok, true} <-
           options.directory.user_allowed(
             options.client,
             interaction.actor_ref,
             interaction.workspace_ref
           ),
         :ok <- configured_operator(interaction, options),
         {:ok, result} <- options.configure_channel.(interaction) do
      {:ok, result}
    else
      {:ok, false} ->
        {:ok, %{outcome: :denied}}

      {:error, :operator_required} ->
        {:ok, %{outcome: :denied}}

      {:error, reason}
      when reason in [
             :configuration_action_mismatch,
             :configuration_actor_mismatch,
             :configuration_channel_mismatch,
             :configuration_expired,
             :configuration_membership_not_found,
             :configuration_membership_stale,
             :configuration_message_mismatch,
             :configuration_prompt_already_bound,
             :configuration_repository_not_offered,
             :configuration_revision_stale,
             :configuration_session_not_found,
             :configuration_session_terminal,
             :configuration_thread_mismatch,
             :configuration_workspace_mismatch
           ] ->
        {:ok, %{outcome: :invalid}}

      {:error, _reason} = error ->
        error
    end
  end

  defp handle_record_action(interaction, options) do
    with {:ok, record_ref, choice_index} <- selection(interaction),
         {:ok, true} <-
           options.directory.user_allowed(
             options.client,
             interaction.actor_ref,
             interaction.workspace_ref
           ),
         {:ok, result} <- dispatch_action(interaction, record_ref, choice_index, options) do
      {:ok, result}
    else
      {:ok, false} -> {:ok, %{outcome: :denied}}
      {:error, :operator_required} -> {:ok, %{outcome: :denied}}
      {:error, reason} when reason in @invalid_offer_errors -> {:ok, %{outcome: :invalid}}
      {:error, {:automation_revision_conflict, _revision}} -> {:ok, %{outcome: :invalid}}
      {:error, :slack_action_mismatch} -> {:ok, %{outcome: :invalid}}
      {:error, :state_record_not_found} -> {:ok, %{outcome: :invalid}}
      {:error, _reason} = error -> error
    end
  end

  defp dispatch_action(
         %Interaction{action_id: "responder_stop_work"} = interaction,
         work_ref,
         nil,
         options
       ) do
    with :ok <- configured_operator(interaction, options) do
      options.stop_work.(work_attributes(interaction, work_ref))
    end
  end

  defp dispatch_action(
         %Interaction{action_id: "responder_close_work"} = interaction,
         work_ref,
         nil,
         options
       ) do
    with :ok <- configured_operator(interaction, options) do
      options.close_work.(work_attributes(interaction, work_ref))
    end
  end

  defp dispatch_action(
         %Interaction{action_id: "responder_view_diff"} = interaction,
         work_ref,
         nil,
         options
       ) do
    options.show_work_diff.(work_attributes(interaction, work_ref))
  end

  defp dispatch_action(
         %Interaction{action_id: "responder_diff_page"} = interaction,
         work_ref,
         %{patch_offset: patch_offset, snapshot_digest: snapshot_digest},
         options
       ) do
    attributes =
      interaction
      |> work_attributes(work_ref)
      |> Map.merge(%{patch_offset: patch_offset, snapshot_digest: snapshot_digest})

    options.show_work_diff_page.(attributes)
  end

  defp dispatch_action(
         %Interaction{action_id: "responder_work_record"} = interaction,
         work_ref,
         record_kind,
         options
       )
       when record_kind in [:timeline, :evidence, :handoff, :postmortem] do
    attributes =
      interaction
      |> work_attributes(work_ref)
      |> Map.put(:record_kind, record_kind)

    options.show_work_record.(attributes)
  end

  defp dispatch_action(
         %Interaction{action_id: "responder_task_readiness"} = interaction,
         work_ref,
         %{publication_item_ref: "record:publication_offer:" <> _rest = record_ref},
         options
       ) do
    attributes = task_publication_attributes(interaction, work_ref, record_ref)

    with :ok <- configured_operator(interaction, options) do
      options.request_task_readiness.(attributes)
    end
  end

  defp dispatch_action(
         %Interaction{action_id: "responder_task_publish"} = interaction,
         work_ref,
         %{publication_item_ref: "publication:" <> _rest = publication_ref},
         options
       ) do
    attributes = task_publication_attributes(interaction, work_ref, publication_ref)

    with :ok <- configured_operator(interaction, options) do
      options.approve_task_publication.(attributes)
    end
  end

  defp dispatch_action(
         %Interaction{action_id: "responder_task_check"} = interaction,
         work_ref,
         %{publication_item_ref: "publication:" <> _rest = publication_ref},
         options
       ) do
    attributes = task_publication_attributes(interaction, work_ref, publication_ref)

    options.check_task_publication.(attributes)
  end

  defp dispatch_action(
         %Interaction{action_id: "responder_publish_draft"} = interaction,
         publication_ref,
         nil,
         options
       ) do
    with :ok <- configured_operator(interaction, options),
         {:ok, approval} <-
           options.approve_publication.(%{
             actor_ref: "slack:user:#{interaction.actor_ref}",
             approval_ref: interaction.event_ref,
             occurred_at: interaction.occurred_at,
             publication_ref: publication_ref,
             target: target(interaction)
           }) do
      {:ok, %{publication_ref: approval.publication.ref, outcome: approval.status}}
    end
  end

  defp dispatch_action(
         %Interaction{action_id: "responder_check_publication"} = interaction,
         publication_ref,
         nil,
         options
       ) do
    with {:ok, check} <- options.check_publication.(publication_ref, interaction.event_ref) do
      {:ok, %{publication_ref: publication_ref, outcome: check.status}}
    end
  end

  defp dispatch_action(
         %Interaction{action_id: "responder_open_publication"},
         publication_ref,
         nil,
         _options
       ) do
    {:ok, %{publication_ref: publication_ref, outcome: :opened}}
  end

  defp dispatch_action(
         %Interaction{action_id: "responder_confirm_memory"} = interaction,
         record_ref,
         nil,
         options
       ) do
    with :ok <- configured_operator(interaction, options),
         {:ok, confirmation} <-
           options.confirm_memory.(%{
             actor_ref: "slack:user:#{interaction.actor_ref}",
             confirmation_ref: interaction.event_ref,
             occurred_at: interaction.occurred_at,
             record_ref: record_ref,
             target: target(interaction)
           }) do
      {:ok, %{memory_ref: confirmation.memory.ref, outcome: confirmation.status}}
    end
  end

  defp dispatch_action(
         %Interaction{action_id: "responder_confirm_automation"} = interaction,
         record_ref,
         nil,
         options
       ) do
    with :ok <- configured_operator(interaction, options),
         {:ok, confirmation} <-
           options.confirm_automation.(%{
             actor_ref: "slack:user:#{interaction.actor_ref}",
             confirmation_ref: interaction.event_ref,
             occurred_at: interaction.occurred_at,
             record_ref: record_ref,
             target: target(interaction)
           }) do
      {:ok,
       %{
         automation_id: confirmation.automation["automation_id"],
         outcome: confirmation.status
       }}
    end
  end

  defp dispatch_action(
         %Interaction{action_id: "responder_confirm_schedule"} = interaction,
         record_ref,
         nil,
         options
       ) do
    with :ok <- configured_operator(interaction, options),
         {:ok, confirmation} <-
           options.confirm_schedule.(%{
             actor_ref: "slack:user:#{interaction.actor_ref}",
             confirmation_ref: interaction.event_ref,
             occurred_at: interaction.occurred_at,
             record_ref: record_ref,
             target: target(interaction)
           }) do
      {:ok, %{outcome: confirmation.status, schedule_ref: confirmation.schedule.ref}}
    end
  end

  defp dispatch_action(
         %Interaction{action_id: "responder_confirm_behavior"} = interaction,
         record_ref,
         nil,
         options
       ) do
    with :ok <- configured_operator(interaction, options),
         {:ok, confirmation} <-
           options.confirm_behavior.(%{
             actor_ref: "slack:user:#{interaction.actor_ref}",
             confirmation_ref: interaction.event_ref,
             occurred_at: interaction.occurred_at,
             record_ref: record_ref,
             target: target(interaction)
           }) do
      {:ok, %{behavior_ref: confirmation.behavior.ref, outcome: confirmation.status}}
    end
  end

  defp dispatch_action(interaction, record_ref, choice_index, options) do
    with {:ok, record} <- record(record_ref, options) do
      apply_action(interaction, record, choice_index, options)
    end
  end

  defp record(record_ref, options) do
    case options.records.fetch_many([record_ref]) do
      {:ok, [%{kind: kind} = record]}
      when kind in [
             "task_offer",
             "publication_offer",
             "schedule_offer",
             "slack_post_offer",
             "input_request"
           ] ->
        {:ok, record}

      {:ok, _invalid} ->
        {:error, :state_record_not_found}

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_action(
         %Interaction{action_id: "responder_answer_input"} = interaction,
         %{kind: "input_request"},
         choice_index,
         options
       )
       when is_integer(choice_index) do
    case options.answer_input_request.(%{
           actor_ref: interaction.actor_ref,
           choice_index: choice_index,
           occurred_at: interaction.occurred_at,
           record_ref: record_ref(interaction.action_value),
           response_ref: interaction.event_ref,
           target: target(interaction)
         }) do
      {:ok, answer} -> {:ok, %{input_ref: answer.input_ref, outcome: answer.status}}
      {:error, _reason} = error -> error
    end
  end

  defp apply_action(
         interaction,
         %{kind: "task_offer", payload: %{"kind" => "incident"}} = record,
         nil,
         options
       ) do
    with :ok <- matching_task_action(interaction.action_id, record.payload["kind"]),
         :ok <- operator_authority(interaction, record, options),
         {:ok, policy} <- policy(record, options),
         {:ok, request} <- request_incident(interaction, policy, options) do
      {:ok, %{outcome: request.status, room_ref: request.room.ref}}
    end
  end

  defp apply_action(interaction, %{kind: "task_offer"} = record, nil, options) do
    with :ok <- matching_task_action(interaction.action_id, record.payload["kind"]),
         :ok <- operator_authority(interaction, record, options),
         {:ok, policy} <- policy(record, options),
         {:ok, confirmation} <- confirm_task(interaction, policy, options) do
      {:ok, %{episode_id: confirmation.episode.id, outcome: confirmation.status}}
    end
  end

  defp apply_action(
         %Interaction{action_id: "responder_review_publication"} = interaction,
         %{kind: "publication_offer"},
         nil,
         options
       ) do
    with :ok <- configured_operator(interaction, options),
         {:ok, request} <-
           options.request_publication_review.(%{
             actor_ref: "slack:user:#{interaction.actor_ref}",
             occurred_at: interaction.occurred_at,
             record_ref: interaction.action_value,
             request_ref: interaction.event_ref,
             target: target(interaction)
           }) do
      {:ok, %{publication_ref: request.publication.ref, outcome: request.status}}
    end
  end

  defp apply_action(
         %Interaction{action_id: "responder_confirm_slack_post"} = interaction,
         %{kind: "slack_post_offer"},
         nil,
         options
       ) do
    with {:ok, confirmation} <-
           options.confirm_slack_post.(%{
             actor_ref: "slack:user:#{interaction.actor_ref}",
             confirmation_ref: interaction.event_ref,
             occurred_at: interaction.occurred_at,
             record_ref: interaction.action_value,
             target: target(interaction)
           }) do
      {:ok, %{action_ref: confirmation.action.action_ref, outcome: confirmation.status}}
    end
  end

  defp apply_action(_interaction, _record, _choice_index, _options),
    do: {:error, :slack_action_mismatch}

  defp matching_task_action("responder_start_engineering_task", "engineering"), do: :ok
  defp matching_task_action("responder_open_incident", "incident"), do: :ok
  defp matching_task_action(_action, _kind), do: {:error, :slack_action_mismatch}

  defp operator_authority(
         %Interaction{actor_ref: actor_ref},
         %{payload: %{"kind" => "incident"}},
         options
       ) do
    if MapSet.member?(options.operators, actor_ref),
      do: :ok,
      else: {:error, :operator_required}
  end

  defp operator_authority(_interaction, _record, _options), do: :ok

  defp configured_operator(%Interaction{actor_ref: actor_ref}, options) do
    if MapSet.member?(options.operators, actor_ref),
      do: :ok,
      else: {:error, :operator_required}
  end

  defp policy(%{payload: %{"kind" => "incident"}}, options),
    do: {:ok, options.incident_policy}

  defp policy(%{payload: %{"kind" => "engineering", "repository" => repository}}, options) do
    case get_in(options, [:repositories, repository, :contributor_policy]) do
      %{digest: digest, name: name} -> {:ok, %{digest: digest, name: name}}
      _missing -> {:error, {:slack_task_policy_not_configured, repository}}
    end
  end

  defp policy(_record, _options), do: {:error, :task_offer_action_mismatch}

  defp confirm_task(interaction, policy, options) do
    options.confirm_task_offer.(%{
      actor_ref: "slack:user:#{interaction.actor_ref}",
      confirmation_ref: interaction.event_ref,
      occurred_at: interaction.occurred_at,
      policy: policy,
      record_ref: interaction.action_value,
      target: target(interaction)
    })
  end

  defp request_incident(interaction, policy, options) do
    options.request_incident_room.(%{
      actor_ref: "slack:user:#{interaction.actor_ref}",
      confirmation_ref: interaction.event_ref,
      occurred_at: interaction.occurred_at,
      policy: policy,
      record_ref: interaction.action_value,
      target: target(interaction),
      workspace_ref: interaction.workspace_ref
    })
  end

  defp selection(%Interaction{
         action_id: "responder_answer_input",
         action_value: action_value
       }) do
    case String.split(action_value, "|", parts: 2) do
      ["record:input_request:" <> _rest = record_ref, index] ->
        case Integer.parse(index) do
          {index, ""} when index in 0..9 -> {:ok, record_ref, index}
          _invalid -> {:error, :slack_action_mismatch}
        end

      _invalid ->
        {:error, :slack_action_mismatch}
    end
  end

  defp selection(%Interaction{
         action_id: "responder_work_record",
         action_value: action_value
       }) do
    case String.split(action_value, "|", parts: 2) do
      [work_ref, kind] when kind in @work_record_kinds ->
        {:ok, work_ref, String.to_existing_atom(kind)}

      _invalid ->
        {:error, :slack_action_mismatch}
    end
  end

  defp selection(%Interaction{
         action_id: "responder_diff_page",
         action_value: action_value
       }) do
    case String.split(action_value, "|", parts: 3) do
      [work_ref, snapshot_digest, patch_offset] ->
        case Integer.parse(patch_offset) do
          {patch_offset, ""} when patch_offset >= 0 ->
            {:ok, work_ref, %{patch_offset: patch_offset, snapshot_digest: snapshot_digest}}

          _invalid ->
            {:error, :slack_action_mismatch}
        end

      _invalid ->
        {:error, :slack_action_mismatch}
    end
  end

  defp selection(%Interaction{action_id: action_id, action_value: action_value})
       when action_id in ~w(responder_task_check responder_task_publish responder_task_readiness) do
    case String.split(action_value, "|", parts: 2) do
      ["task-card:" <> _rest = work_ref, publication_item_ref] ->
        {:ok, work_ref, %{publication_item_ref: publication_item_ref}}

      _invalid ->
        {:error, :slack_action_mismatch}
    end
  end

  defp selection(%Interaction{action_value: record_ref}) do
    {:ok, record_ref, nil}
  end

  defp record_ref(action_value) do
    action_value |> String.split("|", parts: 2) |> hd()
  end

  defp target(interaction) do
    %{
      conversation_ref: "slack:#{interaction.workspace_ref}:#{interaction.channel_ref}",
      message_ref: interaction.message_ref,
      thread_ref: interaction.thread_ref,
      transport: "slack"
    }
  end

  defp work_attributes(interaction, work_ref) do
    %{
      actor_ref: "slack:user:#{interaction.actor_ref}",
      occurred_at: interaction.occurred_at,
      request_ref: interaction.event_ref,
      target: target(interaction),
      work_ref: work_ref
    }
  end

  defp task_publication_attributes(interaction, work_ref, publication_item_ref) do
    key =
      if String.starts_with?(publication_item_ref, "publication:"),
        do: :publication_ref,
        else: :record_ref

    interaction
    |> work_attributes(work_ref)
    |> Map.put(key, publication_item_ref)
  end
end
