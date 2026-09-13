defmodule Ryker.Slack.HomeInteraction do
  @moduledoc false

  @actions %{
    "ryker_home_delete_behavior" => {:delete_behavior, ["behavior-control:", "behavior:"]},
    "ryker_home_delete_schedule" => {:delete_schedule, ["schedule-control:", "schedule:"]},
    "ryker_home_discard_publication" => {:discard_publication, "publication-recovery:"},
    "ryker_home_discard_workspace" => {:discard_workspace, "ryker-work-control:"},
    "ryker_home_disable_behavior" => {:disable_behavior, ["behavior-control:", "behavior:"]},
    "ryker_home_edit_memory_review" => {:edit_memory_review, "memory-review:"},
    "ryker_home_enable_behavior" => {:enable_behavior, ["behavior-control:", "behavior:"]},
    "ryker_home_forget_memory" => {:forget_memory, "memory:"},
    "ryker_home_forget_memory_review" => {:forget_memory_review, "memory-review:"},
    "ryker_home_keep_memory_review" => {:keep_memory_review, "memory-review:"},
    "ryker_home_merge_memory_review" => {:merge_memory_review, "memory-review:"},
    "ryker_home_open" => {:open_resource, :resource},
    "ryker_home_pause_schedule" => {:pause_schedule, ["schedule-control:", "schedule:"]},
    "ryker_home_resume_schedule" => {:resume_schedule, ["schedule-control:", "schedule:"]},
    "ryker_home_retry_publication" => {:retry_publication, "publication-recovery:"},
    "ryker_home_run_schedule" => {:run_schedule, "schedule:"},
    "ryker_home_show_collection" => {:show_collection, "home-collection:"},
    "ryker_home_show_dashboard" => {:show_dashboard, "home-collection:"},
    "ryker_home_update_publication" => {:update_publication, "publication-recovery:"}
  }
  @reference ~r/\A[A-Za-z0-9_.:-]{1,256}\z/
  @action_instance ~r/\A(.+)__i([0-9]+)\z/
  # Work sessions created before the 2026-09-13 rename keep their retained
  # external_ref prefix; an Open control rendered from one must still resolve.
  @resource_prefixes ~w(behavior: episode: incident-room: memory: memory-review: publication: ryker-work: schedule: task-card:) ++
                       [Ryker.Retained.work_session_prefix()]

  @enforce_keys [
    :action,
    :actor_ref,
    :event_ref,
    :occurred_at,
    :resource_ref,
    :workspace_ref
  ]
  defstruct @enforce_keys ++ [trigger_ref: nil]

  @type action ::
          :delete_behavior
          | :delete_schedule
          | :discard_publication
          | :discard_workspace
          | :disable_behavior
          | :edit_memory_review
          | :enable_behavior
          | :forget_memory
          | :forget_memory_review
          | :keep_memory_review
          | :merge_memory_review
          | :open_resource
          | :pause_schedule
          | :resume_schedule
          | :retry_publication
          | :run_schedule
          | :show_collection
          | :show_dashboard
          | :update_publication

  @type t :: %__MODULE__{
          action: action(),
          actor_ref: String.t(),
          event_ref: String.t(),
          occurred_at: DateTime.t(),
          resource_ref: String.t(),
          trigger_ref: String.t() | nil,
          workspace_ref: String.t()
        }

  @spec from_socket(map(), String.t(), DateTime.t()) :: {:ok, t()} | :ignore
  def from_socket(
        %{
          "envelope_id" => envelope_ref,
          "payload" =>
            %{
              "actions" => [
                %{"action_id" => action_id, "type" => "button", "value" => resource_ref}
              ],
              "container" => %{"type" => "view", "view_id" => view_ref},
              "team" => %{"id" => workspace_ref},
              "type" => "block_actions",
              "user" => %{"id" => actor_ref},
              "view" => %{"id" => view_ref, "type" => "home"}
            } = payload,
          "type" => "interactive"
        },
        workspace_ref,
        %DateTime{} = occurred_at
      ) do
    with {action, prefix} <- action_route(action_id),
         true <- reference?(envelope_ref),
         true <- reference?(actor_ref),
         true <- reference?(workspace_ref),
         true <- reference?(view_ref),
         true <- reference?(resource_ref),
         true <- resource?(resource_ref, prefix),
         true <- optional_reference?(payload["trigger_id"]),
         true <- utc?(occurred_at) do
      {:ok,
       %__MODULE__{
         action: action,
         actor_ref: actor_ref,
         event_ref: "interaction:#{envelope_ref}",
         occurred_at: normalize_datetime(occurred_at),
         resource_ref: resource_ref,
         trigger_ref: payload["trigger_id"],
         workspace_ref: workspace_ref
       }}
    else
      _invalid -> :ignore
    end
  end

  def from_socket(_envelope, _workspace_ref, _occurred_at), do: :ignore

  defp action_route(action_id) when is_binary(action_id) do
    action_id
    |> base_action_id()
    |> then(&Map.get(@actions, &1))
  end

  defp action_route(_action_id), do: nil

  defp base_action_id(action_id) do
    case Regex.run(@action_instance, action_id, capture: :all_but_first) do
      [base, instance] ->
        case Integer.parse(instance) do
          {instance, ""} when instance >= 2 -> base
          _invalid -> action_id
        end

      _without_instance ->
        action_id
    end
  end

  defp reference?(value), do: is_binary(value) and Regex.match?(@reference, value)

  defp optional_reference?(nil), do: true
  defp optional_reference?(value), do: reference?(value)

  defp resource?(value, prefix) when is_binary(prefix), do: String.starts_with?(value, prefix)

  defp resource?(value, prefixes) when is_list(prefixes),
    do: Enum.any?(prefixes, &String.starts_with?(value, &1))

  defp resource?(value, :resource),
    do: Enum.any?(@resource_prefixes, &String.starts_with?(value, &1))

  defp utc?(%DateTime{} = value),
    do: value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0

  defp normalize_datetime(%DateTime{microsecond: {microsecond, _precision}} = value),
    do: %{value | microsecond: {microsecond, 6}}
end
