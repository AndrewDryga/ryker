defmodule Ryker.Slack.CapabilityTools.ChannelListing do
  @moduledoc """
  The channels a turn may list: public joined channels plus the current
  private one, each with its configuration and, when asked, its resources.
  """

  alias Ryker.Slack.CapabilityTools.Resources
  alias Ryker.Slack.{ChannelConfiguration, SourceRef}

  @doc "The listed page reduced to what this turn may see, with its configuration facts."
  @spec filter_conversations(term(), String.t(), String.t(), map(), (String.t(), String.t() ->
                                                                       term())) ::
          {:ok, map()} | {:error, atom()}
  def filter_conversations(
        %{"conversations" => conversations, "cursor" => cursor},
        current_channel_ref,
        workspace_ref,
        filters,
        configuration
      )
      when is_list(conversations) and is_binary(cursor) do
    conversations
    |> Enum.reduce_while({:ok, []}, fn conversation, {:ok, listed} ->
      case listed_conversation(
             conversation,
             current_channel_ref,
             workspace_ref,
             filters,
             configuration
           ) do
        {:ok, nil} -> {:cont, {:ok, listed}}
        {:ok, result} -> {:cont, {:ok, [result | listed]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, listed} ->
        {:ok,
         %{
           "conversations" => Enum.reverse(listed),
           "cursor" => cursor,
           "visibility" => "public_and_current_private"
         }}

      {:error, _reason} = error ->
        error
    end
  end

  def filter_conversations(
        _response,
        _current_channel_ref,
        _workspace_ref,
        _filters,
        _configuration
      ),
      do: {:error, :slack_protocol_error}

  defp listed_conversation(
         %{
           "channel_ref" => channel_ref,
           "is_archived" => archived,
           "is_external_shared" => external,
           "is_private" => private,
           "name" => name,
           "purpose" => purpose,
           "topic" => topic
         } = conversation,
         current_channel_ref,
         workspace_ref,
         filters,
         configuration
       )
       when is_boolean(archived) and is_boolean(external) and is_boolean(private) and
              is_binary(name) and is_binary(purpose) and is_binary(topic) do
    configured = configuration.(workspace_ref, channel_ref)

    attributes = %{
      archived: archived,
      channel_ref: channel_ref,
      configured: configured,
      conversation: conversation,
      include_resources: filters.include_resources,
      name: name,
      private: private,
      purpose: purpose,
      topic: topic,
      workspace_ref: workspace_ref
    }

    allowed =
      listed_conversation_allowed?(
        external,
        private,
        current_channel_ref,
        channel_ref,
        configured,
        filters,
        [name, purpose, topic]
      )

    listed_conversation_result(allowed, attributes)
  rescue
    _error -> {:error, :slack_protocol_error}
  end

  defp listed_conversation(
         _conversation,
         _current_channel_ref,
         _workspace_ref,
         _filters,
         _configuration
       ),
       do: {:error, :slack_protocol_error}

  defp listed_conversation_allowed?(
         external,
         private,
         current_channel_ref,
         channel_ref,
         configured,
         filters,
         text
       ) do
    Enum.all?([
      not external,
      not private or channel_ref == current_channel_ref,
      not filters.configured_only or not is_nil(configured),
      query_match?(filters.query, text ++ [environment_ref(configured)])
    ])
  end

  defp listed_conversation_result(false, _attributes), do: {:ok, nil}

  defp listed_conversation_result(true, attributes) do
    {:ok,
     %{
       "configured" => not is_nil(attributes.configured),
       "configured_environment_ref" => environment_ref(attributes.configured),
       "conversation_ref" => "slack:#{attributes.workspace_ref}:#{attributes.channel_ref}",
       "is_archived" => attributes.archived,
       "kind" => if(attributes.private, do: "private_channel", else: "public_channel"),
       "name" => attributes.name,
       "purpose" => attributes.purpose,
       "source_ref" => SourceRef.channel(attributes.workspace_ref, attributes.channel_ref),
       "topic" => attributes.topic
     }
     |> maybe_resources(
       attributes.include_resources,
       attributes.workspace_ref,
       attributes.channel_ref,
       Map.get(attributes.conversation, "canvas_ref")
     )}
  end

  defp maybe_resources(conversation, false, _workspace_ref, _channel_ref, _canvas_ref),
    do: conversation

  defp maybe_resources(conversation, true, workspace_ref, channel_ref, canvas_ref) do
    resources =
      case canvas_ref do
        value when is_binary(value) ->
          try do
            [
              %{
                "kind" => "canvas",
                "source_ref" => SourceRef.canvas(workspace_ref, channel_ref, value)
              }
            ]
          rescue
            _error -> []
          end

        _value ->
          []
      end

    Map.merge(conversation, %{
      "resources" => resources,
      "resources_complete" => false,
      "resources_unavailable" => ["pins"]
    })
  end

  @spec hydrate_resources(map(), boolean(), map()) :: {:ok, map()} | {:error, atom()}
  def hydrate_resources(listed, false, _options), do: {:ok, listed}

  def hydrate_resources(%{"conversations" => conversations} = listed, true, options)
      when is_list(conversations) do
    conversations
    |> Enum.reduce_while({:ok, []}, fn conversation, {:ok, hydrated} ->
      with {:ok, %{channel_ref: channel_ref}} <-
             SourceRef.parse(conversation["source_ref"], options.workspace_ref),
           {:ok, bookmarks} <- options.api.list_bookmarks(options.client, channel_ref),
           {:ok, bookmarks} <-
             Resources.normalize_bookmarks(bookmarks, options.workspace_ref, channel_ref) do
        conversation =
          Map.update!(conversation, "resources", &(bookmarks ++ &1))

        {:cont, {:ok, [conversation | hydrated]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, hydrated} -> {:ok, %{listed | "conversations" => Enum.reverse(hydrated)}}
      {:error, _reason} = error -> error
    end
  end

  def hydrate_resources(_listed, true, _options), do: {:error, :slack_protocol_error}

  # A configured channel selects an environment, or none.
  defp environment_ref(%ChannelConfiguration{environment_ref: environment_ref})
       when is_binary(environment_ref),
       do: environment_ref

  defp environment_ref(_configuration), do: nil

  defp query_match?(nil, _values), do: true

  defp query_match?(query, values) do
    query = String.downcase(query)

    Enum.any?(values, fn
      value when is_binary(value) -> String.contains?(String.downcase(value), query)
      _value -> false
    end)
  end
end
