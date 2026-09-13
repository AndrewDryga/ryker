defmodule Ryker.Slack.Client.Conversations do
  @moduledoc """
  What the client sends to and reads from Slack's conversation, bookmark and
  user endpoints: the listing documents it accepts, the pages it parses and
  the shapes it refuses.

  Every page reader returns `{:ok, items, next_cursor}` for the pagination
  walk, and every refusal is a `{:slack_protocol_error, field}` because the
  request was well-formed and the reply was not.
  """

  alias Ryker.Slack.Client.{Fields, Pagination}

  @maximum_bookmarks 100

  # --- documents ------------------------------------------------------------

  @doc "The users.conversations query for a caller-supplied listing document."
  @spec list_document(term()) ::
          {:ok, [{String.t(), term()}]} | {:error, {:invalid_slack_api_request, :conversations}}
  def list_document(%{} = document) do
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

  def list_document(_document), do: {:error, {:invalid_slack_api_request, :conversations}}

  @doc "The conversations.history or conversations.replies query for a source read."
  @spec history_document(term()) ::
          {:ok, [{String.t(), term()}]} | {:error, {:invalid_slack_api_request, :history}}
  def history_document(%{} = document) do
    allowed = ~w(cursor inclusive latest limit oldest)
    keys = Map.keys(document)
    oldest = Map.get(document, "oldest")
    latest = Map.get(document, "latest")

    with true <- Enum.all?(keys, &is_binary/1) and keys -- allowed == [],
         {:ok, cursor} <- list_cursor(Map.get(document, "cursor")),
         {:ok, inclusive} <- list_boolean(Map.get(document, "inclusive", false)),
         {:ok, limit} <- source_limit(Map.get(document, "limit", 100)),
         :ok <- Fields.optional_message_timestamp(oldest),
         :ok <- Fields.optional_message_timestamp(latest) do
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

  def history_document(_document), do: {:error, {:invalid_slack_api_request, :history}}

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

  # --- pages ----------------------------------------------------------------

  @doc "A users.conversations page as the joined, unarchived channels with their privacy."
  @spec joined_page(map()) :: {:ok, [map()], String.t()} | {:error, term()}
  def joined_page(%{"channels" => channels} = body) when is_list(channels) do
    with {:ok, cursor} <- Pagination.next_cursor(body),
         {:ok, refs} <- conversation_refs(channels) do
      {:ok, refs, cursor}
    else
      _invalid -> {:error, {:slack_protocol_error, :conversations}}
    end
  end

  def joined_page(_body), do: {:error, {:slack_protocol_error, :conversations}}

  @doc "A users.conversations page for another user, as the channel refs Ryker shares with them."
  @spec shared_page(map()) :: {:ok, [String.t()], String.t()} | {:error, term()}
  def shared_page(%{"channels" => channels} = body) when is_list(channels) do
    with {:ok, cursor} <- Pagination.next_cursor(body),
         {:ok, refs} <- shared_conversation_refs(channels) do
      {:ok, refs, cursor}
    else
      _invalid -> {:error, {:slack_protocol_error, :conversations}}
    end
  end

  def shared_page(_body), do: {:error, {:slack_protocol_error, :conversations}}

  @doc "A users.conversations page as the normalized conversations a capability tool lists."
  @spec listing_page(map()) :: {:ok, [map()], String.t()} | {:error, term()}
  def listing_page(%{"channels" => channels} = body) when is_list(channels) do
    with {:ok, cursor} <- Pagination.next_cursor(body),
         {:ok, conversations} <- normalize_conversations(channels) do
      {:ok, conversations, cursor}
    else
      _invalid -> {:error, {:slack_protocol_error, :conversations}}
    end
  end

  def listing_page(_body), do: {:error, {:slack_protocol_error, :conversations}}

  @doc "A conversations.list page, raw, for finding one channel by name."
  @spec search_page(map()) :: {:ok, [map()], String.t()} | {:error, term()}
  def search_page(%{"channels" => channels} = body) when is_list(channels) do
    case Pagination.next_cursor(body) do
      {:ok, cursor} -> {:ok, channels, cursor}
      {:error, _reason} -> {:error, {:slack_protocol_error, :conversations}}
    end
  end

  def search_page(_body), do: {:error, {:slack_protocol_error, :conversations}}

  @doc """
  The channel on a page that `ensure_conversation` created or would have:
  same name, privacy and creator, created within the request's window.
  """
  @spec matching_conversation([map()], String.t(), boolean(), String.t(), DateTime.t()) ::
          {:ok, String.t()} | :not_found | {:error, term()}
  def matching_conversation(channels, name, private, creator_ref, requested_at) do
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
        if Fields.slack_id(channel_ref) == :ok,
          do: {:halt, {:ok, channel_ref}},
          else: {:halt, {:error, {:slack_protocol_error, :conversation}}}

      %{}, :not_found ->
        {:cont, :not_found}

      _invalid, :not_found ->
        {:halt, {:error, {:slack_protocol_error, :conversation}}}
    end)
  end

  @doc "The channel ref of a conversations.create reply that matches what was asked for."
  @spec created_conversation(map(), String.t(), boolean(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def created_conversation(
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
    case Fields.slack_id(channel_ref) do
      :ok -> {:ok, channel_ref}
      {:error, _reason} -> {:error, {:slack_protocol_error, :conversation}}
    end
  end

  def created_conversation(_body, _name, _private, _creator_ref),
    do: {:error, {:slack_protocol_error, :conversation}}

  @spec conversation_state(map(), String.t()) :: {:ok, :active | :archived} | {:error, term()}
  def conversation_state(
        %{"channel" => %{"id" => channel_ref, "is_archived" => archived}},
        channel_ref
      )
      when is_boolean(archived) do
    case Fields.slack_id(channel_ref) do
      :ok -> {:ok, if(archived, do: :archived, else: :active)}
      {:error, _reason} -> {:error, {:slack_protocol_error, :conversation}}
    end
  end

  def conversation_state(_body, _channel_ref),
    do: {:error, {:slack_protocol_error, :conversation}}

  @doc "A bookmarks.list reply, every bookmark checked to belong to the channel asked about."
  @spec bookmarks(map(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def bookmarks(%{"bookmarks" => bookmarks}, channel_ref)
      when is_list(bookmarks) and length(bookmarks) <= @maximum_bookmarks do
    if Enum.all?(bookmarks, &valid_bookmark?(&1, channel_ref)) and
         Fields.bounded_result(bookmarks, :bookmarks) == :ok,
       do: {:ok, bookmarks},
       else: {:error, {:slack_protocol_error, :bookmarks}}
  end

  def bookmarks(_body, _channel_ref), do: {:error, {:slack_protocol_error, :bookmarks}}

  defp valid_bookmark?(
         %{
           "channel_id" => channel_ref,
           "id" => bookmark_ref,
           "title" => title,
           "type" => type
         } = bookmark,
         channel_ref
       ) do
    Fields.resource_id?(bookmark_ref) and Fields.bounded_string?(title, 1_024) and
      Fields.bounded_token?(type, 64) and
      Fields.optional_bounded_string?(bookmark["link"], 8_192) and
      Fields.optional_resource_id?(bookmark["entity_id"])
  end

  defp valid_bookmark?(_bookmark, _channel_ref), do: false

  @doc "Whether a users.info reply describes an active full member of this workspace."
  @spec allowed_user(map(), String.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def allowed_user(
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

  def allowed_user(
        %{"user" => %{"id" => _id, "team_id" => _actual_workspace}},
        _user_ref,
        _expected_workspace
      ),
      do: {:ok, false}

  def allowed_user(_body, _user_ref, _workspace_ref),
    do: {:error, {:slack_protocol_error, :user}}

  @spec group_users(map()) :: {:ok, [String.t()]} | {:error, term()}
  def group_users(%{"users" => users}) when is_list(users) do
    if Enum.uniq(users) == users and Enum.all?(users, &(Fields.slack_id(&1) == :ok)),
      do: {:ok, Enum.sort(users)},
      else: {:error, {:slack_protocol_error, :user_group}}
  end

  def group_users(_body), do: {:error, {:slack_protocol_error, :user_group}}

  # --- normalization --------------------------------------------------------

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
        with :ok <- Fields.slack_id(channel_ref),
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
        if(Fields.slack_id(canvas_ref) == :ok,
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
    case Fields.slack_id(channel_ref) do
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
    with :ok <- Fields.slack_id(channel_ref),
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
end
