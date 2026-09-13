defmodule Ryker.Slack.Client do
  @moduledoc """
  Bounded Slack Web API adapter for message and emoji delivery.

  Posted messages carry host-owned metadata. Retries walk the exact channel or
  thread until that metadata is found, so a lost HTTP response cannot duplicate
  a visible reply.

  This module is the `Ryker.Slack.API` surface: every callback validates its
  arguments, sends one request through `Client.Transport` and reads the reply.
  `Client.Pagination` walks cursor-paged listings, `Client.Conversations` owns
  the conversation, bookmark and user documents and pages, `Client.Files` the
  attachment uploads, and `Client.Fields` the argument and shape checks.
  """

  @behaviour Ryker.Slack.API
  @behaviour Ryker.Slack.MemberDirectory

  alias Ryker.Delivery.JSONClient
  alias Ryker.Slack.Client.{Conversations, Fields, Files, Pagination, Transport}
  alias Ryker.Slack.{Renderer, UploadClient}
  alias Ryker.Slack.Renderer.Blocks

  @required_fields [:http, :requester]
  @fields @required_fields ++ [:upload_http, :uploader]
  @page_size 100
  @conversation_page_size 200

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
  def find_message(client, channel, thread, delivery_ref) do
    with :ok <- Fields.text(channel),
         :ok <- Fields.optional_text(thread),
         :ok <- Fields.text(delivery_ref) do
      Pagination.find(
        client,
        &history_path(channel, thread, &1),
        &history/1,
        &find_delivery(&1, delivery_ref),
        @page_size
      )
    end
  end

  @impl true
  def post_message(client, channel, thread, body, delivery_ref) do
    with {:ok, rendered} <- render(body),
         :ok <- Fields.text(channel),
         :ok <- Fields.optional_text(thread),
         :ok <- Fields.text(delivery_ref),
         document <- channel |> message_document(rendered, delivery_ref) |> put_thread(thread),
         {:ok, response} <- Transport.request(client, :post, "/chat.postMessage", document),
         {:ok, response_body} <- Transport.response(response) do
      case response_body do
        %{"ts" => message_ref} when is_binary(message_ref) and message_ref != "" ->
          {:ok, message_ref}

        _invalid ->
          {:error, {:slack_protocol_error, :message}}
      end
    end
  end

  @impl true
  def post_ephemeral(client, channel, actor, thread, text) do
    with :ok <- Fields.text(channel),
         :ok <- Fields.text(actor),
         :ok <- Fields.optional_text(thread),
         :ok <- Fields.text(text),
         document <-
           %{"channel" => channel, "text" => text, "user" => actor}
           |> put_thread(thread),
         {:ok, response} <- Transport.request(client, :post, "/chat.postEphemeral", document),
         {:ok, _body} <- Transport.response(response) do
      :ok
    end
  end

  @impl true
  def update_message(client, channel, message_ref, body, delivery_ref) do
    with {:ok, rendered} <- render(body),
         :ok <- Fields.text(channel),
         :ok <- Fields.text(message_ref),
         :ok <- Fields.text(delivery_ref),
         document <-
           channel
           |> message_document(rendered, delivery_ref)
           |> Map.put("ts", message_ref),
         {:ok, response} <- Transport.request(client, :post, "/chat.update", document),
         {:ok, response_body} <- Transport.response(response),
         true <- response_body["ts"] == message_ref and response_body["channel"] == channel do
      :ok
    else
      false -> {:error, {:slack_protocol_error, :message_update}}
      {:error, _reason} = error -> error
    end
  end

  defp render(body) when is_binary(body) do
    with :ok <- Fields.text(body) do
      {:ok, %{"text" => Blocks.escape(body)}}
    end
  end

  defp render(%{} = document), do: Renderer.render(document)
  defp render(_body), do: {:error, {:invalid_slack_api_request, :message}}

  defp message_document(channel, rendered, delivery_ref) do
    Map.merge(rendered, %{
      "channel" => channel,
      "metadata" => %{
        "event_payload" => %{"id" => delivery_ref},
        "event_type" => "ryker_delivery"
      },
      "mrkdwn" => false,
      "unfurl_links" => false,
      "unfurl_media" => false
    })
  end

  defp put_thread(document, nil), do: document
  defp put_thread(document, thread), do: Map.put(document, "thread_ts", thread)

  # --- files ----------------------------------------------------------------

  @impl true
  def find_files(client, channel, thread, filenames) do
    with :ok <- Fields.text(channel),
         :ok <- Fields.optional_text(thread),
         :ok <- Files.filenames(filenames) do
      Pagination.find(
        client,
        &history_path(channel, thread, &1),
        &history/1,
        &Files.find_delivery(&1, filenames),
        @page_size
      )
    end
  end

  @impl true
  def upload_files(client, channel, thread, body, delivery_ref, files) do
    with :ok <- Fields.text(channel),
         :ok <- Fields.optional_text(thread),
         {:ok, rendered} <- render(body),
         :ok <- Fields.text(delivery_ref),
         :ok <- Files.uploads(files),
         :ok <- upload_configured(client),
         {:ok, uploaded} <- Files.upload_external(client, files),
         document <-
           channel |> Files.completion_document(rendered, uploaded) |> put_thread(thread),
         {:ok, response} <-
           Transport.request(client, :post, "/files.completeUploadExternal", document),
         {:ok, _body} <- Transport.response(response) do
      case find_files(client, channel, thread, Enum.map(files, & &1.filename)) do
        {:ok, message_ref} -> {:ok, message_ref}
        :not_found -> {:error, {:slack_reconciliation_pending, :file_share}}
        {:error, _reason} = error -> error
      end
    end
  end

  @impl true
  def file_info(client, file_ref) do
    with :ok <- Fields.slack_id(file_ref),
         path <- "/files.info?" <> URI.encode_query(file: file_ref),
         {:ok, response} <- Transport.request(client, :get, path, nil),
         {:ok, %{"file" => %{"id" => ^file_ref} = file}} <- Transport.response(response),
         :ok <- Fields.bounded_result(file, :file) do
      {:ok, file}
    else
      {:ok, _invalid} -> {:error, {:slack_protocol_error, :file}}
      {:error, _reason} = error -> error
    end
  end

  # --- reactions ------------------------------------------------------------

  @impl true
  def add_reaction(client, channel, message_ref, emoji_name) do
    with :ok <- Fields.text(channel),
         :ok <- Fields.text(message_ref),
         :ok <- Fields.text(emoji_name),
         {:ok, response} <-
           Transport.request(client, :post, "/reactions.add", %{
             "channel" => channel,
             "name" => emoji_name,
             "timestamp" => message_ref
           }) do
      reaction_response(response, "already_reacted")
    end
  end

  @impl true
  def remove_reaction(client, channel, message_ref, emoji_name) do
    with :ok <- Fields.text(channel),
         :ok <- Fields.text(message_ref),
         :ok <- Fields.text(emoji_name),
         {:ok, response} <-
           Transport.request(client, :post, "/reactions.remove", %{
             "channel" => channel,
             "name" => emoji_name,
             "timestamp" => message_ref
           }) do
      reaction_response(response, "no_reaction")
    end
  end

  # A reaction that is already there, or already gone, is the state that was
  # asked for; Slack reports it as an error and the delivery treats it as done.
  defp reaction_response(%{body: %{"error" => settled, "ok" => false}, status: 200}, settled),
    do: :ok

  defp reaction_response(response, _settled),
    do: response |> Transport.response() |> Transport.success()

  # --- assistant ------------------------------------------------------------

  @impl true
  def set_thread_status(client, channel, thread_ref, status) do
    with :ok <- Fields.slack_id(channel),
         :ok <- Fields.message_timestamp(thread_ref),
         :ok <- Fields.thread_status(status),
         {:ok, response} <-
           Transport.request(client, :post, "/assistant.threads.setStatus", %{
             "channel_id" => channel,
             "status" => status,
             "thread_ts" => thread_ref
           }),
         {:ok, _body} <- Transport.response(response) do
      :ok
    end
  end

  @impl true
  def search_context(client, action_token, document) do
    with :ok <- action_token(action_token),
         :ok <- search_document(document),
         {:ok, response} <-
           Transport.request(
             client,
             :post,
             "/assistant.search.context",
             Map.put(document, "action_token", action_token)
           ),
         {:ok, body} <- Transport.response(response) do
      search_response(body)
    end
  end

  defp action_token(value) do
    if Fields.bounded_text(value, 4_096) == :ok and :binary.match(value, <<0>>) == :nomatch,
      do: :ok,
      else: {:error, {:invalid_slack_api_request, :action_token}}
  end

  defp search_document(%{"query" => query} = document) do
    allowed =
      ~w(after before channel_types content_types context_channel_id cursor include_bots include_context_messages limit query sort sort_dir)

    valid =
      Enum.all?([
        Map.keys(document) -- allowed == [],
        Fields.bounded_text(query, 2_048) == :ok,
        optional_enum_list(document["channel_types"], ~w(public_channel private_channel mpim im)),
        optional_enum_list(document["content_types"], ~w(messages files channels users)),
        optional_boolean(document["include_bots"]),
        optional_boolean(document["include_context_messages"]),
        optional_positive_integer(document["after"]),
        optional_positive_integer(document["before"]),
        optional_limit(document["limit"]),
        optional_text(document["cursor"], 1_024),
        optional_slack_id(document["context_channel_id"]),
        optional_enum(document["sort"], ~w(score timestamp)),
        optional_enum(document["sort_dir"], ~w(asc desc))
      ])

    if valid, do: :ok, else: {:error, {:invalid_slack_api_request, :search}}
  end

  defp search_document(_document), do: {:error, {:invalid_slack_api_request, :search}}

  defp search_response(%{"results" => %{} = _results} = body) do
    result = Map.drop(body, ["ok"])

    if Fields.bounded_result(result, :search) == :ok and search_cursor?(result["next_cursor"]),
      do: {:ok, result},
      else: {:error, {:slack_protocol_error, :search}}
  end

  defp search_response(_body), do: {:error, {:slack_protocol_error, :search}}

  defp optional_enum(nil, _allowed), do: true
  defp optional_enum(value, allowed), do: value in allowed

  defp optional_enum_list(nil, _allowed), do: true

  defp optional_enum_list(values, allowed) when is_list(values) and length(values) in 1..8,
    do: Enum.uniq(values) == values and Enum.all?(values, &(&1 in allowed))

  defp optional_enum_list(_values, _allowed), do: false

  defp optional_boolean(nil), do: true
  defp optional_boolean(value), do: is_boolean(value)

  defp optional_positive_integer(nil), do: true
  defp optional_positive_integer(value), do: is_integer(value) and value > 0

  defp optional_limit(nil), do: true
  defp optional_limit(value), do: is_integer(value) and value in 1..20

  defp optional_text(nil, _maximum), do: true
  defp optional_text(value, maximum), do: Fields.bounded_text(value, maximum) == :ok

  defp optional_slack_id(nil), do: true
  defp optional_slack_id(value), do: Fields.slack_id(value) == :ok

  defp search_cursor?(nil), do: true

  defp search_cursor?(value),
    do: is_binary(value) and String.valid?(value) and byte_size(value) <= 4_096

  # --- history --------------------------------------------------------------

  @impl true
  def read_messages(client, channel_ref, thread_ref, document) do
    with :ok <- Fields.slack_id(channel_ref),
         :ok <- Fields.optional_message_timestamp(thread_ref),
         {:ok, parameters} <- Conversations.history_document(document),
         path <- source_history_path(channel_ref, thread_ref, parameters),
         {:ok, response} <- Transport.request(client, :get, path, nil),
         {:ok, body} <- Transport.response(response),
         {:ok, messages, cursor} <- history(body),
         result <-
           Map.merge(
             %{"cursor" => cursor, "messages" => messages},
             Map.take(body, ["has_more", "is_limited"])
           ),
         :ok <- Fields.bounded_result(result, :history) do
      {:ok, result}
    end
  end

  defp source_history_path(channel_ref, nil, parameters),
    do: "/conversations.history?" <> URI.encode_query([{"channel", channel_ref} | parameters])

  defp source_history_path(channel_ref, thread_ref, parameters),
    do:
      "/conversations.replies?" <>
        URI.encode_query([{"channel", channel_ref}, {"ts", thread_ref} | parameters])

  # The walk a retry makes through a channel or thread to find its own
  # delivery: metadata comes along so the delivery ref is on every message.
  defp history_path(channel, nil, cursor) do
    Pagination.query(
      "/conversations.history",
      [{"channel", channel}, {"limit", @page_size}, {"include_all_metadata", true}],
      cursor
    )
  end

  defp history_path(channel, thread, cursor) do
    Pagination.query(
      "/conversations.replies",
      [
        {"channel", channel},
        {"ts", thread},
        {"limit", @page_size},
        {"include_all_metadata", true}
      ],
      cursor
    )
  end

  defp history(%{"messages" => messages} = body) when is_list(messages) do
    case Pagination.next_cursor(body) do
      {:ok, cursor} -> {:ok, messages, cursor}
      {:error, _reason} -> {:error, {:slack_protocol_error, :history}}
    end
  end

  defp history(_body), do: {:error, {:slack_protocol_error, :history}}

  defp find_delivery(messages, delivery_ref) do
    Enum.reduce_while(messages, :not_found, fn
      %{
        "metadata" => %{
          "event_payload" => %{"id" => ^delivery_ref},
          "event_type" => "ryker_delivery"
        },
        "ts" => message_ref
      },
      :not_found
      when is_binary(message_ref) and message_ref != "" ->
        {:halt, {:ok, message_ref}}

      %{}, :not_found ->
        {:cont, :not_found}

      _invalid, :not_found ->
        {:halt, {:error, {:slack_protocol_error, :message}}}
    end)
  end

  # --- conversations --------------------------------------------------------

  @impl true
  def list_conversations(client, document) do
    with {:ok, parameters} <- Conversations.list_document(document),
         path <- "/users.conversations?" <> URI.encode_query(parameters),
         {:ok, response} <- Transport.request(client, :get, path, nil),
         {:ok, body} <- Transport.response(response),
         {:ok, channels, cursor} <- Conversations.listing_page(body) do
      {:ok, %{"conversations" => channels, "cursor" => cursor}}
    end
  end

  @impl true
  def conversation_info(client, channel_ref) do
    with :ok <- Fields.slack_id(channel_ref),
         {:ok, response} <- Transport.request(client, :get, info_path(channel_ref), nil),
         {:ok, %{"channel" => %{"id" => ^channel_ref} = channel}} <- Transport.response(response),
         :ok <- Fields.bounded_result(channel, :conversation) do
      {:ok, channel}
    else
      {:ok, _invalid} -> {:error, {:slack_protocol_error, :conversation}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def conversation_state(client, channel_ref) do
    with :ok <- Fields.slack_id(channel_ref),
         {:ok, response} <- Transport.request(client, :get, info_path(channel_ref), nil) do
      conversation_state_response(response, channel_ref)
    end
  end

  defp conversation_state_response(
         %{body: %{"error" => "channel_not_found", "ok" => false}, status: 200},
         _channel_ref
       ),
       do: :not_found

  defp conversation_state_response(response, channel_ref) do
    with {:ok, body} <- Transport.response(response),
         do: Conversations.conversation_state(body, channel_ref)
  end

  defp info_path(channel_ref),
    do:
      "/conversations.info?" <> URI.encode_query(channel: channel_ref, include_num_members: false)

  @impl true
  def list_bookmarks(client, channel_ref) do
    with :ok <- Fields.slack_id(channel_ref),
         {:ok, response} <-
           Transport.request(client, :post, "/bookmarks.list", %{"channel_id" => channel_ref}),
         {:ok, body} <- Transport.response(response) do
      Conversations.bookmarks(body, channel_ref)
    end
  end

  @impl true
  def joined_conversations(client) do
    parameters = [
      {"exclude_archived", true},
      {"limit", @conversation_page_size},
      {"types", "public_channel,private_channel"}
    ]

    with {:ok, channels} <-
           Pagination.collect(
             client,
             &Pagination.query("/users.conversations", parameters, &1),
             &Conversations.joined_page/1,
             @conversation_page_size
           ) do
      {:ok, channels |> Enum.uniq_by(& &1.channel_ref) |> Enum.sort_by(& &1.channel_ref)}
    end
  end

  @impl true
  def shared_conversations(client, user_ref, workspace_ref) do
    parameters = [
      {"exclude_archived", true},
      {"limit", @conversation_page_size},
      {"team_id", workspace_ref},
      {"types", "public_channel,private_channel,mpim,im"},
      {"user", user_ref}
    ]

    with :ok <- Fields.slack_id(user_ref),
         :ok <- Fields.slack_id(workspace_ref),
         {:ok, channel_refs} <-
           Pagination.collect(
             client,
             &Pagination.query("/users.conversations", parameters, &1),
             &Conversations.shared_page/1,
             @conversation_page_size
           ) do
      {:ok, MapSet.new(channel_refs)}
    end
  end

  @impl true
  def ensure_conversation(client, workspace_ref, name, private, creator_ref, requested_at) do
    with :ok <- Fields.slack_id(workspace_ref),
         :ok <- Fields.conversation_name(name),
         true <- is_boolean(private),
         :ok <- Fields.slack_id(creator_ref),
         :ok <- Fields.utc_datetime(requested_at) do
      case find_conversation(client, name, private, creator_ref, requested_at) do
        {:ok, channel_ref} ->
          {:ok, channel_ref}

        :not_found ->
          create_conversation(
            client,
            workspace_ref,
            name,
            private,
            creator_ref,
            requested_at
          )

        {:error, _reason} = error ->
          error
      end
    else
      false -> {:error, {:invalid_slack_api_request, :private}}
      {:error, _reason} = error -> error
    end
  end

  defp find_conversation(client, name, private, creator_ref, requested_at) do
    parameters = [
      {"exclude_archived", false},
      {"limit", @conversation_page_size},
      {"types", "public_channel,private_channel"}
    ]

    Pagination.find(
      client,
      &Pagination.query("/conversations.list", parameters, &1),
      &Conversations.search_page/1,
      &Conversations.matching_conversation(&1, name, private, creator_ref, requested_at),
      @conversation_page_size
    )
  end

  # A create whose reply was lost, or that Slack refused because the name is
  # taken, is reconciled by finding the channel this exact request created.
  defp create_conversation(client, workspace_ref, name, private, creator_ref, requested_at) do
    document = %{"is_private" => private, "name" => name, "team_id" => workspace_ref}

    case Transport.request(client, :post, "/conversations.create", document) do
      {:ok, %{body: %{"error" => "name_taken", "ok" => false}, status: 200}} ->
        reconcile_created_conversation(client, name, private, creator_ref, requested_at)

      {:ok, response} ->
        with {:ok, body} <- Transport.response(response) do
          Conversations.created_conversation(body, name, private, creator_ref)
        end

      {:error, _reason} ->
        reconcile_created_conversation(client, name, private, creator_ref, requested_at)
    end
  end

  defp reconcile_created_conversation(client, name, private, creator_ref, requested_at) do
    case find_conversation(client, name, private, creator_ref, requested_at) do
      {:ok, channel_ref} -> {:ok, channel_ref}
      :not_found -> {:error, {:slack_reconciliation_pending, :conversation}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def invite_users(_client, _channel_ref, []), do: :ok

  def invite_users(client, channel_ref, users) do
    with :ok <- Fields.slack_id(channel_ref),
         :ok <- Fields.unique_slack_ids(users) do
      Enum.reduce_while(users, :ok, fn user_ref, :ok ->
        invite_user(client, channel_ref, user_ref)
      end)
    end
  end

  defp invite_user(client, channel_ref, user_ref) do
    document = %{"channel" => channel_ref, "users" => user_ref}

    case invitation_response(Transport.request(client, :post, "/conversations.invite", document)) do
      :ok -> {:cont, :ok}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  # Someone already in the room, or Ryker itself, is invited by definition.
  defp invitation_response({:ok, %{body: %{"error" => error, "ok" => false}, status: 200}})
       when error in ["already_in_channel", "cant_invite_self"],
       do: :ok

  defp invitation_response({:ok, response}),
    do: response |> Transport.response() |> Transport.success()

  defp invitation_response({:error, _reason} = error), do: error

  @impl true
  def set_topic(client, channel_ref, topic) do
    with :ok <- Fields.slack_id(channel_ref),
         :ok <- Fields.bounded_text(topic, 250),
         {:ok, response} <-
           Transport.request(client, :post, "/conversations.setTopic", %{
             "channel" => channel_ref,
             "topic" => topic
           }),
         {:ok, _body} <- Transport.response(response) do
      :ok
    end
  end

  @impl true
  def pin_message(client, channel_ref, message_ref) do
    with :ok <- Fields.slack_id(channel_ref),
         :ok <- Fields.text(message_ref) do
      document = %{"channel" => channel_ref, "timestamp" => message_ref}

      case Transport.request(client, :post, "/pins.add", document) do
        {:ok, %{body: %{"error" => "already_pinned", "ok" => false}, status: 200}} -> :ok
        {:ok, response} -> response |> Transport.response() |> Transport.success()
        {:error, _reason} = error -> error
      end
    end
  end

  # --- directory ------------------------------------------------------------

  @doc "Read a display name only. These names never participate in authorization."
  @spec directory_name(t(), String.t(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def directory_name(client, workspace, ref) do
    with :ok <- Fields.slack_id(workspace), :ok <- Fields.slack_id(ref) do
      directory_name_request(client, workspace, ref)
    end
  end

  defp directory_name_request(client, workspace, "T" <> _ = workspace) do
    # auth.test needs no additional scope and returns the token's bound team.
    with {:ok, response} <- Transport.request(client, :post, "/auth.test", %{}),
         {:ok, %{"team_id" => ^workspace, "team" => name}} <- Transport.response(response) do
      {:ok, name}
    else
      {:error, _} = error -> error
      _ -> {:error, :directory_name_unavailable}
    end
  end

  defp directory_name_request(client, workspace, <<prefix, _::binary>> = ref)
       when prefix in [?U, ?W] do
    with {:ok, response} <- Transport.request(client, :get, user_path(ref), nil),
         {:ok, %{"user" => %{"id" => ^ref, "team_id" => ^workspace} = user}} <-
           Transport.response(response) do
      profile = user["profile"] || %{}

      {:ok,
       Enum.find(
         [profile["display_name"], profile["real_name"], user["name"]],
         &(is_binary(&1) and String.trim(&1) != "")
       )}
    else
      {:error, _} = error -> error
      _ -> {:error, :directory_name_unavailable}
    end
  end

  defp directory_name_request(client, _workspace, <<prefix, _::binary>> = ref)
       when prefix in [?C, ?G, ?D] do
    with {:ok, channel} <- conversation_info(client, ref),
         do: {:ok, channel["name"] || "Direct message"}
  end

  defp directory_name_request(_, _, _), do: {:error, :directory_name_unavailable}

  @impl Ryker.Slack.MemberDirectory
  def user_allowed(client, user_ref, workspace_ref) do
    with :ok <- Fields.slack_id(user_ref),
         :ok <- Fields.slack_id(workspace_ref),
         {:ok, response} <- Transport.request(client, :get, user_path(user_ref), nil),
         {:ok, body} <- Transport.response(response) do
      Conversations.allowed_user(body, user_ref, workspace_ref)
    end
  end

  defp user_path(user_ref), do: "/users.info?" <> URI.encode_query(user: user_ref)

  @impl Ryker.Slack.MemberDirectory
  def user_group_members(client, user_group_ref, workspace_ref) do
    with :ok <- Fields.slack_id(user_group_ref),
         :ok <- Fields.slack_id(workspace_ref),
         {:ok, response} <-
           Transport.request(
             client,
             :get,
             "/usergroups.users.list?" <> URI.encode_query(usergroup: user_group_ref),
             nil
           ),
         {:ok, body} <- Transport.response(response) do
      Conversations.group_users(body)
    end
  end

  # --- views ----------------------------------------------------------------

  @impl true
  def publish_home(client, user_ref, view) do
    with :ok <- Fields.slack_id(user_ref),
         :ok <- Fields.home_view(view),
         {:ok, response} <-
           Transport.request(client, :post, "/views.publish", %{
             "user_id" => user_ref,
             "view" => view
           }),
         {:ok, body} <- Transport.response(response),
         %{"view" => %{"type" => "home"}} <- body do
      :ok
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, {:slack_protocol_error, :home_view}}
    end
  end

  @impl true
  def open_view(client, trigger_ref, view) do
    with :ok <- Fields.bounded_text(trigger_ref, 256),
         :ok <- Fields.modal_view(view),
         {:ok, response} <-
           Transport.request(client, :post, "/views.open", %{
             "trigger_id" => trigger_ref,
             "view" => view
           }),
         {:ok, body} <- Transport.response(response),
         %{"view" => %{"type" => "modal"}} <- body do
      :ok
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, {:slack_protocol_error, :modal_view}}
    end
  end

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

  defp prepare_uploader(
         %__MODULE__{http: %JSONClient{} = http, upload_http: nil, uploader: nil} = client
       ) do
    case UploadClient.new(
           base_origin: "https://files.slack.com",
           finch: http.finch,
           receive_timeout: http.receive_timeout
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

  defp upload_configured(%__MODULE__{upload_http: nil}),
    do: {:error, {:slack_upload_unavailable, :transport}}

  defp upload_configured(%__MODULE__{}), do: :ok
end
