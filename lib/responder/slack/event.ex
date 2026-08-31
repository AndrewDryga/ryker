defmodule Responder.Slack.Event do
  @moduledoc """
  Normalizes authenticated Slack Events API envelopes into generic ingress.

  This module performs no model work and owns no credentials. It accepts only
  supported message lifecycles from the configured workspace and suppresses
  Responder's own messages before they can enter durable admission.
  """

  alias Responder.Slack.{Input, PostGrant}

  @supported_message_subtypes [nil, "bot_message", "file_share", "thread_broadcast"]
  @identity_fields [:bot_ref, :bot_user_ref, :workspace_ref]

  @type normalized :: %{
          action_token: String.t() | nil,
          audience: :ambient | :direct | :mention,
          input: Responder.Ingress.Input.t(),
          platform_thread_ref: String.t() | nil
        }

  @spec from_socket(map(), map()) :: {:ok, normalized()} | :ignore | {:error, term()}
  def from_socket(
        %{
          "payload" => %{
            "event" => event,
            "event_id" => event_ref,
            "team_id" => workspace_ref,
            "type" => "event_callback"
          },
          "type" => "events_api"
        },
        %{workspace_ref: workspace_ref} = identity
      )
      when is_map(event) and is_binary(event_ref) do
    with :ok <- identity(identity),
         {:ok, details} <- event_details(event),
         :ok <- not_self(details, identity),
         {:ok, occurred_at, timestamp_revision} <- timestamp(details.event_timestamp),
         {:ok, input} <-
           Input.new(%{
             actor: details.actor,
             channel_ref: details.channel_ref,
             content: details.content,
             event_kind: details.event_kind,
             event_ref: event_ref,
             message_ref: details.message_ref,
             occurred_at: occurred_at,
             post_destination_refs:
               PostGrant.destination_refs(
                 details.content["text"],
                 workspace_ref,
                 identity.bot_user_ref
               ),
             revision: timestamp_revision * 4 + revision_rank(details.event_kind),
             thread_ref: details.thread_ref,
             workspace_ref: workspace_ref
           }) do
      {:ok,
       %{
         action_token: action_token(event),
         audience: audience(details),
         input: input,
         platform_thread_ref: details.thread_ref
       }}
    else
      :ignore -> :ignore
      {:error, {:invalid_slack_event, _field}} = error -> error
      {:error, {:invalid_input, _field}} = error -> error
      {:error, {:invalid_input, _field, _reason}} = error -> error
      {:error, _reason} -> {:error, {:invalid_slack_event, :input}}
    end
  end

  def from_socket(_envelope, _identity), do: :ignore

  defp event_details(%{"type" => "app_mention"} = event) do
    message_details(event, :mention, :message)
  end

  defp event_details(%{"subtype" => "message_changed", "type" => "message"} = event) do
    case event["message"] do
      %{} = message ->
        message
        |> Map.put_new("channel", event["channel"])
        |> Map.put("event_ts", event["event_ts"] || get_in(message, ["edited", "ts"]))
        |> message_details(:ambient, :edit)

      _invalid ->
        {:error, {:invalid_slack_event, :message}}
    end
  end

  defp event_details(%{"subtype" => "message_deleted", "type" => "message"} = event) do
    previous = if is_map(event["previous_message"]), do: event["previous_message"], else: %{}

    details = %{
      "channel" => event["channel"],
      "event_ts" => event["event_ts"],
      "text" => previous["text"],
      "thread_ts" => previous["thread_ts"],
      "ts" => event["deleted_ts"] || previous["ts"],
      "user" => previous["user"]
    }

    message_details(details, :ambient, :delete)
  end

  defp event_details(%{"type" => "message"} = event) do
    if event["subtype"] in @supported_message_subtypes,
      do: message_details(event, :ambient, :message),
      else: :ignore
  end

  defp event_details(_event), do: :ignore

  defp message_details(event, audience, event_kind) do
    with {:ok, actor} <- actor(event),
         :ok <- reference(event["channel"], :channel),
         :ok <- reference(event["ts"], :message_ref),
         :ok <- optional_reference(event["thread_ts"], :thread_ref),
         :ok <- reference(event["event_ts"] || event["ts"], :event_timestamp),
         {:ok, content} <- content(event, event_kind) do
      {:ok,
       %{
         actor: actor,
         audience: audience,
         channel_ref: event["channel"],
         content: content,
         event_kind: event_kind,
         event_timestamp: event["event_ts"] || event["ts"],
         message_ref: event["ts"],
         thread_ref: event["thread_ts"]
       }}
    end
  end

  defp actor(%{"app_id" => ref}) when is_binary(ref), do: {:ok, %{kind: :app, ref: ref}}
  defp actor(%{"bot_id" => ref}) when is_binary(ref), do: {:ok, %{kind: :bot, ref: ref}}
  defp actor(%{"user" => ref}) when is_binary(ref), do: {:ok, %{kind: :user, ref: ref}}
  defp actor(_event), do: {:error, {:invalid_slack_event, :actor}}

  defp content(event, event_kind) do
    content = %{
      "attachments" => list_or_empty(event["attachments"]),
      "blocks" => list_or_empty(event["blocks"]),
      "files" => list_or_empty(event["files"]),
      "slack_event_kind" => Atom.to_string(event_kind),
      "subtype" => event["subtype"],
      "text" => text_or_empty(event["text"])
    }

    if valid_json_collections?(content),
      do: {:ok, content},
      else: {:error, {:invalid_slack_event, :content}}
  end

  defp list_or_empty(nil), do: []
  defp list_or_empty(value), do: value

  defp action_token(%{"action_token" => token})
       when is_binary(token) and byte_size(token) in 1..4_096 do
    if String.valid?(token) and :binary.match(token, <<0>>) == :nomatch,
      do: token,
      else: nil
  end

  defp action_token(_event), do: nil

  defp text_or_empty(nil), do: ""
  defp text_or_empty(value), do: value

  defp valid_json_collections?(content) do
    is_list(content["attachments"]) and is_list(content["blocks"]) and
      is_list(content["files"]) and is_binary(content["text"])
  end

  defp not_self(%{actor: %{kind: :user, ref: ref}}, %{bot_user_ref: ref}), do: :ignore
  defp not_self(%{actor: %{kind: :bot, ref: ref}}, %{bot_ref: ref}), do: :ignore
  defp not_self(_details, _identity), do: :ok

  defp audience(%{audience: :mention}), do: :mention
  defp audience(%{channel_ref: "D" <> _rest}), do: :direct
  defp audience(_details), do: :ambient

  defp timestamp(value) do
    case Regex.run(~r/\A([0-9]{10,})\.([0-9]{1,6})\z/, value || "") do
      [_whole, seconds, fraction] ->
        microseconds =
          String.to_integer(seconds) * 1_000_000 +
            ((fraction <> String.duplicate("0", 6 - byte_size(fraction))) |> String.to_integer())

        case DateTime.from_unix(microseconds, :microsecond) do
          {:ok, datetime} -> {:ok, datetime, microseconds}
          {:error, _reason} -> {:error, {:invalid_slack_event, :timestamp}}
        end

      _invalid ->
        {:error, {:invalid_slack_event, :timestamp}}
    end
  end

  defp revision_rank(:message), do: 0
  defp revision_rank(:edit), do: 1
  defp revision_rank(:delete), do: 2

  defp identity(%{} = identity) do
    if Map.keys(identity) |> Enum.sort() == Enum.sort(@identity_fields) and
         Enum.all?(@identity_fields, &(reference(Map.fetch!(identity, &1), &1) == :ok)),
       do: :ok,
       else: {:error, {:invalid_slack_event, :identity}}
  end

  defp optional_reference(nil, _field), do: :ok
  defp optional_reference(value, field), do: reference(value, field)

  defp reference(value, field) do
    if is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
         String.trim(value) != "" and byte_size(value) <= 1_024,
       do: :ok,
       else: {:error, {:invalid_slack_event, field}}
  end
end
