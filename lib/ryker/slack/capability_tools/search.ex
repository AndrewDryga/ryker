defmodule Ryker.Slack.CapabilityTools.Search do
  @moduledoc """
  Workspace search for one user-initiated turn: the provider's results are
  reduced to what the turn may see, and hits missing their context are read
  again through the exact source reader.
  """

  alias Ryker.Slack.CapabilityTools.{Arguments, Authority, Resources, SourceReader}
  alias Ryker.Slack.SourceRef

  @search_expansions 2

  @doc "Whether the provider returned everything: no continuation and no dropped hit."
  @spec complete?(map()) :: boolean()
  def complete?(response),
    do: response["complete"] != false and Map.get(response, "next_cursor") in [nil, ""]

  # A hit whose provider context is unavailable is read again through the
  # ordinary source reader, within a small budget per search.
  @spec expand_search_context(map(), map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def expand_search_context(
        %{"results" => %{"messages" => messages}} = response,
        arguments,
        binding,
        options
      ) do
    Enum.reduce_while(messages, {:ok, [], @search_expansions}, fn hit, {:ok, hits, remaining} ->
      case expand_search_hit(hit, arguments, binding, options, remaining) do
        {:ok, hit, remaining} -> {:cont, {:ok, [hit | hits], remaining}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> expanded_search_response(response, length(messages))
  end

  def expand_search_context(response, _arguments, _binding, _options), do: {:ok, response}

  defp expanded_search_response({:ok, hits, remaining}, response, original_count) do
    hits = hits |> Enum.reverse() |> Enum.reject(&is_nil/1)
    response = put_in(response, ["results", "messages"], hits)

    response =
      if length(hits) < original_count, do: Map.put(response, "complete", false), else: response

    {:ok,
     Map.put(response, "context_limits", %{
       "fallback_reads" => @search_expansions - remaining,
       "fallback_read_limit" => @search_expansions,
       "message_page_limit" => @search_expansions * 6
     })}
  end

  defp expanded_search_response({:error, _} = error, _response, _count), do: error

  defp expand_search_hit(hit, arguments, binding, options, remaining) do
    read = Arguments.source_read_arguments(hit, arguments)
    hit = Map.put(hit, "source_read", %{"tool" => "read_slack_source", "arguments" => read})

    cond do
      hit["context_coverage"]["status"] != "unavailable" -> {:ok, hit, remaining}
      remaining == 0 -> {:ok, put_in(hit, ["context_coverage", "reason"], "expansion_budget"), 0}
      true -> expand_search_original(hit, read, binding, options, remaining - 1)
    end
  end

  defp expand_search_original(hit, read, binding, options, remaining) do
    with {:ok, source, view, document} <- Arguments.read_document(read, options.workspace_ref),
         thread = if(view == :thread, do: source.message_ref),
         {:ok, anchor, root} <- SourceReader.source_anchor(options, source, thread),
         {:ok, page} <- SourceReader.source_page(options, source, thread, document, anchor, root),
         {:ok, messages} <-
           SourceReader.decorate_source_messages(
             page["messages"],
             source.workspace_ref,
             source.channel_ref
           ),
         {:ok, cursor} <-
           SourceReader.seal_source_cursor(page["cursor"], document, source, view, binding) do
      {before, after_messages} =
        Enum.split_with(
          messages,
          &(Arguments.timestamp_value(&1["ts"]) < Arguments.timestamp_value(anchor["ts"]))
        )

      coverage =
        Map.merge(page["coverage"], %{
          "status" => if(page["complete"], do: "complete", else: "partial"),
          "basis" => "original_reader",
          "neighbor_limit" => 2
        })

      read =
        if cursor == "", do: Map.put(read, "limit", 20), else: Map.put(read, "cursor", cursor)

      hit =
        Map.merge(hit, %{
          "content" => Map.get(anchor, "text", hit["content"]),
          "context_messages" => %{
            "before" => Enum.map(before, &compact_context_message/1),
            "after" => Enum.map(after_messages, &compact_context_message/1)
          },
          "context_coverage" => coverage,
          "thread_root" => if(root && root["source_ref"] != hit["source_ref"], do: root),
          "source_read" => %{"tool" => "read_slack_source", "arguments" => read}
        })

      {:ok, hit, remaining}
    else
      {:error, :slack_source_not_found} -> {:ok, nil, remaining}
      {:error, _} = error -> error
    end
  end

  @spec public_search_scopes_authorized([String.t()], map()) :: :ok | {:error, term()}
  def public_search_scopes_authorized(channel_refs, options) when is_list(channel_refs) do
    Enum.reduce_while(channel_refs, :ok, fn channel_ref, :ok ->
      case public_search_channel(options, channel_ref) do
        {:ok, true} -> {:cont, :ok}
        {:ok, false} -> {:halt, {:error, :unauthorized}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Slack search sees more than this turn may: every message, file and channel
  # is kept only when its channel is a live public one, and every user only
  # from this workspace.
  @spec authorize_search_response(term(), map()) :: {:ok, map()} | {:error, term()}
  def authorize_search_response(%{"results" => %{} = results} = response, options) do
    if Map.keys(results) -- Arguments.content_types() == [] do
      with {:ok, results} <- authorize_search_messages(results, options),
           {:ok, results} <- authorize_search_files(results, options),
           {:ok, results} <- authorize_search_channels(results, options),
           {:ok, results} <- authorize_search_users(results, options) do
        {:ok, Map.put(response, "results", results)}
      end
    else
      {:error, :slack_protocol_error}
    end
  end

  def authorize_search_response(_response, _options), do: {:error, :slack_protocol_error}

  defp authorize_search_messages(results, options) do
    authorize_search_result_list(
      results,
      "messages",
      &authorize_search_message(&1, options)
    )
  end

  defp authorize_search_files(results, options) do
    authorize_search_result_list(results, "files", &authorize_search_file(&1, options))
  end

  defp authorize_search_channels(results, options) do
    authorize_search_result_list(
      results,
      "channels",
      &authorize_search_channel(&1, options)
    )
  end

  defp authorize_search_users(results, options) do
    authorize_search_result_list(results, "users", fn
      %{"user_id" => user_ref} = result when is_binary(user_ref) ->
        team_ref = Map.get(result, "team_id", options.workspace_ref)

        if SourceRef.slack_id?(user_ref) and team_ref == options.workspace_ref do
          {:ok, Map.put(result, "entity_ref", "slack-user:#{user_ref}")}
        else
          {:error, :slack_protocol_error}
        end

      _invalid ->
        {:error, :slack_protocol_error}
    end)
  end

  defp authorize_search_result_list(results, key, authorize) do
    case Map.fetch(results, key) do
      :error ->
        {:ok, results}

      {:ok, values} when is_list(values) ->
        authorize_search_values(values, authorize)
        |> put_authorized_search_values(results, key)

      {:ok, _invalid} ->
        {:error, :slack_protocol_error}
    end
  end

  defp authorize_search_message(
         %{"channel_id" => channel_ref, "message_ts" => message_ref} = message,
         options
       )
       when is_binary(channel_ref) and is_binary(message_ref) do
    with {:ok, visible} <- public_search_channel(options, channel_ref) do
      authorize_search_message_visibility(visible, message, options, channel_ref, message_ref)
    end
  end

  defp authorize_search_message(_invalid, _options), do: {:error, :slack_protocol_error}

  defp authorize_search_message_visibility(false, _message, _options, _channel_ref, _message_ref),
    do: {:ok, nil}

  defp authorize_search_message_visibility(true, message, options, channel_ref, message_ref) do
    with true <- Map.get(message, "team_id", options.workspace_ref) == options.workspace_ref,
         {:ok, context, coverage} <- search_message_context(message, options.workspace_ref) do
      thread_ref = message["thread_ts"]

      {:ok,
       Map.merge(message, %{
         "source_ref" => SourceRef.message(options.workspace_ref, channel_ref, message_ref),
         "context_messages" => context,
         "context_coverage" => coverage,
         "thread_source_ref" =>
           if(thread_ref, do: SourceRef.thread(options.workspace_ref, channel_ref, thread_ref))
       })}
    else
      _ -> {:error, :slack_protocol_error}
    end
  rescue
    _error -> {:error, :slack_protocol_error}
  end

  defp search_message_context(message, workspace_ref) do
    case Map.fetch(message, "context_messages") do
      :error ->
        {:ok, %{"before" => [], "after" => []}, %{"status" => "unavailable"}}

      {:ok, %{"before" => before_messages, "after" => after_messages}}
      when is_list(before_messages) and is_list(after_messages) ->
        normalize_search_context(before_messages ++ after_messages, message, workspace_ref)

      _ ->
        {:error, :slack_protocol_error}
    end
  end

  defp normalize_search_context(messages, anchor, workspace_ref) do
    with true <- Enum.all?(messages, &same_context_identity?(&1, anchor, workspace_ref)),
         {:ok, messages} <-
           SourceReader.decorate_source_messages(messages, workspace_ref, anchor["channel_id"]) do
      originals =
        messages
        |> Enum.uniq_by(& &1["source_ref"])
        |> Enum.reject(&(&1["ts"] == anchor["message_ts"]))
        |> Enum.sort_by(&Arguments.timestamp_value(&1["ts"]))

      {before_messages, after_messages} =
        Enum.split_while(
          originals,
          &(Arguments.timestamp_value(&1["ts"]) < Arguments.timestamp_value(anchor["message_ts"]))
        )

      selected = Enum.take(before_messages, -2) ++ Enum.take(after_messages, 2)

      truncated =
        length(selected) < length(originals) or
          Enum.any?(selected, &(byte_size(&1["text"]) > 4_096))

      context = %{
        "before" => before_messages |> Enum.take(-2) |> Enum.map(&compact_context_message/1),
        "after" => after_messages |> Enum.take(2) |> Enum.map(&compact_context_message/1)
      }

      {:ok, context,
       %{
         "status" => "partial",
         "basis" => "provider_selected",
         "truncated" => truncated,
         "neighbor_limit" => 2
       }}
    else
      _ -> {:error, :slack_protocol_error}
    end
  end

  defp same_context_identity?(%{"text" => text} = message, anchor, workspace_ref)
       when is_binary(text) do
    Map.get(message, "channel_id", anchor["channel_id"]) == anchor["channel_id"] and
      Map.get(message, "team_id", workspace_ref) == workspace_ref and
      (is_nil(anchor["thread_ts"]) or
         Map.get(message, "thread_ts", anchor["thread_ts"]) == anchor["thread_ts"])
  end

  defp same_context_identity?(_message, _anchor, _workspace_ref), do: false

  defp compact_context_message(message) do
    # Search carries a small original excerpt, never arbitrary nested provider context.
    message
    |> Map.take(~w(source_ref text ts thread_ts user user_id))
    |> Map.put("text", String.byte_slice(message["text"], 0, 4_096))
    |> Map.put("text_truncated", byte_size(message["text"]) > 4_096)
  end

  defp authorize_search_file(%{"file_id" => file_ref} = result, options)
       when is_binary(file_ref) do
    with {:ok, %{"id" => ^file_ref} = file} <- options.api.file_info(options.client, file_ref),
         {:ok, channel_ref} <- first_public_file_channel(file, options) do
      authorize_search_file_channel(result, options, channel_ref, file)
    else
      {:ok, _crossed_file} -> {:error, :slack_protocol_error}
      {:error, _reason} = error -> error
    end
  end

  defp authorize_search_file(_invalid, _options), do: {:error, :slack_protocol_error}

  defp authorize_search_file_channel(_result, _options, nil, _file), do: {:ok, nil}

  defp authorize_search_file_channel(result, options, channel_ref, file) do
    source = %{
      workspace_ref: options.workspace_ref,
      channel_ref: channel_ref,
      kind: :file,
      resource_ref: file["id"]
    }

    with {:ok, document} <- Resources.file_document(file, source) do
      {:ok,
       result
       |> Map.merge(Map.drop(document, ["content", "content_complete"]))
       |> Map.put("channel_id", channel_ref)
       |> Map.put("source_ref", SourceRef.encode(source))
       |> Map.put("source_read", %{
         "tool" => "read_slack_source",
         "arguments" => %{"source_ref" => SourceRef.encode(source), "view" => "document"}
       })}
    end
  rescue
    _error -> {:error, :slack_protocol_error}
  end

  defp authorize_search_channel(result, options) do
    with {:ok, channel_ref} <- search_result_channel_ref(result),
         {:ok, visible} <- public_search_channel(options, channel_ref) do
      authorize_search_channel_visibility(visible, result, options, channel_ref)
    end
  end

  defp authorize_search_channel_visibility(false, _result, _options, _channel_ref),
    do: {:ok, nil}

  defp authorize_search_channel_visibility(true, result, options, channel_ref) do
    {:ok,
     result
     |> Map.put("channel_id", channel_ref)
     |> Map.put("source_ref", SourceRef.channel(options.workspace_ref, channel_ref))}
  end

  defp authorize_search_values(values, authorize) do
    Enum.reduce_while(
      values,
      {:ok, []},
      &authorize_search_value(&1, &2, authorize)
    )
  end

  defp authorize_search_value(value, {:ok, authorized}, authorize) do
    case authorize.(value) do
      {:ok, nil} -> {:cont, {:ok, authorized}}
      {:ok, result} -> {:cont, {:ok, [result | authorized]}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp put_authorized_search_values({:ok, authorized}, results, key),
    do: {:ok, Map.put(results, key, Enum.reverse(authorized))}

  defp put_authorized_search_values({:error, _reason} = error, _results, _key), do: error

  defp public_search_channel(options, channel_ref) when is_binary(channel_ref) do
    with {:ok, conversation} <- options.api.conversation_info(options.client, channel_ref) do
      Authority.public_search_conversation(conversation, channel_ref)
    end
  end

  defp first_public_file_channel(%{} = file, options) do
    file
    |> Resources.file_channel_refs()
    |> Enum.reduce_while({:ok, nil}, fn channel_ref, {:ok, nil} ->
      case public_search_channel(options, channel_ref) do
        {:ok, true} -> {:halt, {:ok, channel_ref}}
        {:ok, false} -> {:cont, {:ok, nil}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp search_result_channel_ref(%{"channel_id" => channel_ref}) when is_binary(channel_ref) do
    if SourceRef.slack_id?(channel_ref),
      do: {:ok, channel_ref},
      else: {:error, :slack_protocol_error}
  end

  defp search_result_channel_ref(%{"permalink" => permalink}) when is_binary(permalink) do
    with %URI{host: host, path: path, scheme: "https"} when is_binary(host) and is_binary(path) <-
           URI.parse(permalink),
         true <- host == "slack.com" or String.ends_with?(host, ".slack.com"),
         ["", "archives", channel_ref] <- String.split(path, "/"),
         true <- SourceRef.slack_id?(channel_ref) do
      {:ok, channel_ref}
    else
      _invalid -> {:error, :slack_protocol_error}
    end
  end

  defp search_result_channel_ref(_result), do: {:error, :slack_protocol_error}
end
