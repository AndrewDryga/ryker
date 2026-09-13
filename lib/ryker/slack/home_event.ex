defmodule Ryker.Slack.HomeEvent do
  @moduledoc false

  @enforce_keys [:actor_ref, :event_ref, :workspace_ref]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          actor_ref: String.t(),
          event_ref: String.t(),
          workspace_ref: String.t()
        }

  @spec from_socket(map(), map()) :: {:ok, t()} | :ignore
  def from_socket(
        %{
          "type" => "events_api",
          "payload" => %{
            "event" => %{
              "tab" => "home",
              "type" => "app_home_opened",
              "user" => actor_ref
            },
            "event_id" => event_ref,
            "team_id" => workspace_ref,
            "type" => "event_callback"
          }
        },
        %{workspace_ref: workspace_ref}
      ) do
    if reference?(actor_ref) and reference?(event_ref) and reference?(workspace_ref) do
      {:ok,
       %__MODULE__{
         actor_ref: actor_ref,
         event_ref: event_ref,
         workspace_ref: workspace_ref
       }}
    else
      :ignore
    end
  end

  def from_socket(_envelope, _identity), do: :ignore

  defp reference?(value) do
    is_binary(value) and String.valid?(value) and String.trim(value) != "" and
      byte_size(value) <= 256
  end
end
