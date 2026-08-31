defmodule Responder.Slack.Interaction do
  @moduledoc """
  One authenticated Slack control selection normalized from Socket Mode.

  Only host-issued action IDs are retained. Arbitrary model-authored Block Kit
  is never interpreted as a control.
  """

  @actions ~w(responder_answer_input responder_check_publication responder_close_work responder_confirm_automation responder_confirm_behavior responder_confirm_memory responder_confirm_schedule responder_diff_page responder_open_incident responder_open_publication responder_publish_draft responder_review_publication responder_start_engineering_task responder_stop_work responder_task_check responder_task_publish responder_task_readiness responder_view_diff responder_work_record responder_setup_alerts_automatic responder_setup_alerts_offer responder_setup_alerts_reply responder_setup_audience_none responder_setup_be_proactive responder_setup_cancel responder_setup_customize responder_setup_participation_mentions responder_setup_participation_proactive responder_setup_participation_shadow responder_setup_restart responder_setup_safe_defaults responder_setup_save)
  @repository_action ~r/\Aresponder_setup_repository_[0-9]{1,2}\z/
  @reference ~r/\A[A-Za-z0-9_.:-]{1,256}\z/
  @choice_value ~r/\Arecord:input_request:[A-Za-z0-9_.:-]{1,220}\|[0-9]{1,2}\z/
  @work_record_value ~r/\A(?:task-card|incident-room):[A-Za-z0-9_.:-]{1,220}\|(?:timeline|evidence|handoff|postmortem)\z/
  @diff_page_value ~r/\A(?:task-card|incident-room):[A-Za-z0-9_.:-]{1,220}\|[0-9a-f]{64}\|[0-9]{1,10}\z/
  @task_publication_value ~r/\Atask-card:[A-Za-z0-9_.:-]{1,220}\|(?:publication|record:publication_offer):[A-Za-z0-9_.:-]{1,220}\z/

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
          "payload" => %{
            "actions" => [action],
            "container" =>
              %{
                "channel_id" => channel_ref,
                "is_ephemeral" => false,
                "message_ts" => message_ref,
                "type" => "message"
              } = container,
            "team" => %{"id" => workspace_ref},
            "type" => "block_actions",
            "user" => %{"id" => actor_ref}
          },
          "type" => "interactive"
        },
        workspace_ref,
        %DateTime{} = occurred_at
      ) do
    case action(action) do
      {:ok, action_id, action_value} ->
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

      :ignore ->
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
  def setup_action?(_action_id), do: false

  defp optional_reference?(nil), do: true
  defp optional_reference?(value), do: reference?(value)

  defp reference?(value), do: is_binary(value) and Regex.match?(@reference, value)

  defp action_value?("responder_answer_input", value),
    do: is_binary(value) and Regex.match?(@choice_value, value)

  defp action_value?("responder_work_record", value),
    do: is_binary(value) and Regex.match?(@work_record_value, value)

  defp action_value?("responder_diff_page", value),
    do: is_binary(value) and Regex.match?(@diff_page_value, value)

  defp action_value?(action_id, value)
       when action_id in ~w(responder_task_check responder_task_publish responder_task_readiness),
       do: is_binary(value) and Regex.match?(@task_publication_value, value)

  defp action_value?("responder_setup_" <> _rest, value) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> true
      :error -> false
    end
  end

  defp action_value?(_action_id, value), do: reference?(value)

  defp action_id?(value),
    do: is_binary(value) and (value in @actions or Regex.match?(@repository_action, value))

  defp action(%{"action_id" => action_id, "type" => "button", "value" => action_value}),
    do: {:ok, action_id, action_value}

  defp action(%{
         "action_id" => action_id,
         "selected_option" => %{"value" => action_value},
         "type" => "overflow"
       }),
       do: {:ok, action_id, action_value}

  defp action(_action), do: :ignore

  defp utc?(%DateTime{} = value),
    do: value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0

  defp normalize_datetime(%DateTime{microsecond: {microsecond, _precision}} = value),
    do: %{value | microsecond: {microsecond, 6}}
end
