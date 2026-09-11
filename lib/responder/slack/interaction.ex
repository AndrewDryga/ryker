defmodule Responder.Slack.Interaction do
  @moduledoc """
  One authenticated Slack control selection normalized from Socket Mode.

  Only host-issued action IDs are retained. Arbitrary model-authored Block Kit
  is never interpreted as a control.
  """

  @actions ~w(responder_answer_input responder_check_publication responder_close_work responder_confirm_automation responder_confirm_behavior responder_confirm_memory responder_confirm_schedule responder_confirm_slack_post responder_delete_behavior responder_delete_schedule responder_forget_memory responder_investigate_incident responder_open_incident responder_open_publication responder_publish_draft responder_review_publication responder_start_engineering_task responder_stop_work responder_task_check responder_task_discard_publication responder_task_publish responder_task_retry_publication responder_task_update_publication responder_work_record responder_setup_alerts_automatic responder_setup_alerts_offer responder_setup_alerts_reply responder_setup_audience_none responder_setup_cancel responder_setup_participation_mentions responder_setup_participation_proactive responder_setup_participation_shadow responder_setup_restart responder_setup_save responder_welcome_be_proactive responder_welcome_configure responder_welcome_mentions_only responder_welcome_view_rules responder_welcome_view_schedules)
  @repository_action ~r/\Aresponder_setup_repository_[0-9]{1,2}\z/
  # Configure channel also lives on the private `/responder status` reply. It
  # acts on the channel configuration named in its value, never on the message
  # it was clicked in, so an ephemeral container is acceptable for it alone.
  @ephemeral_actions ~w(responder_welcome_configure)
  @welcome_value ~r/\A[0-9a-f-]{36}\|[1-9][0-9]{0,9}\z/
  @schedule_control_value ~r/\Aschedule-control:schedule:[0-9a-f-]{36}:[1-9][0-9]{0,9}\z/
  @behavior_control_value ~r/\Abehavior-control:behavior:[0-9a-f-]{36}:[1-9][0-9]{0,9}\z/
  @memory_value ~r/\Amemory:[A-Za-z0-9_.:-]{1,240}\z/
  @reference ~r/\A[A-Za-z0-9_.:-]{1,256}\z/
  @choice_value ~r/\Arecord:input_request:[A-Za-z0-9_.:-]{1,220}\|[0-9]{1,2}\z/
  @work_record_value ~r/\A(?:task-card|incident-room):[A-Za-z0-9_.:-]{1,220}\|(?:timeline|evidence|handoff|postmortem)\z/
  @task_publication_value ~r/\Atask-card:[A-Za-z0-9_.:-]{1,220}\|(?:publication|record:publication_offer):[A-Za-z0-9_.:-]{1,220}\z/
  @task_publication_recovery_value ~r/\Atask-card:[A-Za-z0-9_.:-]{1,220}\|publication:[A-Za-z0-9_.:-]{1,220}\|[1-9][0-9]{0,18}\z/

  @enforce_keys [
    :action_id,
    :action_value,
    :actor_ref,
    :channel_ref,
    :event_ref,
    :message_ref,
    :occurred_at,
    :thread_ref,
    :workspace_ref
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          action_id: String.t(),
          action_value: String.t(),
          actor_ref: String.t(),
          channel_ref: String.t(),
          event_ref: String.t(),
          message_ref: String.t(),
          occurred_at: DateTime.t(),
          thread_ref: String.t() | nil,
          workspace_ref: String.t()
        }

  @spec from_socket(map(), String.t(), DateTime.t()) :: {:ok, t()} | :ignore
  def from_socket(
        %{
          "envelope_id" => envelope_id,
          "payload" =>
            %{
              "actions" => [action],
              "container" =>
                %{
                  "channel_id" => channel_ref,
                  "is_ephemeral" => ephemeral,
                  "message_ts" => message_ref,
                  "type" => "message"
                } = container,
              "team" => %{"id" => workspace_ref},
              "type" => "block_actions",
              "user" => %{"id" => actor_ref}
            } = payload,
          "type" => "interactive"
        },
        workspace_ref,
        %DateTime{} = occurred_at
      ) do
    case action(action, payload) do
      {:ok, action_id, action_value}
      when ephemeral == false or (ephemeral == true and action_id in @ephemeral_actions) ->
        build_interaction(
          action_id,
          action_value,
          container,
          %{
            actor_ref: actor_ref,
            channel_ref: channel_ref,
            envelope_id: envelope_id,
            message_ref: message_ref,
            occurred_at: occurred_at,
            workspace_ref: workspace_ref
          }
        )

      _ignored ->
        :ignore
    end
  end

  def from_socket(_envelope, _workspace_ref, _occurred_at), do: :ignore

  defp build_interaction(action_id, action_value, container, context) do
    thread_ref = container["thread_ts"]

    values =
      Map.take(context, [:actor_ref, :channel_ref, :envelope_id, :message_ref, :workspace_ref])
      |> Map.values()

    if action_id?(action_id) and Enum.all?(values, &reference?/1) and
         action_value?(action_id, action_value) and optional_reference?(thread_ref) and
         utc?(context.occurred_at) do
      {:ok,
       %__MODULE__{
         action_id: action_id,
         action_value: action_value,
         actor_ref: context.actor_ref,
         channel_ref: context.channel_ref,
         event_ref: "interaction:#{context.envelope_id}",
         message_ref: context.message_ref,
         occurred_at: normalize_datetime(context.occurred_at),
         thread_ref: thread_ref,
         workspace_ref: context.workspace_ref
       }}
    else
      :ignore
    end
  end

  @spec setup_action?(String.t()) :: boolean()
  def setup_action?("responder_setup_" <> _rest = action_id), do: action_id?(action_id)
  def setup_action?("responder_welcome_" <> _rest = action_id), do: action_id?(action_id)
  def setup_action?(_action_id), do: false

  defp optional_reference?(nil), do: true
  defp optional_reference?(value), do: reference?(value)

  defp reference?(value), do: is_binary(value) and Regex.match?(@reference, value)

  defp action_value?("responder_answer_input", value),
    do: is_binary(value) and Regex.match?(@choice_value, value)

  defp action_value?("responder_work_record", value),
    do: is_binary(value) and Regex.match?(@work_record_value, value)

  defp action_value?(action_id, value)
       when action_id in ~w(responder_task_check responder_task_publish),
       do: is_binary(value) and Regex.match?(@task_publication_value, value)

  defp action_value?(action_id, value)
       when action_id in ~w(responder_task_retry_publication responder_task_update_publication responder_task_discard_publication),
       do: is_binary(value) and Regex.match?(@task_publication_recovery_value, value)

  defp action_value?("responder_welcome_" <> _rest, value),
    do: is_binary(value) and Regex.match?(@welcome_value, value)

  defp action_value?("responder_delete_schedule", value),
    do: is_binary(value) and Regex.match?(@schedule_control_value, value)

  defp action_value?("responder_delete_behavior", value),
    do: is_binary(value) and Regex.match?(@behavior_control_value, value)

  defp action_value?("responder_forget_memory", value),
    do: is_binary(value) and Regex.match?(@memory_value, value)

  defp action_value?("responder_setup_" <> _rest, value) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> true
      :error -> false
    end
  end

  defp action_value?(_action_id, value), do: reference?(value)

  defp action_id?(value),
    do:
      is_binary(value) and
        (value in @actions or value == "responder_submit_input" or
           Regex.match?(@repository_action, value))

  defp action(
         %{"action_id" => "responder_submit_input", "type" => "button", "value" => ref},
         payload
       ) do
    # Slack includes native state in the authenticated submitting user's payload.
    # Selecting a radio alone is inert; no cross-user staging store is needed.
    case get_in(payload, ["state", "values", ref, "responder_question_choice"]) do
      %{"type" => "radio_buttons", "selected_option" => %{"value" => value}}
      when is_binary(value) ->
        if String.starts_with?(value, ref <> "|"),
          do: {:ok, "responder_answer_input", value},
          else: :ignore

      _missing ->
        {:ok, "responder_submit_input", ref}
    end
  end

  defp action(
         %{
           "action_id" => "responder_answer_input_" <> index,
           "type" => "button",
           "value" => value
         },
         _payload
       )
       when index in ~w(0 1 2 3 4) and is_binary(value) do
    if String.ends_with?(value, "|" <> index),
      do: {:ok, "responder_answer_input", value},
      else: :ignore
  end

  defp action(%{"action_id" => action_id, "type" => "button", "value" => action_value}, _payload)
       when action_id != "responder_answer_input",
       do: {:ok, action_id, action_value}

  defp action(
         %{
           "action_id" => action_id,
           "selected_option" => %{"value" => action_value},
           "type" => "overflow"
         },
         _payload
       ),
       do: {:ok, action_id, action_value}

  defp action(_action, _payload), do: :ignore

  defp utc?(%DateTime{} = value),
    do: value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0

  defp normalize_datetime(%DateTime{microsecond: {microsecond, _precision}} = value),
    do: %{value | microsecond: {microsecond, 6}}
end
