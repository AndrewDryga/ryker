defmodule Ryker.Slack.Client do
  @moduledoc """
  Bounded Slack Web API adapter for message and emoji delivery.

  Posted messages carry host-owned metadata. Retries walk the exact channel or
  thread until that metadata is found, so a lost HTTP response cannot duplicate
  a visible reply.

  This module is the `Ryker.Slack.API` and `Ryker.Slack.MemberDirectory`
  surface bindings configure as `api:` and `directory:`: the client struct and
  every callback. The work behind each callback lives with what it talks to:
  `Client.Messages`, `Client.Files`, `Client.Reactions`, `Client.Assistant`,
  `Client.Conversations` (the conversations Ryker reads), `Client.Rooms` (the
  ones it creates and sets up), `Client.Users` and `Client.Views`. Each sends
  its requests through `Client.Transport`, walks cursor-paged listings with
  `Client.Pagination` and checks its arguments and replies with
  `Client.Fields`.
  """

  @behaviour Ryker.Slack.API
  @behaviour Ryker.Slack.MemberDirectory

  alias Ryker.Delivery.JSONClient

  alias Ryker.Slack.Client.{
    Assistant,
    Conversations,
    Files,
    Messages,
    Reactions,
    Rooms,
    Users,
    Views
  }

  alias Ryker.Slack.UploadClient

  @required_fields [:http, :requester]
  @upload_receive_timeout_ms 120_000
  @fields @required_fields ++ [:upload_http, :uploader]

  @enforce_keys @required_fields
  defstruct @required_fields ++ [upload_http: nil, uploader: nil]

  @type t :: %__MODULE__{
          http: term(),
          requester: module(),
          upload_http: term() | nil,
          uploader: module() | nil
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attributes) do
    with {:ok, attributes} <- normalize_attributes(attributes),
         client <- struct!(__MODULE__, attributes),
         {:ok, client} <- prepare_uploader(client),
         true <- requester?(client.requester),
         true <- uploader?(client) do
      {:ok, client}
    else
      false -> {:error, {:invalid_slack_client, :requester}}
      {:error, _reason} = error -> error
    end
  end

  # --- messages -------------------------------------------------------------

  @impl true
  defdelegate find_message(client, channel, thread, delivery_ref), to: Messages

  @impl true
  defdelegate find_message(client, channel, thread, delivery_ref, oldest), to: Messages

  @impl true
  defdelegate post_message(client, channel, thread, body, delivery_ref), to: Messages

  @impl true
  defdelegate post_ephemeral(client, channel, actor, thread, text), to: Messages

  @impl true
  defdelegate update_message(client, channel, message_ref, body, delivery_ref), to: Messages

  @impl true
  defdelegate read_messages(client, channel_ref, thread_ref, document), to: Messages

  # --- files ----------------------------------------------------------------

  @impl true
  defdelegate find_files(client, channel, thread, filenames, oldest), to: Files

  @impl true
  defdelegate upload_files(client, channel, thread, body, delivery_ref, files), to: Files

  @impl true
  defdelegate file_info(client, file_ref), to: Files

  # --- reactions ------------------------------------------------------------

  @impl true
  defdelegate add_reaction(client, channel, message_ref, emoji_name), to: Reactions

  @impl true
  defdelegate remove_reaction(client, channel, message_ref, emoji_name), to: Reactions

  # --- assistant ------------------------------------------------------------

  @impl true
  defdelegate set_thread_status(client, channel, thread_ref, status), to: Assistant

  @impl true
  defdelegate search_context(client, action_token, document), to: Assistant

  # --- conversations Ryker reads --------------------------------------------

  @impl true
  defdelegate list_conversations(client, document), to: Conversations

  @impl true
  defdelegate conversation_info(client, channel_ref), to: Conversations

  @impl true
  defdelegate conversation_state(client, channel_ref), to: Conversations

  @impl true
  defdelegate list_bookmarks(client, channel_ref), to: Conversations

  @impl true
  defdelegate joined_conversations(client), to: Conversations

  @impl true
  defdelegate shared_conversations(client, user_ref, workspace_ref), to: Conversations

  # --- rooms Ryker creates and sets up --------------------------------------

  @impl true
  defdelegate ensure_conversation(
                client,
                workspace_ref,
                name,
                private,
                creator_ref,
                requested_at
              ),
              to: Rooms

  @impl true
  defdelegate invite_users(client, channel_ref, users), to: Rooms

  @impl true
  defdelegate set_topic(client, channel_ref, topic), to: Rooms

  @impl true
  defdelegate leave_conversation(client, channel_ref), to: Rooms

  @impl true
  defdelegate pin_message(client, channel_ref, message_ref), to: Rooms

  # --- people ---------------------------------------------------------------

  @impl Ryker.Slack.MemberDirectory
  defdelegate user_allowed(client, user_ref, workspace_ref), to: Users

  @impl Ryker.Slack.MemberDirectory
  defdelegate user_group_members(client, user_group_ref, workspace_ref), to: Users

  @impl Ryker.Slack.MemberDirectory
  defdelegate workspace_admin(client, user_ref, workspace_ref), to: Users

  # --- views ----------------------------------------------------------------

  @impl true
  defdelegate publish_home(client, user_ref, view), to: Views

  @impl true
  defdelegate open_view(client, trigger_ref, view), to: Views

  # --- construction ---------------------------------------------------------

  defp normalize_attributes(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes) do
      normalize_attributes(Map.new(attributes))
    else
      {:error, {:invalid_slack_client, :fields}}
    end
  end

  defp normalize_attributes(%{} = attributes) do
    keys = Map.keys(attributes) |> Enum.sort()

    cond do
      keys == Enum.sort(@required_fields) ->
        {:ok, Map.merge(%{upload_http: nil, uploader: nil}, attributes)}

      keys == Enum.sort(@fields) ->
        {:ok, attributes}

      true ->
        {:error, {:invalid_slack_client, :fields}}
    end
  end

  defp normalize_attributes(_attributes), do: {:error, {:invalid_slack_client, :fields}}

  defp requester?(requester) do
    is_atom(requester) and Code.ensure_loaded?(requester) and
      function_exported?(requester, :request, 5)
  end

  # Up to 8 MiB goes to Slack's file host in one request, which an API call's
  # 30-second wait cut short twice the day uploads began (2026-10-04 review).
  defp prepare_uploader(
         %__MODULE__{http: %JSONClient{} = http, upload_http: nil, uploader: nil} = client
       ) do
    case UploadClient.new(
           base_origin: "https://files.slack.com",
           finch: http.finch,
           receive_timeout: @upload_receive_timeout_ms
         ) do
      {:ok, upload_http} -> {:ok, %{client | upload_http: upload_http, uploader: UploadClient}}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_uploader(client), do: {:ok, client}

  defp uploader?(%__MODULE__{upload_http: nil, uploader: nil}), do: true

  defp uploader?(%__MODULE__{upload_http: upload_http, uploader: uploader}) do
    not is_nil(upload_http) and is_atom(uploader) and Code.ensure_loaded?(uploader) and
      function_exported?(uploader, :upload, 4)
  end
end
