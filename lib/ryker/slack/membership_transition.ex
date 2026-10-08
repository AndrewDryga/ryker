defmodule Ryker.Slack.MembershipTransition do
  @moduledoc """
  Normalizes authenticated Slack bot membership events before generic message admission.
  """
  alias Ryker.Slack.{Id, Timestamp}

  @enforce_keys [:actor_ref, :channel_ref, :event_ref, :kind, :occurred_at, :workspace_ref]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          actor_ref: String.t() | nil,
          channel_ref: String.t(),
          event_ref: String.t(),
          kind: :joined | :left | :archived | :unarchived | :deleted,
          occurred_at: DateTime.t(),
          workspace_ref: String.t()
        }

  @spec from_socket(map(), map()) :: {:ok, t()} | :ignore | {:error, term()}
  def from_socket(
        %{
          "payload" => %{
            "event" => event,
            "event_id" => event_ref,
            "team_id" => workspace_ref,
            "type" => "event_callback"
          },
          "type" => "events_api"
        } = envelope,
        %{bot_user_ref: bot_user_ref, workspace_ref: workspace_ref}
      )
      when is_map(event) and is_binary(event_ref) do
    with {:ok, kind, channel_ref, actor_ref} <- details(event, bot_user_ref),
         :ok <- reference(channel_ref, :channel_ref),
         :ok <- optional_reference(actor_ref, :actor_ref),
         {:ok, occurred_at} <- occurred_at(event, envelope["payload"]["event_time"]) do
      {:ok,
       %__MODULE__{
         actor_ref: actor_ref,
         channel_ref: channel_ref,
         event_ref: event_ref,
         kind: kind,
         occurred_at: occurred_at,
         workspace_ref: workspace_ref
       }}
    end
  end

  def from_socket(_envelope, _identity), do: :ignore

  defp details(
         %{
           "channel" => channel_ref,
           "type" => "member_joined_channel",
           "user" => bot_user_ref
         } = event,
         bot_user_ref
       ),
       do: {:ok, :joined, channel_ref, event["inviter"]}

  defp details(
         %{
           "channel" => channel_ref,
           "type" => "member_left_channel",
           "user" => bot_user_ref
         },
         bot_user_ref
       ),
       do: {:ok, :left, channel_ref, nil}

  defp details(%{"channel" => channel_ref, "type" => "channel_deleted"}, _bot_user_ref)
       when is_binary(channel_ref),
       do: {:ok, :deleted, channel_ref, nil}

  defp details(%{"channel" => channel_ref, "type" => "group_deleted"}, _bot_user_ref)
       when is_binary(channel_ref),
       do: {:ok, :deleted, channel_ref, nil}

  defp details(%{"channel" => channel_ref, "type" => type} = event, _bot_user_ref)
       when is_binary(channel_ref) and type in ["channel_archive", "group_archive"],
       do: {:ok, :archived, channel_ref, event["user"]}

  defp details(%{"channel" => channel_ref, "type" => type} = event, _bot_user_ref)
       when is_binary(channel_ref) and type in ["channel_unarchive", "group_unarchive"],
       do: {:ok, :unarchived, channel_ref, event["user"]}

  defp details(_event, _bot_user_ref), do: :ignore

  defp occurred_at(%{"event_ts" => timestamp}, _event_time) when is_binary(timestamp),
    do: slack_timestamp(timestamp)

  defp occurred_at(_event, seconds) when is_integer(seconds),
    do: seconds |> DateTime.from_unix() |> occurred_at_result()

  defp occurred_at(_event, _event_time), do: {:error, {:invalid_slack_membership, :occurred_at}}

  defp slack_timestamp(value) do
    case Timestamp.to_datetime(value) do
      {:ok, datetime} -> {:ok, datetime}
      :error -> {:error, {:invalid_slack_membership, :occurred_at}}
    end
  end

  # A time past the year 9999 is refused in the membership's own words, as a
  # malformed one is.
  defp occurred_at_result({:ok, datetime}), do: {:ok, datetime}

  defp occurred_at_result({:error, _beyond}),
    do: {:error, {:invalid_slack_membership, :occurred_at}}

  defp optional_reference(nil, _field), do: :ok
  defp optional_reference(value, field), do: reference(value, field)

  defp reference(value, field) do
    if Id.valid?(value),
      do: :ok,
      else: {:error, {:invalid_slack_membership, field}}
  end
end
