defmodule Responder.Slack.Shortcut do
  @moduledoc """
  Normalizes the host-owned Slack message shortcut into generic ingress.

  The actor is the member who invoked the shortcut, while the selected message
  remains untrusted content and the exact source item for reply/reaction scope.
  """

  alias Responder.CanonicalJSON
  alias Responder.Ingress.Input

  @callback_id "responder_investigate_message"
  @timestamp ~r/\A[0-9]{10,}\.[0-9]{1,6}\z/

  @type normalized :: %{
          action_token: nil,
          audience: :direct,
          input: Input.t(),
          platform_thread_ref: String.t()
        }

  @spec from_socket(map(), String.t(), DateTime.t()) ::
          {:ok, normalized()} | :ignore | {:error, term()}
  def from_socket(
        %{
          "envelope_id" => envelope_ref,
          "payload" => %{
            "callback_id" => @callback_id,
            "channel" => %{"id" => channel_ref},
            "message" => message,
            "team" => %{"id" => workspace_ref},
            "type" => "message_action",
            "user" => %{"id" => actor_ref}
          },
          "type" => "interactive"
        },
        workspace_ref,
        %DateTime{} = occurred_at
      )
      when is_map(message) do
    with :ok <- reference(envelope_ref, :envelope_ref),
         :ok <- reference(actor_ref, :actor_ref),
         :ok <- reference(channel_ref, :channel_ref),
         {:ok, message_ref} <- timestamp(message["ts"], :message_ref),
         {:ok, thread_ref} <- thread_ref(message["thread_ts"], message_ref),
         {:ok, content} <- content(message),
         {:ok, input} <-
           Input.new(%{
             actor: %{kind: :user, ref: actor_ref},
             content: content,
             destination: %{
               conversation_ref: "slack:#{workspace_ref}:#{channel_ref}",
               thread_ref: thread_ref,
               transport: "slack"
             },
             event_kind: :event,
             event_ref: "shortcut:#{envelope_ref}",
             native_input_id:
               "slack-shortcut:" <> CanonicalJSON.digest([workspace_ref, envelope_ref]),
             occurred_at: occurred_at,
             occurred_at_source: :ingress,
             revision: 1,
             source: %{kind: "slack", ref: workspace_ref},
             source_capabilities: %{"react" => %{"emoji_names" => nil}},
             source_item_ref: message_ref
           }) do
      {:ok,
       %{
         action_token: nil,
         audience: :direct,
         input: input,
         platform_thread_ref: thread_ref
       }}
    else
      {:error, {:invalid_input, _field}} = error -> error
      {:error, {:invalid_input, _field, _reason}} = error -> error
      {:error, _reason} = error -> error
    end
  end

  def from_socket(
        %{
          "payload" => %{
            "callback_id" => @callback_id,
            "type" => "message_action"
          }
        },
        _workspace_ref,
        _occurred_at
      ),
      do: {:error, {:invalid_slack_shortcut, :payload}}

  def from_socket(_envelope, _workspace_ref, _occurred_at), do: :ignore

  defp content(message) do
    content = %{
      "attachments" => list_or_empty(message["attachments"]),
      "blocks" => list_or_empty(message["blocks"]),
      "files" => list_or_empty(message["files"]),
      "selected_message_actor_ref" => optional_text(message["user"]),
      "slack_event_kind" => "shortcut",
      "text" => text_or_empty(message["text"])
    }

    if is_list(content["attachments"]) and is_list(content["blocks"]) and
         is_list(content["files"]) and is_binary(content["text"]),
       do: {:ok, content},
       else: {:error, {:invalid_slack_shortcut, :content}}
  end

  defp thread_ref(nil, message_ref), do: {:ok, message_ref}
  defp thread_ref(value, _message_ref), do: timestamp(value, :thread_ref)

  defp timestamp(value, field) do
    if is_binary(value) and Regex.match?(@timestamp, value),
      do: {:ok, value},
      else: {:error, {:invalid_slack_shortcut, field}}
  end

  defp reference(value, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..980 and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: :ok,
       else: {:error, {:invalid_slack_shortcut, field}}
  end

  defp list_or_empty(nil), do: []
  defp list_or_empty(value), do: value

  defp text_or_empty(nil), do: ""
  defp text_or_empty(value), do: value

  defp optional_text(nil), do: nil
  defp optional_text(value) when is_binary(value), do: value
  defp optional_text(_value), do: nil
end
