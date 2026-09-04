defmodule Responder.Slack.HomeInteraction do
  @moduledoc false

  @actions %{
    "responder_home_delete_behavior" => {:delete_behavior, "behavior:"},
    "responder_home_delete_schedule" => {:delete_schedule, "schedule:"},
    "responder_home_disable_behavior" => {:disable_behavior, "behavior:"},
    "responder_home_enable_behavior" => {:enable_behavior, "behavior:"},
    "responder_home_forget_memory" => {:forget_memory, "memory:"},
    "responder_home_forget_memory_review" => {:forget_memory_review, "memory-review:"},
    "responder_home_keep_memory_review" => {:keep_memory_review, "memory-review:"},
    "responder_home_merge_memory_review" => {:merge_memory_review, "memory-review:"},
    "responder_home_pause_schedule" => {:pause_schedule, "schedule:"},
    "responder_home_resume_schedule" => {:resume_schedule, "schedule:"}
  }
  @reference ~r/\A[A-Za-z0-9_.:-]{1,256}\z/

  @enforce_keys [
    :action,
    :actor_ref,
    :event_ref,
    :occurred_at,
    :resource_ref,
    :workspace_ref
  ]
  defstruct @enforce_keys

  @type action ::
          :delete_behavior
          | :delete_schedule
          | :disable_behavior
          | :enable_behavior
          | :forget_memory
          | :forget_memory_review
          | :keep_memory_review
          | :merge_memory_review
          | :pause_schedule
          | :resume_schedule

  @type t :: %__MODULE__{
          action: action(),
          actor_ref: String.t(),
          event_ref: String.t(),
          occurred_at: DateTime.t(),
          resource_ref: String.t(),
          workspace_ref: String.t()
        }

  @spec from_socket(map(), String.t(), DateTime.t()) :: {:ok, t()} | :ignore
  def from_socket(
        %{
          "envelope_id" => envelope_ref,
          "payload" => %{
            "actions" => [
              %{"action_id" => action_id, "type" => "button", "value" => resource_ref}
            ],
            "container" => %{"type" => "view", "view_id" => view_ref},
            "team" => %{"id" => workspace_ref},
            "type" => "block_actions",
            "user" => %{"id" => actor_ref},
            "view" => %{"id" => view_ref, "type" => "home"}
          },
          "type" => "interactive"
        },
        workspace_ref,
        %DateTime{} = occurred_at
      ) do
    with {action, prefix} <- Map.get(@actions, action_id),
         true <- reference?(envelope_ref),
         true <- reference?(actor_ref),
         true <- reference?(workspace_ref),
         true <- reference?(view_ref),
         true <- reference?(resource_ref),
         true <- String.starts_with?(resource_ref, prefix),
         true <- utc?(occurred_at) do
      {:ok,
       %__MODULE__{
         action: action,
         actor_ref: actor_ref,
         event_ref: "interaction:#{envelope_ref}",
         occurred_at: normalize_datetime(occurred_at),
         resource_ref: resource_ref,
         workspace_ref: workspace_ref
       }}
    else
      _invalid -> :ignore
    end
  end

  def from_socket(_envelope, _workspace_ref, _occurred_at), do: :ignore

  defp reference?(value), do: is_binary(value) and Regex.match?(@reference, value)

  defp utc?(%DateTime{} = value),
    do: value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0

  defp normalize_datetime(%DateTime{microsecond: {microsecond, _precision}} = value),
    do: %{value | microsecond: {microsecond, 6}}
end
