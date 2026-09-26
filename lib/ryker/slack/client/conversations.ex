defmodule Ryker.Slack.Client.Conversations do
  @moduledoc """
  The conversations Ryker reads: the ones it is in, the ones it shares with a
  person, one conversation's details and state, and its bookmarks.

  Every page reader returns `{:ok, items, next_cursor}` for the pagination
  walk, and every refusal of a reply is a `{:slack_protocol_error, field}`
  because the request was well-formed and the reply was not. Creating a
  conversation and setting it up is `Client.Rooms`.
  """

  alias Ryker.Slack.Client.{Fields, Pagination, Transport}

  @conversation_page_size 200
  @maximum_bookmarks 100

  def list_conversations(client, document) do
    with {:ok, parameters} <- list_document(document),
         path <- "/users.conversations?" <> URI.encode_query(parameters),
         {:ok, response} <- Transport.request(client, :get, path, nil),
         {:ok, body} <- Transport.response(response),
         {:ok, channels, cursor} <- listing_page(body) do
      {:ok, %{"conversations" => channels, "cursor" => cursor}}
    end
  end

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

  def conversation_state(client, channel_ref) do
    with :ok <- Fields.slack_id(channel_ref),
         {:ok, response} <- Transport.request(client, :get, info_path(channel_ref), nil) do
      conversation_state_response(response, channel_ref)
    end
  end

  def list_bookmarks(client, channel_ref) do
    with :ok <- Fields.slack_id(channel_ref),
         {:ok, response} <-
           Transport.request(client, :post, "/bookmarks.list", %{"channel_id" => channel_ref}),
         {:ok, body} <- Transport.response(response) do
      bookmarks(body, channel_ref)
    end
  end

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
             &joined_page/1,
             @conversation_page_size
           ) do
      {:ok, channels |> Enum.uniq_by(& &1.channel_ref) |> Enum.sort_by(& &1.channel_ref)}
    end
  end

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
             &shared_page/1,
             @conversation_page_size
           ) do
      {:ok, MapSet.new(channel_refs)}
    end
  end

  # --- one conversation -----------------------------------------------------

  defp info_path(channel_ref),
    do:
      "/conversations.info?" <> URI.encode_query(channel: channel_ref, include_num_members: false)

  defp conversation_state_response(
         %{body: %{"error" => "channel_not_found", "ok" => false}, status: 200},
         _channel_ref
       ),
       do: :not_found

  defp conversation_state_response(response, channel_ref) do
    with {:ok, body} <- Transport.response(response),
         do: conversation_state_reply(body, channel_ref)
  end

  defp conversation_state_reply(
         %{"channel" => %{"id" => channel_ref, "is_archived" => archived}},
         channel_ref
       )
       when is_boolean(archived) do
    case Fields.slack_id(channel_ref) do
      :ok -> {:ok, if(archived, do: :archived, else: :active)}
      {:error, _reason} -> {:error, {:slack_protocol_error, :conversation}}
    end
  end

  defp conversation_state_reply(_body, _channel_ref),
    do: {:error, {:slack_protocol_error, :conversation}}

  # A bookmarks.list reply, every bookmark checked to belong to the channel asked about.
  defp bookmarks(%{"bookmarks" => bookmarks}, channel_ref)
       when is_list(bookmarks) and length(bookmarks) <= @maximum_bookmarks do
    if Enum.all?(bookmarks, &valid_bookmark?(&1, channel_ref)) and
         Fields.bounded_result(bookmarks, :bookmarks) == :ok,
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
    Fields.resource_id?(bookmark_ref) and Fields.bounded_string?(title, 1_024) and
      Fields.bounded_token?(type, 64) and
      Fields.optional_bounded_string?(bookmark["link"], 8_192) and
      Fields.optional_resource_id?(bookmark["entity_id"])
  end

  defp valid_bookmark?(_bookmark, _channel_ref), do: false

  # --- the listing a capability tool asks for -------------------------------

  # The users.conversations query for a caller-supplied listing document.
  defp list_document(%{} = document) do
    allowed = ~w(cursor exclude_archived limit types)
    keys = Map.keys(document)

    with true <- Enum.all?(keys, &is_binary/1) and keys -- allowed == [],
         {:ok, cursor} <- Fields.listing_cursor(Map.get(document, "cursor")),
         {:ok, exclude_archived} <-
           Fields.listing_boolean(Map.get(document, "exclude_archived", true)),
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

  defp list_document(_document), do: {:error, {:invalid_slack_api_request, :conversations}}

  defp conversation_limit(value) when is_integer(value) and value in 1..200, do: {:ok, value}
  defp conversation_limit(_value), do: {:error, :limit}

  defp conversation_types(values) when is_list(values) and length(values) in 1..2 do
    allowed = ["public_channel", "private_channel"]

    if values == Enum.uniq(values) and Enum.all?(values, &(&1 in allowed)),
      do: {:ok, values},
      else: {:error, :types}
  end

  defp conversation_types(_values), do: {:error, :types}

  defp maybe_query_cursor(parameters, nil), do: parameters
  defp maybe_query_cursor(parameters, cursor), do: parameters ++ [{"cursor", cursor}]

  # A users.conversations page as the normalized conversations a capability tool lists.
  defp listing_page(%{"channels" => channels} = body) when is_list(channels) do
    with {:ok, cursor} <- Pagination.next_cursor(body),
         {:ok, conversations} <- normalize_conversations(channels) do
      {:ok, conversations, cursor}
    else
      _invalid -> {:error, {:slack_protocol_error, :conversations}}
    end
  end

  defp listing_page(_body), do: {:error, {:slack_protocol_error, :conversations}}

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

  # --- the conversations Ryker is in ----------------------------------------

  # A users.conversations page as the joined, unarchived channels with their privacy.
  defp joined_page(%{"channels" => channels} = body) when is_list(channels) do
    with {:ok, cursor} <- Pagination.next_cursor(body),
         {:ok, refs} <- conversation_refs(channels) do
      {:ok, refs, cursor}
    else
      _invalid -> {:error, {:slack_protocol_error, :conversations}}
    end
  end

  defp joined_page(_body), do: {:error, {:slack_protocol_error, :conversations}}

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

  # --- the conversations Ryker shares with a person -------------------------

  # A users.conversations page for another user, as the channel refs Ryker shares with them.
  defp shared_page(%{"channels" => channels} = body) when is_list(channels) do
    with {:ok, cursor} <- Pagination.next_cursor(body),
         {:ok, refs} <- shared_conversation_refs(channels) do
      {:ok, refs, cursor}
    else
      _invalid -> {:error, {:slack_protocol_error, :conversations}}
    end
  end

  defp shared_page(_body), do: {:error, {:slack_protocol_error, :conversations}}

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
