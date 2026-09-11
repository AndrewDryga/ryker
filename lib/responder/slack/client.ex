defmodule Responder.Slack.Client do
  @moduledoc """
  Bounded Slack Web API adapter for message and emoji delivery.

  Posted messages carry host-owned metadata. Retries walk the exact channel or
  thread until that metadata is found, so a lost HTTP response cannot duplicate
  a visible reply.
  """

  @behaviour Responder.Slack.API
  @behaviour Responder.Slack.MemberDirectory

  alias Responder.CanonicalJSON
  alias Responder.Delivery.JSONClient
  alias Responder.Slack.{Renderer, UploadClient}

  @required_fields [:http, :requester]
  @fields @required_fields ++ [:upload_http, :uploader]
  @maximum_pages 100
  @page_size 100
  @conversation_page_size 200
  @maximum_conversation_name_bytes 80
  @maximum_bookmarks 100
  @maximum_files 5
  @maximum_file_bytes 8 * 1_024 * 1_024
  @maximum_search_response_bytes 768 * 1_024
  @media_types ~w(image/gif image/jpeg image/png image/webp)

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

  @impl true
  def find_files(client, channel, thread, filenames) do
    with :ok <- text(channel),
         :ok <- optional_text(thread),
         :ok <- filenames(filenames) do
      find_files_page(client, channel, thread, filenames)
    end
  end

  @impl true
  def upload_files(client, channel, thread, body, delivery_ref, files) do
    with :ok <- text(channel),
         :ok <- optional_text(thread),
         {:ok, rendered} <- render(body),
         :ok <- text(delivery_ref),
         :ok <- upload_files(files),
         :ok <- upload_configured(client),
         {:ok, uploaded} <- upload_external_files(client, files),
         document <- completion_document(channel, thread, rendered, uploaded),
         {:ok, response} <- request(client, :post, "/files.completeUploadExternal", document),
         {:ok, _body} <- slack_response(response) do
      case find_files(client, channel, thread, Enum.map(files, & &1.filename)) do
        {:ok, message_ref} -> {:ok, message_ref}
        :not_found -> {:error, {:slack_reconciliation_pending, :file_share}}
        {:error, _reason} = error -> error
      end
    end
  end

  @impl true
  def find_message(client, channel, thread, delivery_ref) do
    with :ok <- text(channel),
         :ok <- optional_text(thread),
         :ok <- text(delivery_ref) do
      find_message_page(client, channel, thread, delivery_ref)
    end
  end

  @doc "Reconciles a specimen only within its durable creation window, allowing five minutes of clock skew."
  def find_card_specimen(client, channel, delivery_ref, %DateTime{} = created_at) do
    with :ok <- text(channel), :ok <- text(delivery_ref) do
      oldest = "#{max(DateTime.to_unix(created_at) - 300, 0)}.000000"
      find_message_page(client, channel, nil, delivery_ref, nil, 1, oldest)
    end
  end

  @impl true
  def post_message(client, channel, thread, body, delivery_ref) do
    with {:ok, rendered} <- render(body) do
      post_rendered_message(client, channel, thread, rendered, delivery_ref)
    end
  end

  @doc "Posts frozen, isolated Card Lab Block Kit; never accepts model-authored controls."
  @spec post_card_specimen(t(), String.t(), String.t() | nil, map(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def post_card_specimen(client, channel, thread, rendered, delivery_ref) do
    with :ok <- specimen_payload(rendered) do
      post_rendered_message(client, channel, thread, rendered, delivery_ref)
    end
  end

  defp post_rendered_message(client, channel, thread, rendered, delivery_ref) do
    with :ok <- text(channel),
         :ok <- optional_text(thread),
         :ok <- text(delivery_ref),
         document <- message_document(channel, thread, rendered, delivery_ref),
         {:ok, response} <- request(client, :post, "/chat.postMessage", document),
         {:ok, response_body} <- slack_response(response) do
      case response_body do
        %{"ts" => message_ref} when is_binary(message_ref) and message_ref != "" ->
          {:ok, message_ref}

        _invalid ->
          {:error, {:slack_protocol_error, :message}}
      end
    end
  end

  @impl true
  def update_message(client, channel, message_ref, body, delivery_ref) do
    with {:ok, rendered} <- render(body) do
      update_rendered_message(client, channel, message_ref, rendered, delivery_ref)
    end
  end

  @doc "Updates one existing Card Lab specimen without changing its delivery identity."
  @spec update_card_specimen(t(), String.t(), String.t(), map(), String.t()) ::
          :ok | {:error, term()}
  def update_card_specimen(client, channel, message_ref, rendered, delivery_ref) do
    with :ok <- specimen_payload(rendered) do
      update_rendered_message(client, channel, message_ref, rendered, delivery_ref)
    end
  end

  defp update_rendered_message(client, channel, message_ref, rendered, delivery_ref) do
    with :ok <- text(channel),
         :ok <- text(message_ref),
         :ok <- text(delivery_ref),
         document <-
           channel
           |> message_document(rendered, delivery_ref)
           |> Map.put("ts", message_ref),
         {:ok, response} <- request(client, :post, "/chat.update", document),
         {:ok, response_body} <- slack_response(response),
         true <- response_body["ts"] == message_ref and response_body["channel"] == channel do
      :ok
    else
      false -> {:error, {:slack_protocol_error, :message_update}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def set_thread_status(client, channel, thread_ref, status) do
    with :ok <- slack_id(channel),
         :ok <- message_timestamp(thread_ref),
         :ok <- thread_status(status),
         {:ok, response} <-
           request(client, :post, "/assistant.threads.setStatus", %{
             "channel_id" => channel,
             "status" => status,
             "thread_ts" => thread_ref
           }),
         {:ok, _body} <- slack_response(response) do
      :ok
    end
  end

  @impl true
  def publish_home(client, user_ref, view) do
    with :ok <- slack_id(user_ref),
         :ok <- home_view(view),
         {:ok, response} <-
           request(client, :post, "/views.publish", %{"user_id" => user_ref, "view" => view}),
         {:ok, body} <- slack_response(response),
         %{"view" => %{"type" => "home"}} <- body do
      :ok
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, {:slack_protocol_error, :home_view}}
    end
  end

  @impl true
  def open_view(client, trigger_ref, view) do
    with :ok <- bounded_text(trigger_ref, 256),
         :ok <- modal_view(view),
         {:ok, response} <-
           request(client, :post, "/views.open", %{"trigger_id" => trigger_ref, "view" => view}),
         {:ok, body} <- slack_response(response),
         %{"view" => %{"type" => "modal"}} <- body do
      :ok
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, {:slack_protocol_error, :modal_view}}
    end
  end

  @impl true
  def add_reaction(client, channel, message_ref, emoji_name) do
    with :ok <- text(channel),
         :ok <- text(message_ref),
         :ok <- text(emoji_name),
         {:ok, response} <-
           request(client, :post, "/reactions.add", %{
             "channel" => channel,
             "name" => emoji_name,
             "timestamp" => message_ref
           }) do
      reaction_response(response)
    end
  end

  @impl true
  def remove_reaction(client, channel, message_ref, emoji_name) do
    with :ok <- text(channel),
         :ok <- text(message_ref),
         :ok <- text(emoji_name),
         {:ok, response} <-
           request(client, :post, "/reactions.remove", %{
             "channel" => channel,
             "name" => emoji_name,
             "timestamp" => message_ref
           }) do
      removal_response(response)
    end
  end

  @impl true
  def search_context(client, action_token, document) do
    with :ok <- action_token(action_token),
         :ok <- search_document(document),
         {:ok, response} <-
           request(
             client,
             :post,
             "/assistant.search.context",
             Map.put(document, "action_token", action_token)
           ),
         {:ok, body} <- slack_response(response),
         {:ok, result} <- search_response(body) do
      {:ok, result}
    else
      {:error, {:invalid_slack_api_request, _field}} = error -> error
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def list_conversations(client, document) do
    with {:ok, parameters} <- conversation_list_document(document),
         path <- "/users.conversations?" <> URI.encode_query(parameters),
         {:ok, response} <- request(client, :get, path, nil),
         {:ok, body} <- slack_response(response),
         {:ok, channels, cursor} <- conversation_listing_page(body) do
      {:ok, %{"conversations" => channels, "cursor" => cursor}}
    else
      {:error, {:invalid_slack_api_request, _field}} = error -> error
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def conversation_info(client, channel_ref) do
    with :ok <- slack_id(channel_ref),
         path <-
           "/conversations.info?" <>
             URI.encode_query(channel: channel_ref, include_num_members: false),
         {:ok, response} <- request(client, :get, path, nil),
         {:ok, %{"channel" => %{"id" => ^channel_ref} = channel}} <- slack_response(response),
         :ok <- bounded_slack_result(channel, :conversation) do
      {:ok, channel}
    else
      {:ok, _invalid} -> {:error, {:slack_protocol_error, :conversation}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def list_bookmarks(client, channel_ref) do
    with :ok <- slack_id(channel_ref),
         {:ok, response} <-
           request(client, :post, "/bookmarks.list", %{"channel_id" => channel_ref}),
         {:ok, body} <- slack_response(response) do
      bookmarks(body, channel_ref)
    end
  end

  @doc "Read a display name only. These names never participate in authorization."
  def directory_name(client, workspace, ref) do
    with :ok <- slack_id(workspace), :ok <- slack_id(ref) do
      directory_name_request(client, workspace, ref)
    end
  end

  defp directory_name_request(client, workspace, "T" <> _ = workspace) do
    # auth.test needs no additional scope and returns the token's bound team.
    with {:ok, response} <- request(client, :post, "/auth.test", %{}),
         {:ok, %{"team_id" => ^workspace, "team" => name}} <- slack_response(response) do
      {:ok, name}
    else
      {:error, _} = error -> error
      _ -> {:error, :directory_name_unavailable}
    end
  end

  defp directory_name_request(client, workspace, <<prefix, _::binary>> = ref)
       when prefix in [?U, ?W] do
    with {:ok, response} <-
           request(client, :get, "/users.info?" <> URI.encode_query(user: ref), nil),
         {:ok, %{"user" => %{"id" => ^ref, "team_id" => ^workspace} = user}} <-
           slack_response(response) do
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

  @impl true
  def file_info(client, file_ref) do
    with :ok <- slack_id(file_ref),
         path <- "/files.info?" <> URI.encode_query(file: file_ref),
         {:ok, response} <- request(client, :get, path, nil),
         {:ok, %{"file" => %{"id" => ^file_ref} = file}} <- slack_response(response),
         :ok <- bounded_slack_result(file, :file) do
      {:ok, file}
    else
      {:ok, _invalid} -> {:error, {:slack_protocol_error, :file}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def read_messages(client, channel_ref, thread_ref, document) do
    with :ok <- slack_id(channel_ref),
         :ok <- optional_message_ref(thread_ref),
         {:ok, parameters} <- history_document(document),
         path <- source_history_path(channel_ref, thread_ref, parameters),
         {:ok, response} <- request(client, :get, path, nil),
         {:ok, body} <- slack_response(response),
         {:ok, messages, cursor} <- history(body),
         result <-
           Map.merge(
             %{"cursor" => cursor, "messages" => messages},
             Map.take(body, ["has_more", "is_limited"])
           ),
         :ok <- bounded_slack_result(result, :history) do
      {:ok, result}
    else
      {:error, {:invalid_slack_api_request, _field}} = error -> error
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def joined_conversations(client), do: joined_conversations_page(client)

  @impl true
  def shared_conversations(client, user_ref, workspace_ref) do
    with :ok <- slack_id(user_ref),
         :ok <- slack_id(workspace_ref) do
      shared_conversations_page(client, user_ref, workspace_ref)
    end
  end

  @impl true
  def ensure_conversation(client, workspace_ref, name, private, creator_ref, requested_at) do
    with :ok <- slack_id(workspace_ref),
         :ok <- conversation_name(name),
         true <- is_boolean(private),
         :ok <- slack_id(creator_ref),
         :ok <- utc_datetime(requested_at) do
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

  @impl true
  def invite_users(_client, _channel_ref, []), do: :ok

  def invite_users(client, channel_ref, users) do
    with :ok <- slack_id(channel_ref),
         :ok <- unique_slack_ids(users) do
      Enum.reduce_while(users, :ok, fn user_ref, :ok ->
        invite_user(client, channel_ref, user_ref)
      end)
    end
  end

  defp invite_user(client, channel_ref, user_ref) do
    response =
      request(client, :post, "/conversations.invite", %{
        "channel" => channel_ref,
        "users" => user_ref
      })

    case invitation_response(response) do
      :ok -> {:cont, :ok}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  @impl true
  def set_topic(client, channel_ref, topic) do
    with :ok <- slack_id(channel_ref),
         :ok <- bounded_text(topic, 250),
         {:ok, response} <-
           request(client, :post, "/conversations.setTopic", %{
             "channel" => channel_ref,
             "topic" => topic
           }),
         {:ok, _body} <- slack_response(response) do
      :ok
    end
  end

  @impl true
  def pin_message(client, channel_ref, message_ref) do
    with :ok <- slack_id(channel_ref),
         :ok <- text(message_ref) do
      case request(client, :post, "/pins.add", %{
             "channel" => channel_ref,
             "timestamp" => message_ref
           }) do
        {:ok, %{body: %{"error" => "already_pinned", "ok" => false}, status: 200}} -> :ok
        {:ok, response} -> response |> slack_response() |> success()
        {:error, _reason} = error -> error
      end
    end
  end

  @impl true
  def conversation_state(client, channel_ref) do
    with :ok <- slack_id(channel_ref) do
      path =
        "/conversations.info?" <>
          URI.encode_query(channel: channel_ref, include_num_members: false)

      case request(client, :get, path, nil) do
        {:ok, %{body: %{"error" => "channel_not_found", "ok" => false}, status: 200}} ->
          :not_found

        {:ok, response} ->
          conversation_state_response(response, channel_ref)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp conversation_state_response(response, channel_ref) do
    with {:ok, body} <- slack_response(response) do
      conversation_state_body(body, channel_ref)
    end
  end

  @impl Responder.Slack.MemberDirectory
  def user_allowed(client, user_ref, workspace_ref) do
    with :ok <- slack_id(user_ref),
         :ok <- slack_id(workspace_ref),
         {:ok, response} <-
           request(client, :get, "/users.info?" <> URI.encode_query(user: user_ref), nil),
         {:ok, body} <- slack_response(response) do
      allowed_user(body, user_ref, workspace_ref)
    end
  end

  @impl Responder.Slack.MemberDirectory
  def user_group_members(client, user_group_ref, workspace_ref) do
    with :ok <- slack_id(user_group_ref),
         :ok <- slack_id(workspace_ref),
         {:ok, response} <-
           request(
             client,
             :get,
             "/usergroups.users.list?" <> URI.encode_query(usergroup: user_group_ref),
             nil
           ),
         {:ok, body} <- slack_response(response) do
      group_users(body)
    end
  end

  defp reaction_response(%{
         body: %{"error" => "already_reacted", "ok" => false},
         status: 200
       }),
       do: :ok

  defp reaction_response(response) do
    case slack_response(response) do
      {:ok, _body} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp removal_response(%{
         body: %{"error" => "no_reaction", "ok" => false},
         status: 200
       }),
       do: :ok

  defp removal_response(response), do: reaction_response(response)

  defp search_document(%{"query" => query} = document) do
    allowed =
      ~w(after before channel_types content_types context_channel_id cursor include_bots include_context_messages limit query sort sort_dir)

    valid =
      Enum.all?([
        Map.keys(document) -- allowed == [],
        bounded_text(query, 2_048) == :ok,
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

    if CanonicalJSON.validate(result, max_bytes: @maximum_search_response_bytes) == :ok and
         search_cursor?(result["next_cursor"]),
       do: {:ok, result},
       else: {:error, {:slack_protocol_error, :search}}
  end

  defp search_response(_body), do: {:error, {:slack_protocol_error, :search}}

  defp bounded_slack_result(document, field) do
    if CanonicalJSON.validate(document, max_bytes: @maximum_search_response_bytes) == :ok,
      do: :ok,
      else: {:error, {:slack_protocol_error, field}}
  end

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
  defp optional_text(value, maximum), do: bounded_text(value, maximum) == :ok

  defp optional_slack_id(nil), do: true
  defp optional_slack_id(value), do: slack_id(value) == :ok

  defp search_cursor?(nil), do: true

  defp search_cursor?(value),
    do: is_binary(value) and String.valid?(value) and byte_size(value) <= 4_096

  defp action_token(value) do
    if bounded_text(value, 4_096) == :ok and :binary.match(value, <<0>>) == :nomatch,
      do: :ok,
      else: {:error, {:invalid_slack_api_request, :action_token}}
  end

  defp find_message_page(
         client,
         channel,
         thread,
         delivery_ref,
         cursor \\ nil,
         page \\ 1,
         oldest \\ nil
       ) do
    path = history_path(channel, thread, cursor, oldest)

    with {:ok, response} <- request(client, :get, path, nil),
         {:ok, body} <- slack_response(response),
         {:ok, messages, next_cursor} <- history(body) do
      case find_delivery(messages, delivery_ref) do
        {:ok, message_ref} ->
          {:ok, message_ref}

        :not_found when next_cursor == "" ->
          :not_found

        :not_found when page < @maximum_pages ->
          find_message_page(client, channel, thread, delivery_ref, next_cursor, page + 1, oldest)

        :not_found ->
          {:error, {:slack_reconciliation_incomplete, @maximum_pages * @page_size}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp joined_conversations_page(client, cursor \\ nil, page \\ 1, channels \\ []) do
    parameters = [
      {"exclude_archived", true},
      {"limit", @conversation_page_size},
      {"types", "public_channel,private_channel"}
    ]

    path = "/users.conversations?" <> query(parameters, cursor)

    with {:ok, response} <- request(client, :get, path, nil),
         {:ok, body} <- slack_response(response),
         {:ok, page_channels, next_cursor} <- conversation_page(body) do
      channels = channels ++ page_channels

      cond do
        next_cursor == "" ->
          {:ok, channels |> Enum.uniq_by(& &1.channel_ref) |> Enum.sort_by(& &1.channel_ref)}

        page < @maximum_pages ->
          joined_conversations_page(client, next_cursor, page + 1, channels)

        true ->
          {:error, {:slack_reconciliation_incomplete, @maximum_pages * @conversation_page_size}}
      end
    end
  end

  defp shared_conversations_page(
         client,
         user_ref,
         workspace_ref,
         cursor \\ nil,
         page \\ 1,
         channel_refs \\ []
       ) do
    parameters = [
      {"exclude_archived", true},
      {"limit", @conversation_page_size},
      {"team_id", workspace_ref},
      {"types", "public_channel,private_channel,mpim,im"},
      {"user", user_ref}
    ]

    path = "/users.conversations?" <> query(parameters, cursor)

    with {:ok, response} <- request(client, :get, path, nil),
         {:ok, body} <- slack_response(response),
         {:ok, page_refs, next_cursor} <- shared_conversation_page(body) do
      channel_refs = channel_refs ++ page_refs

      cond do
        next_cursor == "" ->
          {:ok, MapSet.new(channel_refs)}

        page < @maximum_pages ->
          shared_conversations_page(
            client,
            user_ref,
            workspace_ref,
            next_cursor,
            page + 1,
            channel_refs
          )

        true ->
          {:error, {:slack_reconciliation_incomplete, @maximum_pages * @conversation_page_size}}
      end
    end
  end

  defp find_conversation(
         client,
         name,
         private,
         creator_ref,
         requested_at,
         cursor \\ nil,
         page \\ 1
       ) do
    parameters = [
      {"exclude_archived", false},
      {"limit", @conversation_page_size},
      {"types", "public_channel,private_channel"}
    ]

    path = "/conversations.list?" <> query(parameters, cursor)

    with {:ok, response} <- request(client, :get, path, nil),
         {:ok, body} <- slack_response(response),
         {:ok, channels, next_cursor} <- conversation_search_page(body) do
      case matching_conversation(channels, name, private, creator_ref, requested_at) do
        {:ok, channel_ref} ->
          {:ok, channel_ref}

        :not_found when next_cursor == "" ->
          :not_found

        :not_found when page < @maximum_pages ->
          find_conversation(
            client,
            name,
            private,
            creator_ref,
            requested_at,
            next_cursor,
            page + 1
          )

        :not_found ->
          {:error, {:slack_reconciliation_incomplete, @maximum_pages * @conversation_page_size}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp create_conversation(client, workspace_ref, name, private, creator_ref, requested_at) do
    document = %{"is_private" => private, "name" => name, "team_id" => workspace_ref}

    case request(client, :post, "/conversations.create", document) do
      {:ok, %{body: %{"error" => "name_taken", "ok" => false}, status: 200}} ->
        reconcile_created_conversation(client, name, private, creator_ref, requested_at)

      {:ok, response} ->
        with {:ok, body} <- slack_response(response) do
          created_conversation(body, name, private, creator_ref)
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

  defp conversation_search_page(%{"channels" => channels} = body) when is_list(channels) do
    cursor = get_in(body, ["response_metadata", "next_cursor"]) || ""

    if is_binary(cursor),
      do: {:ok, channels, cursor},
      else: {:error, {:slack_protocol_error, :conversations}}
  end

  defp conversation_search_page(_body), do: {:error, {:slack_protocol_error, :conversations}}

  defp matching_conversation(channels, name, private, creator_ref, requested_at) do
    earliest = DateTime.add(requested_at, -300, :second) |> DateTime.to_unix()
    latest = DateTime.add(requested_at, 3_600, :second) |> DateTime.to_unix()

    Enum.reduce_while(channels, :not_found, fn
      %{
        "created" => created,
        "creator" => ^creator_ref,
        "id" => channel_ref,
        "is_private" => ^private,
        "name" => ^name
      },
      :not_found
      when is_integer(created) and created >= earliest and created <= latest ->
        if slack_id(channel_ref) == :ok,
          do: {:halt, {:ok, channel_ref}},
          else: {:halt, {:error, {:slack_protocol_error, :conversation}}}

      %{}, :not_found ->
        {:cont, :not_found}

      _invalid, :not_found ->
        {:halt, {:error, {:slack_protocol_error, :conversation}}}
    end)
  end

  defp created_conversation(
         %{
           "channel" => %{
             "creator" => creator_ref,
             "id" => channel_ref,
             "is_private" => private,
             "name" => name
           }
         },
         name,
         private,
         creator_ref
       ) do
    case slack_id(channel_ref) do
      :ok -> {:ok, channel_ref}
      {:error, _reason} -> {:error, {:slack_protocol_error, :conversation}}
    end
  end

  defp created_conversation(_body, _name, _private, _creator_ref),
    do: {:error, {:slack_protocol_error, :conversation}}

  defp invitation_response({:ok, %{body: %{"error" => error, "ok" => false}, status: 200}})
       when error in ["already_in_channel", "cant_invite_self"],
       do: :ok

  defp invitation_response({:ok, response}), do: response |> slack_response() |> success()
  defp invitation_response({:error, _reason} = error), do: error

  defp success({:ok, _body}), do: :ok
  defp success({:error, _reason} = error), do: error

  defp conversation_state_body(
         %{"channel" => %{"id" => channel_ref, "is_archived" => archived}},
         channel_ref
       )
       when is_boolean(archived) do
    case slack_id(channel_ref) do
      :ok -> {:ok, if(archived, do: :archived, else: :active)}
      {:error, _reason} -> {:error, {:slack_protocol_error, :conversation}}
    end
  end

  defp conversation_state_body(_body, _channel_ref),
    do: {:error, {:slack_protocol_error, :conversation}}

  defp conversation_page(%{"channels" => channels} = body) when is_list(channels) do
    cursor = get_in(body, ["response_metadata", "next_cursor"]) || ""

    with true <- is_binary(cursor),
         {:ok, refs} <- conversation_refs(channels) do
      {:ok, refs, cursor}
    else
      _invalid -> {:error, {:slack_protocol_error, :conversations}}
    end
  end

  defp conversation_page(_body), do: {:error, {:slack_protocol_error, :conversations}}

  defp shared_conversation_page(%{"channels" => channels} = body) when is_list(channels) do
    cursor = get_in(body, ["response_metadata", "next_cursor"]) || ""

    with true <- is_binary(cursor),
         {:ok, refs} <- shared_conversation_refs(channels) do
      {:ok, refs, cursor}
    else
      _invalid -> {:error, {:slack_protocol_error, :conversations}}
    end
  end

  defp shared_conversation_page(_body),
    do: {:error, {:slack_protocol_error, :conversations}}

  defp shared_conversation_refs(channels) do
    Enum.reduce_while(channels, {:ok, []}, fn channel, {:ok, refs} ->
      case shared_conversation_ref(channel) do
        {:ok, nil} -> {:cont, {:ok, refs}}
        {:ok, channel_ref} -> {:cont, {:ok, [channel_ref | refs]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, Enum.reverse(refs)}
      {:error, _reason} = error -> error
    end
  end

  defp shared_conversation_ref(%{"id" => channel_ref, "is_im" => true} = channel),
    do: current_shared_conversation_ref(channel_ref, channel)

  defp shared_conversation_ref(%{"id" => channel_ref, "is_archived" => false} = channel),
    do: current_shared_conversation_ref(channel_ref, channel)

  defp shared_conversation_ref(%{"id" => _channel_ref, "is_archived" => true}), do: {:ok, nil}
  defp shared_conversation_ref(_channel), do: {:error, {:slack_protocol_error, :conversations}}

  defp current_shared_conversation_ref(channel_ref, channel) do
    with :ok <- slack_id(channel_ref),
         {:ok, external_shared} <- external_shared?(channel) do
      if external_shared, do: {:ok, nil}, else: {:ok, channel_ref}
    else
      _invalid -> {:error, {:slack_protocol_error, :conversations}}
    end
  end

  defp external_shared?(%{
         "is_ext_shared" => external_shared,
         "is_pending_ext_shared" => pending_external_shared
       })
       when is_boolean(external_shared) and is_boolean(pending_external_shared),
       do: {:ok, external_shared or pending_external_shared}

  defp external_shared?(%{"is_im" => true, "is_org_shared" => org_shared})
       when is_boolean(org_shared),
       do: {:ok, org_shared}

  defp external_shared?(_channel), do: {:error, :external_shared}

  defp conversation_listing_page(%{"channels" => channels} = body) when is_list(channels) do
    cursor = get_in(body, ["response_metadata", "next_cursor"]) || ""

    with true <- is_binary(cursor),
         {:ok, conversations} <- normalize_conversations(channels) do
      {:ok, conversations, cursor}
    else
      _invalid -> {:error, {:slack_protocol_error, :conversations}}
    end
  end

  defp conversation_listing_page(_body),
    do: {:error, {:slack_protocol_error, :conversations}}

  defp bookmarks(%{"bookmarks" => bookmarks}, channel_ref)
       when is_list(bookmarks) and length(bookmarks) <= @maximum_bookmarks do
    if Enum.all?(bookmarks, &valid_bookmark?(&1, channel_ref)) and
         bounded_slack_result(bookmarks, :bookmarks) == :ok,
       do: {:ok, bookmarks},
       else: {:error, {:slack_protocol_error, :bookmarks}}
  end

  defp bookmarks(_body, _channel_ref), do: {:error, {:slack_protocol_error, :bookmarks}}

  defp valid_bookmark?(
         %{
           "channel_id" => channel_ref,
           "id" => bookmark_ref,
           "title" => title,
           "type" => type
         } = bookmark,
         channel_ref
       ) do
    resource_id?(bookmark_ref) and bounded_string?(title, 1_024) and
      bounded_token?(type, 64) and optional_bounded_string?(bookmark["link"], 8_192) and
      optional_resource_id?(bookmark["entity_id"])
  end

  defp valid_bookmark?(_bookmark, _channel_ref), do: false

  defp normalize_conversations(channels) do
    Enum.reduce_while(channels, {:ok, []}, fn
      %{
        "id" => channel_ref,
        "is_archived" => archived,
        "is_ext_shared" => external_shared,
        "is_private" => private,
        "name" => name
      } = channel,
      {:ok, conversations}
      when is_boolean(archived) and is_boolean(external_shared) and is_boolean(private) and
             is_binary(name) ->
        with :ok <- slack_id(channel_ref),
             {:ok, topic} <- conversation_text(channel["topic"]),
             {:ok, purpose} <- conversation_text(channel["purpose"]) do
          conversation = %{
            "channel_ref" => channel_ref,
            "is_archived" => archived,
            "is_external_shared" => external_shared,
            "is_private" => private,
            "name" => name,
            "purpose" => purpose,
            "topic" => topic
          }

          conversation = maybe_put_canvas_ref(conversation, channel)

          {:cont, {:ok, [conversation | conversations]}}
        else
          {:error, _reason} -> {:halt, {:error, {:slack_protocol_error, :conversations}}}
        end

      _invalid, _result ->
        {:halt, {:error, {:slack_protocol_error, :conversations}}}
    end)
    |> case do
      {:ok, conversations} -> {:ok, Enum.reverse(conversations)}
      {:error, _reason} = error -> error
    end
  end

  defp conversation_text(nil), do: {:ok, ""}
  defp conversation_text(%{"value" => value}) when is_binary(value), do: {:ok, value}
  defp conversation_text(_value), do: {:error, :conversation_text}

  defp maybe_put_canvas_ref(conversation, channel) do
    case get_in(channel, ["properties", "canvas", "file_id"]) do
      nil ->
        conversation

      canvas_ref ->
        if(slack_id(canvas_ref) == :ok,
          do: Map.put(conversation, "canvas_ref", canvas_ref),
          else: conversation
        )
    end
  end

  defp conversation_refs(channels) do
    Enum.reduce_while(channels, {:ok, []}, fn
      %{"id" => channel_ref, "is_archived" => false, "is_private" => private} = channel,
      {:ok, refs}
      when is_boolean(private) ->
        conversation_ref(
          channel_ref,
          Map.get(channel, "is_member", true),
          private,
          Map.get(channel, "is_ext_shared"),
          refs
        )

      %{"id" => _channel_ref}, {:ok, refs} ->
        {:cont, {:ok, refs}}

      _invalid, _result ->
        {:halt, {:error, {:slack_protocol_error, :conversations}}}
    end)
    |> case do
      {:ok, refs} -> {:ok, Enum.reverse(refs)}
      {:error, _reason} = error -> error
    end
  end

  defp conversation_ref(_channel_ref, false, _private, _external_shared, refs),
    do: {:cont, {:ok, refs}}

  defp conversation_ref(channel_ref, true, private, external_shared, refs)
       when is_boolean(external_shared) do
    case slack_id(channel_ref) do
      :ok ->
        {:cont,
         {:ok,
          [
            %{
              channel_ref: channel_ref,
              external_shared: external_shared,
              private: private
            }
            | refs
          ]}}

      {:error, _reason} ->
        {:halt, {:error, {:slack_protocol_error, :conversations}}}
    end
  end

  defp conversation_ref(_channel_ref, _member, _private, _external_shared, _refs),
    do: {:halt, {:error, {:slack_protocol_error, :conversations}}}

  defp conversation_list_document(%{} = document) do
    allowed = ~w(cursor exclude_archived limit types)
    keys = Map.keys(document)

    with true <- Enum.all?(keys, &is_binary/1) and keys -- allowed == [],
         {:ok, cursor} <- list_cursor(Map.get(document, "cursor")),
         {:ok, exclude_archived} <- list_boolean(Map.get(document, "exclude_archived", true)),
         {:ok, limit} <- conversation_limit(Map.get(document, "limit", 100)),
         {:ok, types} <- conversation_types(Map.get(document, "types", ["public_channel"])) do
      {:ok,
       [
         {"exclude_archived", exclude_archived},
         {"limit", limit},
         {"types", Enum.join(types, ",")}
       ]
       |> maybe_query_cursor(cursor)}
    else
      _invalid -> {:error, {:invalid_slack_api_request, :conversations}}
    end
  end

  defp conversation_list_document(_document),
    do: {:error, {:invalid_slack_api_request, :conversations}}

  defp history_document(%{} = document) do
    allowed = ~w(cursor inclusive latest limit oldest)
    keys = Map.keys(document)

    with true <- Enum.all?(keys, &is_binary/1) and keys -- allowed == [],
         {:ok, cursor} <- list_cursor(Map.get(document, "cursor")),
         {:ok, inclusive} <- list_boolean(Map.get(document, "inclusive", false)),
         {:ok, limit} <- source_limit(Map.get(document, "limit", 100)),
         {:ok, oldest} <- optional_message_timestamp(Map.get(document, "oldest")),
         {:ok, latest} <- optional_message_timestamp(Map.get(document, "latest")) do
      {:ok,
       [
         {"inclusive", inclusive},
         {"limit", limit}
       ]
       |> maybe_query_parameter("cursor", cursor)
       |> maybe_query_parameter("latest", latest)
       |> maybe_query_parameter("oldest", oldest)}
    else
      _invalid -> {:error, {:invalid_slack_api_request, :history}}
    end
  end

  defp history_document(_document), do: {:error, {:invalid_slack_api_request, :history}}

  defp source_history_path(channel_ref, nil, parameters),
    do: "/conversations.history?" <> URI.encode_query([{"channel", channel_ref} | parameters])

  defp source_history_path(channel_ref, thread_ref, parameters),
    do:
      "/conversations.replies?" <>
        URI.encode_query([{"channel", channel_ref}, {"ts", thread_ref} | parameters])

  defp list_cursor(nil), do: {:ok, nil}

  defp list_cursor(value) when is_binary(value) and byte_size(value) in 1..4_096,
    do: {:ok, value}

  defp list_cursor(_value), do: {:error, :cursor}

  defp list_boolean(value) when is_boolean(value), do: {:ok, value}
  defp list_boolean(_value), do: {:error, :boolean}

  defp conversation_limit(value) when is_integer(value) and value in 1..200, do: {:ok, value}
  defp conversation_limit(_value), do: {:error, :limit}

  defp source_limit(value) when is_integer(value) and value in 1..100, do: {:ok, value}
  defp source_limit(_value), do: {:error, :limit}

  defp conversation_types(values) when is_list(values) and length(values) in 1..2 do
    allowed = ["public_channel", "private_channel"]

    if values == Enum.uniq(values) and Enum.all?(values, &(&1 in allowed)),
      do: {:ok, values},
      else: {:error, :types}
  end

  defp conversation_types(_values), do: {:error, :types}

  defp maybe_query_cursor(parameters, nil), do: parameters
  defp maybe_query_cursor(parameters, cursor), do: parameters ++ [{"cursor", cursor}]

  defp maybe_query_parameter(parameters, _key, nil), do: parameters
  defp maybe_query_parameter(parameters, key, value), do: parameters ++ [{key, value}]

  defp optional_message_ref(nil), do: :ok
  defp optional_message_ref(value), do: message_timestamp(value)

  defp optional_message_timestamp(nil), do: {:ok, nil}

  defp optional_message_timestamp(value) do
    case message_timestamp(value) do
      :ok -> {:ok, value}
      {:error, _reason} -> {:error, :timestamp}
    end
  end

  defp message_timestamp(value) do
    if is_binary(value) and Regex.match?(~r/\A[0-9]{10,}\.[0-9]{1,6}\z/, value),
      do: :ok,
      else: {:error, {:invalid_slack_api_request, :timestamp}}
  end

  defp find_files_page(client, channel, thread, filenames, cursor \\ nil, page \\ 1) do
    path = history_path(channel, thread, cursor)

    with {:ok, response} <- request(client, :get, path, nil),
         {:ok, body} <- slack_response(response),
         {:ok, messages, next_cursor} <- history(body) do
      case find_file_delivery(messages, filenames) do
        {:ok, message_ref} ->
          {:ok, message_ref}

        :not_found when next_cursor == "" ->
          :not_found

        :not_found when page < @maximum_pages ->
          find_files_page(client, channel, thread, filenames, next_cursor, page + 1)

        :not_found ->
          {:error, {:slack_reconciliation_incomplete, @maximum_pages * @page_size}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp history_path(channel, thread, cursor, oldest \\ nil)

  defp history_path(channel, nil, cursor, oldest) do
    query(
      [{"channel", channel}, {"limit", @page_size}, {"include_all_metadata", true}] ++
        if(oldest, do: [{"oldest", oldest}, {"inclusive", true}], else: []),
      cursor
    )
    |> then(&("/conversations.history?" <> &1))
  end

  defp history_path(channel, thread, cursor, _oldest) do
    query(
      [
        {"channel", channel},
        {"ts", thread},
        {"limit", @page_size},
        {"include_all_metadata", true}
      ],
      cursor
    )
    |> then(&("/conversations.replies?" <> &1))
  end

  defp query(parameters, nil), do: URI.encode_query(parameters)
  defp query(parameters, cursor), do: URI.encode_query(parameters ++ [{"cursor", cursor}])

  defp history(%{"messages" => messages} = body) when is_list(messages) do
    cursor = get_in(body, ["response_metadata", "next_cursor"])

    if is_nil(cursor) or is_binary(cursor),
      do: {:ok, messages, cursor || ""},
      else: {:error, {:slack_protocol_error, :history}}
  end

  defp history(_body), do: {:error, {:slack_protocol_error, :history}}

  defp find_delivery(messages, delivery_ref) do
    Enum.reduce_while(messages, :not_found, fn
      %{
        "metadata" => %{
          "event_payload" => %{"id" => ^delivery_ref},
          "event_type" => "responder_delivery"
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

  defp find_file_delivery(messages, filenames) do
    expected = MapSet.new(filenames)

    Enum.reduce_while(messages, :not_found, fn
      %{"files" => files, "ts" => message_ref}, :not_found
      when is_list(files) and is_binary(message_ref) and message_ref != "" ->
        file_delivery_result(file_names(files), expected, message_ref)

      %{}, :not_found ->
        {:cont, :not_found}

      _invalid, :not_found ->
        {:halt, {:error, {:slack_protocol_error, :message}}}
    end)
  end

  defp file_delivery_result({:ok, names}, expected, message_ref) do
    if MapSet.subset?(expected, MapSet.new(names)),
      do: {:halt, {:ok, message_ref}},
      else: {:cont, :not_found}
  end

  defp file_delivery_result({:error, _reason} = error, _expected, _message_ref),
    do: {:halt, error}

  defp file_names(files) do
    Enum.reduce_while(files, {:ok, []}, fn
      %{"name" => name}, {:ok, names} when is_binary(name) and name != "" ->
        {:cont, {:ok, [name | names]}}

      %{}, {:ok, names} ->
        {:cont, {:ok, names}}

      _invalid, {:ok, _names} ->
        {:halt, {:error, {:slack_protocol_error, :file}}}
    end)
  end

  defp upload_external_files(client, files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, uploaded} ->
      case upload_external_file(client, file) do
        {:ok, result} -> {:cont, {:ok, uploaded ++ [result]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp upload_external_file(client, file) do
    request_document = %{
      "alt_txt" => file.alt_text,
      "filename" => file.filename,
      "length" => byte_size(file.data)
    }

    with {:ok, response} <-
           request(client, :post, "/files.getUploadURLExternal", request_document),
         {:ok, body} <- slack_response(response),
         {:ok, upload_url, file_id} <- upload_target(body),
         :ok <- client.uploader.upload(client.upload_http, upload_url, file.data, file.media_type) do
      {:ok, %{"id" => file_id, "title" => file.title}}
    end
  end

  defp upload_target(%{"file_id" => file_id, "upload_url" => upload_url}) do
    with :ok <- text(file_id),
         :ok <- text(upload_url) do
      {:ok, upload_url, file_id}
    else
      {:error, _reason} -> {:error, {:slack_protocol_error, :upload_target}}
    end
  end

  defp upload_target(_body), do: {:error, {:slack_protocol_error, :upload_target}}

  defp completion_document(channel, nil, rendered, files),
    do: completion_document(channel, rendered, files)

  defp completion_document(channel, thread, rendered, files),
    do: Map.put(completion_document(channel, rendered, files), "thread_ts", thread)

  defp completion_document(channel, rendered, files) do
    %{
      "blocks" => Jason.encode!(rendered["blocks"]),
      "channel_id" => channel,
      "files" => files,
      "initial_comment" => rendered["text"]
    }
  end

  defp render(body) when is_binary(body) do
    with :ok <- text(body) do
      {:ok, %{"text" => neutralize_control_syntax(body)}}
    end
  end

  defp render(%{} = document), do: Renderer.render(document)
  defp render(_body), do: {:error, {:invalid_slack_api_request, :message}}

  defp specimen_payload(%{"text" => "Card Lab · " <> _, "blocks" => blocks} = payload)
       when map_size(payload) == 2 and is_list(blocks) and length(blocks) in 1..50 do
    if byte_size(Jason.encode!(payload)) <= 256 * 1_024 and specimen_controls?(payload),
      do: :ok,
      else: {:error, {:invalid_slack_api_request, :card_lab_specimen}}
  end

  defp specimen_payload(_payload),
    do: {:error, {:invalid_slack_api_request, :card_lab_specimen}}

  defp specimen_controls?(%{} = value) do
    Enum.all?(value, fn
      {"action_id", "card_lab_preview_" <> _id} -> true
      {"action_id", _id} -> false
      {key, _item} when key in ["callback_id", "private_metadata"] -> false
      {_key, item} -> specimen_controls?(item)
    end)
  end

  defp specimen_controls?(value) when is_list(value), do: Enum.all?(value, &specimen_controls?/1)

  defp specimen_controls?(value) when is_binary(value),
    do: not String.contains?(value, ["<!", "<@"])

  defp specimen_controls?(_value), do: true

  defp message_document(channel, nil, rendered, delivery_ref),
    do: message_document(channel, rendered, delivery_ref)

  defp message_document(channel, thread, rendered, delivery_ref),
    do: Map.put(message_document(channel, rendered, delivery_ref), "thread_ts", thread)

  defp message_document(channel, rendered, delivery_ref) do
    Map.merge(rendered, %{
      "channel" => channel,
      "metadata" => %{
        "event_payload" => %{"id" => delivery_ref},
        "event_type" => "responder_delivery"
      },
      "mrkdwn" => false,
      "unfurl_links" => false,
      "unfurl_media" => false
    })
  end

  defp neutralize_control_syntax(body) do
    body
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp slack_response(%{body: %{"ok" => true} = body, status: 200}), do: {:ok, body}

  defp slack_response(%{
         body: %{"error" => "ratelimited"},
         headers: headers,
         status: status
       })
       when status in [200, 429] and is_list(headers) do
    error =
      if status == 200,
        do: {:slack_api_error, "ratelimited"},
        else: {:slack_http_error, status, "ratelimited"}

    {:error, {:delivery_rate_limited, retry_after(headers), error}}
  end

  defp slack_response(%{body: body, headers: headers, status: 429}) when is_list(headers) do
    {:error, {:delivery_rate_limited, retry_after(headers), {:slack_http_error, 429, body}}}
  end

  defp slack_response(%{body: %{"error" => error, "ok" => false}, status: 200})
       when is_binary(error),
       do: {:error, {:slack_api_error, error}}

  defp slack_response(%{body: %{"error" => error}, status: status})
       when is_integer(status) and is_binary(error),
       do: {:error, {:slack_http_error, status, error}}

  defp slack_response(%{status: status}) when is_integer(status),
    do: {:error, {:slack_http_error, status, :invalid_response}}

  defp slack_response(_response), do: {:error, {:slack_protocol_error, :response}}

  defp request(%__MODULE__{http: http, requester: requester}, method, path, document),
    do: requester.request(http, method, path, document, [])

  defp text(value) do
    if is_binary(value) and String.valid?(value) and byte_size(value) > 0 and
         byte_size(value) <= 256 * 1_024,
       do: :ok,
       else: {:error, {:invalid_slack_api_request, :text}}
  end

  defp bounded_text(value, maximum) do
    if is_binary(value) and String.valid?(value) and String.trim(value) != "" and
         byte_size(value) <= maximum,
       do: :ok,
       else: {:error, {:invalid_slack_api_request, :text}}
  end

  defp thread_status(value) do
    if is_binary(value) and String.valid?(value) and byte_size(value) <= 100 and
         :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, {:invalid_slack_api_request, :thread_status}}
  end

  defp conversation_name(value) do
    if is_binary(value) and byte_size(value) in 1..@maximum_conversation_name_bytes and
         Regex.match?(~r/\A[a-z0-9_-]+\z/, value),
       do: :ok,
       else: {:error, {:invalid_slack_api_request, :conversation_name}}
  end

  defp unique_slack_ids(values) when is_list(values) and length(values) <= 200 do
    if values == Enum.uniq(values) and Enum.all?(values, &(slack_id(&1) == :ok)),
      do: :ok,
      else: {:error, {:invalid_slack_api_request, :users}}
  end

  defp unique_slack_ids(_values), do: {:error, {:invalid_slack_api_request, :users}}

  defp utc_datetime(%DateTime{} = value) do
    if value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0,
      do: :ok,
      else: {:error, {:invalid_slack_api_request, :requested_at}}
  end

  defp utc_datetime(_value), do: {:error, {:invalid_slack_api_request, :requested_at}}

  defp optional_text(nil), do: :ok
  defp optional_text(value), do: text(value)

  defp home_view(%{"blocks" => blocks, "type" => "home"} = view)
       when is_list(blocks) and length(blocks) <= 100 do
    if Map.keys(view) |> Enum.sort() == ["blocks", "type"] and
         Enum.all?(blocks, &is_map/1) and byte_size(Jason.encode!(view)) <= 256 * 1_024,
       do: :ok,
       else: {:error, {:invalid_slack_api_request, :home_view}}
  end

  defp home_view(_view), do: {:error, {:invalid_slack_api_request, :home_view}}

  defp modal_view(%{"blocks" => blocks, "type" => "modal"} = view)
       when is_list(blocks) and length(blocks) <= 100 do
    required = ~w(blocks callback_id close private_metadata submit title type)

    if Map.keys(view) |> Enum.sort() == Enum.sort(required) and
         Enum.all?(blocks, &is_map/1) and byte_size(Jason.encode!(view)) <= 256 * 1_024,
       do: :ok,
       else: {:error, {:invalid_slack_api_request, :modal_view}}
  end

  defp modal_view(_view), do: {:error, {:invalid_slack_api_request, :modal_view}}

  defp slack_id(value) do
    if is_binary(value) and Regex.match?(~r/\A[A-Z0-9]+\z/, value),
      do: :ok,
      else: {:error, {:invalid_slack_api_request, :id}}
  end

  defp resource_id?(value),
    do:
      is_binary(value) and byte_size(value) in 1..256 and
        Regex.match?(~r/\A[A-Za-z0-9]+\z/, value)

  defp optional_resource_id?(nil), do: true
  defp optional_resource_id?(value), do: resource_id?(value)

  defp bounded_token?(value, maximum),
    do:
      is_binary(value) and byte_size(value) in 1..maximum and
        Regex.match?(~r/\A[a-z0-9_]+\z/, value)

  defp bounded_string?(value, maximum),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
        :binary.match(value, <<0>>) == :nomatch and String.trim(value) != ""

  defp optional_bounded_string?(nil, _maximum), do: true
  defp optional_bounded_string?(value, maximum), do: bounded_string?(value, maximum)

  defp allowed_user(
         %{
           "user" => %{
             "deleted" => deleted,
             "id" => user_ref,
             "is_bot" => is_bot,
             "is_restricted" => is_restricted,
             "is_ultra_restricted" => is_ultra_restricted,
             "team_id" => workspace_ref
           }
         },
         user_ref,
         workspace_ref
       )
       when is_boolean(deleted) and is_boolean(is_bot) and is_boolean(is_restricted) and
              is_boolean(is_ultra_restricted) do
    {:ok, not deleted and not is_bot and not is_restricted and not is_ultra_restricted}
  end

  defp allowed_user(
         %{"user" => %{"id" => _id, "team_id" => _actual_workspace}},
         _user_ref,
         _expected_workspace
       ),
       do: {:ok, false}

  defp allowed_user(_body, _user_ref, _workspace_ref),
    do: {:error, {:slack_protocol_error, :user}}

  defp group_users(%{"users" => users}) when is_list(users) do
    if Enum.uniq(users) == users and Enum.all?(users, &(slack_id(&1) == :ok)),
      do: {:ok, Enum.sort(users)},
      else: {:error, {:slack_protocol_error, :user_group}}
  end

  defp group_users(_body), do: {:error, {:slack_protocol_error, :user_group}}

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

  defp filenames(values) when is_list(values) and length(values) in 1..@maximum_files do
    if Enum.uniq(values) == values and Enum.all?(values, &filename?/1),
      do: :ok,
      else: {:error, {:invalid_slack_api_request, :files}}
  end

  defp filenames(_values), do: {:error, {:invalid_slack_api_request, :files}}

  defp upload_files(values) when is_list(values) and length(values) in 1..@maximum_files do
    total = Enum.reduce(values, 0, fn file, acc -> acc + upload_bytes(file) end)

    if total <= @maximum_file_bytes and Enum.all?(values, &upload_file?/1) and
         Enum.uniq(Enum.map(values, & &1.filename)) == Enum.map(values, & &1.filename) do
      :ok
    else
      {:error, {:invalid_slack_api_request, :files}}
    end
  end

  defp upload_files(_values), do: {:error, {:invalid_slack_api_request, :files}}

  defp upload_file?(
         %{
           alt_text: alt_text,
           data: data,
           filename: filename,
           media_type: media_type,
           title: title
         } = file
       )
       when map_size(file) == 5 do
    filename?(filename) and text_bound?(title, 200) and text_bound?(alt_text, 1_000) and
      media_type in @media_types and is_binary(data) and byte_size(data) in 1..@maximum_file_bytes
  end

  defp upload_file?(_file), do: false

  defp upload_bytes(%{data: data}) when is_binary(data), do: byte_size(data)
  defp upload_bytes(_file), do: @maximum_file_bytes + 1

  defp filename?(value) do
    text_bound?(value, 255) and value not in [".", ".."] and
      not String.contains?(value, ["/", "\\"])
  end

  defp text_bound?(value, maximum) do
    is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
      :binary.match(value, <<0>>) == :nomatch and String.trim(value) != ""
  end

  defp retry_after(headers) do
    value =
      Enum.find_value(headers, fn
        {name, value} when is_binary(name) and is_binary(value) ->
          if String.downcase(name) == "retry-after", do: value

        _invalid ->
          nil
      end)

    case Integer.parse(value || "") do
      {seconds, ""} when seconds > 0 -> seconds
      _invalid -> nil
    end
  end
end
