defmodule Ryker.Slack.Interaction do
  @moduledoc """
  One authenticated Slack control selection normalized from Socket Mode.

  Only host-issued action IDs are retained. Arbitrary model-authored Block Kit
  is never interpreted as a control, and neither is a card posted before the
  2026-09-13 rename: `retired_control/3` names such a click for an explicit
  reply and audit row without ever admitting its id as a control.
  """

  alias Ryker.Retained

  @actions ~w(ryker_answer_input ryker_check_publication ryker_close_work ryker_confirm_automation ryker_confirm_behavior ryker_confirm_memory ryker_confirm_schedule ryker_confirm_slack_post ryker_delete_behavior ryker_delete_schedule ryker_resume_behavior ryker_forget_memory ryker_investigate_incident ryker_open_incident ryker_open_publication ryker_publish_draft ryker_resume_work ryker_review_publication ryker_start_engineering_task ryker_stop_work ryker_task_check ryker_task_discard_publication ryker_task_publish ryker_task_retry_publication ryker_task_update_publication ryker_work_record ryker_setup_alerts_automatic ryker_setup_alerts_offer ryker_setup_alerts_reply ryker_setup_audience_none ryker_setup_cancel ryker_setup_participation_mentions ryker_setup_participation_proactive ryker_setup_participation_shadow ryker_setup_restart ryker_setup_save ryker_welcome_be_proactive ryker_welcome_configure ryker_welcome_mentions_only ryker_welcome_view_rules ryker_welcome_view_schedules)
  @repository_action ~r/\Aryker_setup_repository_[0-9]{1,2}\z/
  # Configure channel also lives on the private `/ryker status` reply. It
  # acts on the channel configuration named in its value, never on the message
  # it was clicked in, so an ephemeral container is acceptable for it alone.
  @ephemeral_actions ~w(ryker_welcome_configure)
  @welcome_value ~r/\A[0-9a-f-]{36}\|[1-9][0-9]{0,9}\z/
  @schedule_control_value ~r/\Aschedule-control:schedule:[0-9a-f-]{36}:[1-9][0-9]{0,9}\z/
  @behavior_control_value ~r/\Abehavior-control:behavior:[0-9a-f-]{36}:[1-9][0-9]{0,9}\z/
  @memory_value ~r/\Amemory:[A-Za-z0-9_.:-]{1,240}\z/
  @reference ~r/\A[A-Za-z0-9_.:-]{1,256}\z/
  @choice_value ~r/\Arecord:input_request:[A-Za-z0-9_.:-]{1,220}\|[0-9]{1,2}\z/
  @work_record_value ~r/\A(?:task-card|incident-room):[A-Za-z0-9_.:-]{1,220}\|(?:timeline|evidence|handoff|recovery|postmortem)\z/
  @resume_work_value ~r/\A(?:task-card|incident-room):[A-Za-z0-9_.:-]{1,220}\|[0-9a-f]{64}\z/
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

  @doc """
  Recognises a click on a card posted before the rename to Ryker.

  Such a card carries an action id with the retained prefix that no current
  control uses. On a message it is normalized exactly like a control, so the
  caller can reply that the card is retired and record the exact id; nothing
  about the click is otherwise trusted. A click inside an App Home view is
  reported as `:app_home`: the view is republished on open and needs no reply.
  """
  @spec retired_control(map(), String.t(), DateTime.t()) :: {:ok, t()} | :app_home | :ignore
  def retired_control(
        %{
          "envelope_id" => envelope_id,
          "payload" =>
            %{
              "actions" => [%{"action_id" => action_id} = action],
              "container" => %{"type" => container_type} = container,
              "team" => %{"id" => workspace_ref},
              "type" => "block_actions",
              "user" => %{"id" => actor_ref}
            } = payload,
          "type" => "interactive"
        },
        workspace_ref,
        %DateTime{} = occurred_at
      ) do
    cond do
      not Retained.retired_slack_action?(action_id) ->
        :ignore

      container_type == "view" ->
        :app_home

      container_type == "message" ->
        with %{"channel_id" => channel_ref, "message_ts" => message_ref} <- container,
             {:ok, ^action_id, action_value} <- action(action, payload),
             true <- reference?(action_value) do
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
            },
            :retired
          )
        else
          _invalid -> :ignore
        end

      true ->
        :ignore
    end
  end

  def retired_control(_envelope, _workspace_ref, _occurred_at), do: :ignore

  defp build_interaction(action_id, action_value, container, context, kind \\ :current) do
    thread_ref = container["thread_ts"]

    values =
      Map.take(context, [:actor_ref, :channel_ref, :envelope_id, :message_ref, :workspace_ref])
      |> Map.values()

    if admitted?(kind, action_id, action_value) and Enum.all?(values, &reference?/1) and
         optional_reference?(thread_ref) and utc?(context.occurred_at) do
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

  # A current control must be a known id with a well-formed value; a retired
  # id is admitted only for the reply and audit row, never as a control.
  defp admitted?(:current, action_id, action_value),
    do: action_id?(action_id) and action_value?(action_id, action_value)

  defp admitted?(:retired, action_id, _action_value),
    do: Retained.retired_slack_action?(action_id)

  @spec setup_action?(String.t()) :: boolean()
  def setup_action?("ryker_setup_" <> _rest = action_id), do: action_id?(action_id)
  def setup_action?("ryker_welcome_" <> _rest = action_id), do: action_id?(action_id)
  def setup_action?(_action_id), do: false

  defp optional_reference?(nil), do: true
  defp optional_reference?(value), do: reference?(value)

  defp reference?(value), do: is_binary(value) and Regex.match?(@reference, value)

  defp action_value?("ryker_answer_input", value),
    do: is_binary(value) and Regex.match?(@choice_value, value)

  defp action_value?("ryker_resume_work", value),
    do: is_binary(value) and Regex.match?(@resume_work_value, value)

  defp action_value?("ryker_work_record", value),
    do: is_binary(value) and Regex.match?(@work_record_value, value)

  defp action_value?(action_id, value)
       when action_id in ~w(ryker_task_check ryker_task_publish),
       do: is_binary(value) and Regex.match?(@task_publication_value, value)

  defp action_value?(action_id, value)
       when action_id in ~w(ryker_task_retry_publication ryker_task_update_publication ryker_task_discard_publication),
       do: is_binary(value) and Regex.match?(@task_publication_recovery_value, value)

  defp action_value?("ryker_welcome_" <> _rest, value),
    do: is_binary(value) and Regex.match?(@welcome_value, value)

  defp action_value?("ryker_delete_schedule", value),
    do: is_binary(value) and Regex.match?(@schedule_control_value, value)

  defp action_value?("ryker_resume_behavior", value),
    do: is_binary(value) and Regex.match?(@behavior_control_value, value)

  defp action_value?("ryker_delete_behavior", value),
    do: is_binary(value) and Regex.match?(@behavior_control_value, value)

  defp action_value?("ryker_forget_memory", value),
    do: is_binary(value) and Regex.match?(@memory_value, value)

  defp action_value?("ryker_setup_" <> _rest, value) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> true
      :error -> false
    end
  end

  defp action_value?(_action_id, value), do: reference?(value)

  defp action_id?(value),
    do:
      is_binary(value) and
        (value in @actions or value == "ryker_submit_input" or
           Regex.match?(@repository_action, value))

  defp action(
         %{"action_id" => "ryker_submit_input", "type" => "button", "value" => ref},
         payload
       ) do
    # Slack includes native state in the authenticated submitting user's payload.
    # Selecting a radio alone is inert; no cross-user staging store is needed.
    case get_in(payload, ["state", "values", ref, "ryker_question_choice"]) do
      %{"type" => "radio_buttons", "selected_option" => %{"value" => value}}
      when is_binary(value) ->
        if String.starts_with?(value, ref <> "|"),
          do: {:ok, "ryker_answer_input", value},
          else: :ignore

      _missing ->
        {:ok, "ryker_submit_input", ref}
    end
  end

  defp action(
         %{
           "action_id" => "ryker_answer_input_" <> index,
           "type" => "button",
           "value" => value
         },
         _payload
       )
       when index in ~w(0 1 2 3 4) and is_binary(value) do
    if String.ends_with?(value, "|" <> index),
      do: {:ok, "ryker_answer_input", value},
      else: :ignore
  end

  defp action(%{"action_id" => action_id, "type" => "button", "value" => action_value}, _payload)
       when action_id != "ryker_answer_input",
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
