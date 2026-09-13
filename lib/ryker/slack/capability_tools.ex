defmodule Ryker.Slack.CapabilityTools do
  @moduledoc """
  Turn-bound Slack source capabilities exposed beside Ryker's fixed tools.

  The model receives no Slack credential. Workspace search checks out the
  triggering event's process-local action token and Slack remains the final
  visibility authority for every result.
  """

  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.Delivery.PlatformActionCustody
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Repo
  alias Ryker.Slack.{ChannelConfigurations, SourceAudits, SourceRef, SourceWindow}
  alias Ryker.State.Records
  alias Ryker.Work.Turn

  @content_types ~w(messages files channels users)
  @search_fields ~w(after author_ref before content_types conversation_refs cursor limit query)
  @list_fields ~w(configured_only cursor include_archived include_resources kinds limit query)
  @read_fields ~w(after anchor_ref before cursor limit source_ref view)
  @reaction_fields ~w(action emoji message_ref)
  @post_fields ~w(destination_ref instruction_ref message)
  @search_expansions 2
  @emoji_name ~r/\A[a-z0-9_+\-]{1,100}\z/

  @spec list(map() | keyword()) :: [map()]
  def list(options) do
    _validated = options!(options)

    definitions()
  end

  @doc false
  @spec definitions() :: [map()]
  def definitions do
    [
      %{
        "description" =>
          "List Slack channels visible to this turn. Public joined channels are available; private access is limited to the current exact channel.",
        "inputSchema" => %{
          "additionalProperties" => false,
          "properties" => %{
            "configured_only" => %{"type" => "boolean"},
            "cursor" => nullable_string("Optional server cursor from the prior list call."),
            "include_archived" => %{"type" => "boolean"},
            "include_resources" => %{"type" => "boolean"},
            "kinds" => %{
              "items" => %{
                "enum" => ["public_channel", "private_channel"],
                "type" => "string"
              },
              "maxItems" => 2,
              "minItems" => 1,
              "type" => "array",
              "uniqueItems" => true
            },
            "limit" => %{"maximum" => 200, "minimum" => 1, "type" => "integer"},
            "query" =>
              nullable_string("Optional channel name, topic, purpose, or repository filter.")
          },
          "type" => "object"
        },
        "name" => "list_slack_channels"
      },
      %{
        "description" =>
          "Search authorized Slack workspace context for the current user-initiated turn. Results are ephemeral; call read_slack_source before citing an important result.",
        "inputSchema" => %{
          "additionalProperties" => false,
          "properties" => %{
            "after" => nullable_string("Optional RFC3339 lower time bound."),
            "author_ref" => nullable_string("Optional server-issued Slack user ref."),
            "before" => nullable_string("Optional RFC3339 upper time bound."),
            "content_types" => %{
              "items" => %{"enum" => @content_types, "type" => "string"},
              "maxItems" => 4,
              "minItems" => 1,
              "type" => "array",
              "uniqueItems" => true
            },
            "conversation_refs" => %{
              "items" => %{"maxLength" => 1_024, "minLength" => 1, "type" => "string"},
              "maxItems" => 5,
              "type" => "array",
              "uniqueItems" => true
            },
            "cursor" => nullable_string("Optional server cursor from the prior search call."),
            "limit" => %{"maximum" => 20, "minimum" => 1, "type" => "integer"},
            "query" => %{"maxLength" => 2_048, "minLength" => 1, "type" => "string"}
          },
          "required" => ["query"],
          "type" => "object"
        },
        "name" => "search_slack"
      },
      %{
        "description" =>
          "Read an exact authorized Slack original, thread, channel, file or canvas. Message reads include bounded neighbors and thread context; Work lookups also include eligible related memory. Coverage states what is missing. Follow source_read/source_reads or omitted_context for more originals; context_reference points to a body with that source_ref in the same response. Metadata stays focused.",
        "inputSchema" => %{
          "additionalProperties" => false,
          "properties" => %{
            "after" => nullable_string("Optional RFC3339 lower time bound."),
            "anchor_ref" =>
              nullable_string(
                "Exact message source within the requested thread. Omit to anchor on its root."
              ),
            "before" => nullable_string("Optional RFC3339 upper time bound."),
            "cursor" => nullable_string("Optional server cursor from the prior read call."),
            "limit" => %{"maximum" => 100, "minimum" => 1, "type" => "integer"},
            "source_ref" => %{"maxLength" => 1_024, "minLength" => 1, "type" => "string"},
            "view" => %{
              "enum" => ["surrounding", "thread", "channel", "document", "metadata"],
              "type" => "string"
            }
          },
          "required" => ["source_ref", "view"],
          "type" => "object"
        },
        "name" => "read_slack_source"
      },
      %{
        "description" =>
          "Add or remove one deliberate reaction on an exact current human Slack message. Removal is limited to a reaction previously added by Ryker.",
        "inputSchema" => %{
          "additionalProperties" => false,
          "properties" => %{
            "action" => %{"enum" => ["add", "remove"], "type" => "string"},
            "emoji" => %{
              "maxLength" => 100,
              "minLength" => 1,
              "pattern" => "^[a-z0-9_+\\-]+$",
              "type" => "string"
            },
            "message_ref" => %{
              "description" => "Exact server-issued Slack message source ref.",
              "maxLength" => 1_024,
              "minLength" => 1,
              "type" => "string"
            }
          },
          "required" => ["message_ref", "action", "emoji"],
          "type" => "object"
        },
        "name" => "set_slack_reaction"
      },
      %{
        "description" =>
          "Prepare one exact additional Slack message for human confirmation, but only for a destination granted by the exact current Slack instruction. This tool never posts directly; the episode's ordinary final reply keeps its host-owned route.",
        "inputSchema" => %{
          "additionalProperties" => false,
          "properties" => %{
            "destination_ref" => %{
              "maxLength" => 1_024,
              "minLength" => 1,
              "type" => "string"
            },
            "instruction_ref" => %{
              "maxLength" => 1_024,
              "minLength" => 1,
              "type" => "string"
            },
            "message" => %{"maxLength" => 20_000, "minLength" => 1, "type" => "string"}
          },
          "required" => ["destination_ref", "message", "instruction_ref"],
          "type" => "object"
        },
        "name" => "post_slack_message"
      }
    ]
  end

  def call("list_slack_channels", arguments, binding, options) do
    options = options!(options)

    with {:ok, current_channel_ref} <- binding(binding, options.workspace_ref),
         {:ok, document, filters} <- list_document(arguments),
         {:ok, response} <- options.api.list_conversations(options.client, document),
         {:ok, listed} <-
           filter_conversations(
             response,
             current_channel_ref,
             options.workspace_ref,
             filters,
             options.configuration
           ),
         {:ok, listed} <- hydrate_resources(listed, filters.include_resources, options),
         :ok <-
           audit_call(
             options,
             binding,
             :list_slack_channels,
             "users.conversations",
             arguments,
             nil,
             result_count(listed),
             listed["cursor"] == ""
           ) do
      {:ok, listed}
    else
      {:error, reason} -> {:error, error_code(reason)}
    end
  rescue
    _error -> {:error, "temporarily_unavailable"}
  end

  @spec call(String.t(), map(), map(), map() | keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def call("search_slack", arguments, binding, options) do
    options = options!(options)

    with {:ok, current_channel_ref} <- binding(binding, options.workspace_ref),
         {:ok, document, scoped_channel_refs} <-
           search_document(arguments, options.workspace_ref),
         {:ok, current_conversation} <-
           options.api.conversation_info(options.client, current_channel_ref),
         :ok <- search_destination_authorized(current_conversation, current_channel_ref),
         :ok <- public_search_scopes_authorized(scoped_channel_refs, options),
         {:ok, event_ref} <- options.event_ref.(binding),
         {:ok, token} <- checkout(options.action_tokens, event_ref, binding.turn.id),
         {:ok, response} <- options.api.search_context(options.client, token, document),
         {:ok, decorated} <- authorize_search_response(response, options),
         {:ok, decorated} <- expand_search_context(decorated, arguments, binding, options),
         :ok <-
           audit_call(
             options,
             binding,
             :search_slack,
             "assistant.search.context",
             arguments,
             nil,
             result_count(decorated),
             search_complete?(decorated)
           ) do
      {:ok, decorated}
    else
      {:error, reason} -> {:error, error_code(reason)}
    end
  rescue
    _error -> {:error, "temporarily_unavailable"}
  end

  def call("read_slack_source", arguments, binding, options) do
    options = options!(options)

    with {:ok, current_channel_ref} <- binding(binding, options.workspace_ref),
         {:ok, source, view, document} <- read_document(arguments, options.workspace_ref),
         {:ok, conversation} <-
           options.api.conversation_info(options.client, source.channel_ref),
         :ok <- source_authorized(conversation, source, current_channel_ref),
         {:ok, result} <- read_source(options, source, view, document, conversation, binding),
         :ok <-
           audit_call(
             options,
             binding,
             :read_slack_source,
             source_capability(source, view),
             arguments,
             source_ref(source),
             result_count(result),
             result["complete"]
           ) do
      {:ok, result}
    else
      {:error, reason} -> {:error, error_code(reason)}
    end
  rescue
    _error -> {:error, "temporarily_unavailable"}
  end

  def call("set_slack_reaction", arguments, binding, options) do
    options = options!(options)

    with {:ok, _current_channel_ref} <- binding(binding, options.workspace_ref),
         {:ok, source, action, emoji_name} <- reaction_document(arguments, options.workspace_ref),
         {:ok, input} <- options.current_input.(binding, source),
         :ok <- removal_authorized(action, binding, source, emoji_name, options),
         {:ok, %{action: frozen}} <-
           options.enqueue_action.(
             binding,
             reaction_attributes(input, source, action, emoji_name)
           ) do
      {:ok, %{"action_ref" => frozen.action_ref, "status" => Atom.to_string(frozen.status)}}
    else
      {:error, reason} -> {:error, error_code(reason)}
    end
  rescue
    _error -> {:error, "temporarily_unavailable"}
  end

  def call("post_slack_message", arguments, binding, options) do
    options = options!(options)

    with {:ok, current_channel_ref} <- binding(binding, options.workspace_ref),
         {:ok, destination, instruction, message} <-
           post_document(arguments, options.workspace_ref),
         destination_ref = source_ref(destination),
         {:ok, instruction_authority} <-
           options.current_instruction.(binding, instruction, destination_ref),
         {:ok, conversation} <-
           options.api.conversation_info(options.client, destination.channel_ref),
         :ok <- post_destination_authorized(conversation, destination, current_channel_ref),
         payload <-
           post_offer_payload(destination, instruction, message, instruction_authority.actor_ref),
         {:ok, record} <- options.propose_post.(binding, payload) do
      {:ok,
       %{
         "kind" => "slack_post_offer",
         "record_ref" => record.ref,
         "status" => Atom.to_string(record.status)
       }}
    else
      {:error, reason} -> {:error, error_code(reason)}
    end
  rescue
    _error -> {:error, "temporarily_unavailable"}
  end

  def call(_name, _arguments, _binding, _options), do: {:error, "unknown_tool"}

  @doc false
  @spec options!(map() | keyword()) :: map()
  def options!(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options),
      do: options |> Map.new() |> options!(),
      else: raise(ArgumentError, "Slack capability-tool options are invalid")
  end

  def options!(%{} = options) do
    allowed = [
      :action_tokens,
      :api,
      :audit,
      :client,
      :configuration,
      :current_input,
      :current_instruction,
      :enqueue_action,
      :event_ref,
      :propose_post,
      :reaction_added,
      :requester_ref,
      :workspace_ref
    ]

    required = [:action_tokens, :api, :client, :workspace_ref]

    unless valid_option_fields?(options, allowed, required),
      do: raise(ArgumentError, "Slack capability-tool options are invalid")

    api = options.api
    action_tokens = options.action_tokens
    event_ref = Map.get(options, :event_ref, &current_event_ref/1)
    audit = Map.get(options, :audit, &SourceAudits.record/1)
    requester_ref = Map.get(options, :requester_ref, &current_requester_ref/1)
    current_input = Map.get(options, :current_input, &current_slack_input/2)
    current_instruction = Map.get(options, :current_instruction, &current_slack_instruction/3)
    enqueue_action = Map.get(options, :enqueue_action, &PlatformActionCustody.enqueue/2)
    propose_post = Map.get(options, :propose_post, &propose_slack_post/2)

    reaction_added =
      Map.get(options, :reaction_added, &PlatformActionCustody.delivered_reaction_added?/4)

    configuration =
      Map.get(options, :configuration, &ChannelConfigurations.configuration/2)

    callbacks = %{
      audit: audit,
      configuration: configuration,
      current_input: current_input,
      current_instruction: current_instruction,
      enqueue_action: enqueue_action,
      event_ref: event_ref,
      propose_post: propose_post,
      reaction_added: reaction_added,
      requester_ref: requester_ref
    }

    unless valid_authority?(api, action_tokens, callbacks, options.workspace_ref),
      do: raise(ArgumentError, "Slack capability-tool authority is invalid")

    options
    |> Map.put(:audit, audit)
    |> Map.put(:configuration, configuration)
    |> Map.put(:current_input, current_input)
    |> Map.put(:current_instruction, current_instruction)
    |> Map.put(:enqueue_action, enqueue_action)
    |> Map.put(:event_ref, event_ref)
    |> Map.put(:propose_post, propose_post)
    |> Map.put(:reaction_added, reaction_added)
    |> Map.put(:requester_ref, requester_ref)
  end

  def options!(_options), do: raise(ArgumentError, "Slack capability-tool options are invalid")

  defp valid_option_fields?(options, allowed, required) do
    Map.keys(options) -- allowed == [] and Enum.all?(required, &Map.has_key?(options, &1))
  end

  defp valid_authority?(api, action_tokens, callbacks, workspace_ref) do
    Enum.all?([
      module_callback?(api, :search_context, 3),
      module_callback?(api, :list_conversations, 2),
      module_callback?(api, :conversation_info, 2),
      module_callback?(api, :list_bookmarks, 2),
      module_callback?(api, :file_info, 2),
      module_callback?(api, :read_messages, 4),
      action_tokens?(action_tokens),
      is_function(callbacks.event_ref, 1),
      is_function(callbacks.audit, 1),
      is_function(callbacks.requester_ref, 1),
      is_function(callbacks.current_input, 2),
      is_function(callbacks.current_instruction, 3),
      is_function(callbacks.enqueue_action, 2),
      is_function(callbacks.propose_post, 2),
      is_function(callbacks.reaction_added, 4),
      is_function(callbacks.configuration, 2),
      slack_id?(workspace_ref)
    ])
  end

  defp search_document(%{} = arguments, workspace_ref) do
    keys = Map.keys(arguments)

    with true <-
           Enum.all?(keys, &is_binary/1) and Map.has_key?(arguments, "query") and
             keys -- @search_fields == [],
         {:ok, query} <- text(arguments["query"], 2_048),
         {:ok, content_types} <- content_types(Map.get(arguments, "content_types", ["messages"])),
         {:ok, conversations} <-
           conversations(Map.get(arguments, "conversation_refs", []), workspace_ref),
         {:ok, author} <- author(Map.get(arguments, "author_ref")),
         {:ok, after_time} <- timestamp(Map.get(arguments, "after")),
         {:ok, before_time} <- timestamp(Map.get(arguments, "before")),
         {:ok, cursor} <- optional_text(Map.get(arguments, "cursor"), 4_096),
         {:ok, limit} <- limit(Map.get(arguments, "limit", 20)),
         {:ok, query} <- bounded_query(query, conversations, author) do
      {:ok,
       %{
         "channel_types" => ["public_channel"],
         "content_types" => content_types,
         "include_context_messages" => true,
         "limit" => limit,
         "query" => query
       }
       |> put_optional("after", after_time)
       |> put_optional("before", before_time)
       |> put_optional("cursor", cursor), conversations}
    else
      false -> {:error, :invalid_arguments}
      {:error, :unauthorized} -> {:error, :unauthorized}
      {:error, _reason} -> {:error, :invalid_arguments}
    end
  end

  defp search_document(_arguments, _workspace_ref), do: {:error, :invalid_arguments}

  defp list_document(%{} = arguments) do
    keys = Map.keys(arguments)

    with true <- Enum.all?(keys, &is_binary/1) and keys -- @list_fields == [],
         {:ok, query} <- optional_text(Map.get(arguments, "query"), 256),
         {:ok, kinds} <- kinds(Map.get(arguments, "kinds", ["public_channel"])),
         {:ok, configured_only} <- boolean(Map.get(arguments, "configured_only", false)),
         {:ok, include_archived} <- boolean(Map.get(arguments, "include_archived", false)),
         {:ok, include_resources} <- boolean(Map.get(arguments, "include_resources", true)),
         {:ok, cursor} <- optional_text(Map.get(arguments, "cursor"), 4_096),
         {:ok, limit} <- channel_limit(Map.get(arguments, "limit", 50)) do
      {:ok,
       %{
         "exclude_archived" => not include_archived,
         "limit" => limit,
         "types" => kinds
       }
       |> put_optional("cursor", cursor),
       %{
         configured_only: configured_only,
         include_resources: include_resources,
         query: query
       }}
    else
      false -> {:error, :invalid_arguments}
      {:error, _reason} -> {:error, :invalid_arguments}
    end
  end

  defp list_document(_arguments), do: {:error, :invalid_arguments}

  defp read_document(%{} = arguments, workspace_ref) do
    keys = Map.keys(arguments)

    with true <- Enum.all?(keys, &is_binary/1) and keys -- @read_fields == [],
         {:ok, source_ref} <- text(Map.get(arguments, "source_ref"), 1_024),
         {:ok, source} <- SourceRef.parse(source_ref, workspace_ref),
         {:ok, view} <- source_view(Map.get(arguments, "view"), source.kind),
         {:ok, source} <- source_anchor_ref(Map.get(arguments, "anchor_ref"), source, view),
         {:ok, after_time} <- slack_timestamp(Map.get(arguments, "after")),
         {:ok, before_time} <- slack_timestamp(Map.get(arguments, "before")),
         {:ok, cursor} <- optional_text(Map.get(arguments, "cursor"), 8_192),
         {:ok, limit} <- source_limit(Map.get(arguments, "limit", 100)),
         {:ok, document} <-
           source_read_bounds(source, view, after_time, before_time, cursor, limit) do
      {:ok, source, view, document}
    else
      false -> {:error, :invalid_arguments}
      {:error, :invalid_slack_source_ref} -> {:error, :unauthorized}
      {:error, :unauthorized} -> {:error, :unauthorized}
      {:error, _reason} -> {:error, :invalid_arguments}
    end
  end

  defp read_document(_arguments, _workspace_ref), do: {:error, :invalid_arguments}

  defp source_anchor_ref(nil, source, _view), do: {:ok, source}

  defp source_anchor_ref(ref, %{kind: :thread} = source, :thread) do
    with {:ok, %{kind: :message, channel_ref: channel, message_ref: timestamp}} <-
           SourceRef.parse(ref, source.workspace_ref),
         true <-
           channel == source.channel_ref and
             timestamp_value(timestamp) >= timestamp_value(source.message_ref) do
      {:ok, Map.put(source, :anchor_message_ref, timestamp)}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp source_anchor_ref(_ref, _source, _view), do: {:error, :invalid_arguments}

  defp reaction_document(%{} = arguments, workspace_ref) do
    with true <- Map.keys(arguments) |> Enum.sort() == @reaction_fields,
         {:ok, source_ref} <- text(arguments["message_ref"], 1_024),
         {:ok, %{kind: :message} = source} <- SourceRef.parse(source_ref, workspace_ref),
         action when action in ["add", "remove"] <- arguments["action"],
         emoji_name when is_binary(emoji_name) <- arguments["emoji"],
         true <- Regex.match?(@emoji_name, emoji_name) do
      {:ok, source, action, emoji_name}
    else
      {:error, :invalid_slack_source_ref} -> {:error, :unauthorized}
      _invalid -> {:error, :invalid_arguments}
    end
  end

  defp reaction_document(_arguments, _workspace_ref), do: {:error, :invalid_arguments}

  defp post_document(%{} = arguments, workspace_ref) do
    with true <- Map.keys(arguments) |> Enum.sort() == @post_fields,
         {:ok, destination_ref} <- text(arguments["destination_ref"], 1_024),
         {:ok, destination} <- SourceRef.parse(destination_ref, workspace_ref),
         true <- destination.kind in [:channel, :thread],
         {:ok, instruction_ref} <- text(arguments["instruction_ref"], 1_024),
         {:ok, %{kind: :message} = instruction} <-
           SourceRef.parse(instruction_ref, workspace_ref),
         {:ok, message} <- text(arguments["message"], 20_000) do
      {:ok, destination, instruction, message}
    else
      {:error, :invalid_slack_source_ref} -> {:error, :unauthorized}
      _invalid -> {:error, :invalid_arguments}
    end
  end

  defp post_document(_arguments, _workspace_ref), do: {:error, :invalid_arguments}

  defp reaction_attributes(input, source, action, emoji_name) do
    %{
      conversation_ref: input["destination"]["conversation_ref"],
      document: %{"action" => action, "emoji_name" => emoji_name},
      host_slot: "reaction",
      kind: :reaction,
      source_item_ref: source.message_ref,
      thread_ref: input["destination"]["thread_ref"],
      tool: :set_slack_reaction,
      transport: "slack"
    }
  end

  defp removal_authorized("add", _binding, _source, _emoji_name, _options), do: :ok

  defp removal_authorized("remove", binding, source, emoji_name, options) do
    conversation_ref = "slack:#{source.workspace_ref}:#{source.channel_ref}"

    if options.reaction_added.(
         binding.episode.id,
         conversation_ref,
         source.message_ref,
         emoji_name
       ),
       do: :ok,
       else: {:error, :unauthorized}
  end

  defp post_destination_authorized(
         %{
           "id" => channel_ref,
           "is_archived" => archived,
           "is_ext_shared" => external,
           "is_private" => private
         } = conversation,
         %{channel_ref: channel_ref},
         current_channel_ref
       )
       when is_boolean(archived) and is_boolean(external) and is_boolean(private) do
    current = channel_ref == current_channel_ref
    joined = Map.get(conversation, "is_member", current) == true

    if not archived and not external and joined and (not private or current),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp post_destination_authorized(_conversation, _destination, _current_channel_ref),
    do: {:error, :slack_protocol_error}

  defp post_offer_payload(destination, instruction, message, actor_ref) do
    destination_ref = source_ref(destination)
    instruction_ref = source_ref(instruction)

    %{
      "conversation_ref" => "slack:#{destination.workspace_ref}:#{destination.channel_ref}",
      "destination_ref" => destination_ref,
      "instruction_ref" => instruction_ref,
      "message" => message,
      "requested_by_actor_ref" => actor_ref,
      "thread_ref" => if(destination.kind == :thread, do: destination.message_ref, else: nil),
      "transport" => "slack"
    }
  end

  defp propose_slack_post(%{state_token: state_token}, payload) when is_binary(state_token) do
    operation_id =
      "slack-post:" <>
        (payload
         |> CanonicalJSON.digest()
         |> binary_part(0, 32))

    Records.create(state_token, operation_id, "slack_post_offer", payload)
  end

  defp propose_slack_post(_binding, _payload), do: {:error, :unauthorized}

  defp source_view("metadata", _kind), do: {:ok, :metadata}
  defp source_view("channel", :channel), do: {:ok, :channel}
  defp source_view("surrounding", :message), do: {:ok, :surrounding}
  defp source_view("thread", :thread), do: {:ok, :thread}

  defp source_view("document", kind) when kind in [:bookmark, :canvas, :file],
    do: {:ok, :document}

  defp source_view(_view, _kind), do: {:error, :view}

  defp source_read_bounds(_source, :metadata, _after_time, _before_time, cursor, limit),
    do: {:ok, %{"cursor" => cursor, "inclusive" => true, "limit" => limit}}

  defp source_read_bounds(source, :surrounding, after_time, before_time, cursor, limit) do
    seconds = source.message_ref |> String.split(".", parts: 2) |> hd() |> String.to_integer()
    oldest = after_time || "#{max(seconds - 86_400, 0)}.000000"
    latest = before_time || "#{seconds + 86_400}.999999"

    if timestamp_value(oldest) <= timestamp_value(source.message_ref) and
         timestamp_value(source.message_ref) <= timestamp_value(latest) do
      {:ok,
       %{
         "cursor" => cursor,
         "inclusive" => true,
         "latest" => latest,
         "limit" => limit,
         "oldest" => oldest
       }}
    else
      {:error, :range}
    end
  end

  defp source_read_bounds(_source, _view, after_time, before_time, cursor, limit) do
    {:ok,
     %{
       "cursor" => cursor,
       "inclusive" => true,
       "latest" => before_time,
       "limit" => limit,
       "oldest" => after_time
     }}
  end

  defp timestamp_value(value) do
    [seconds, fraction] = String.split(value, ".", parts: 2)

    String.to_integer(seconds) * 1_000_000 +
      String.to_integer(String.pad_trailing(fraction, 6, "0"))
  end

  defp source_authorized(
         %{
           "id" => channel_ref,
           "is_archived" => archived,
           "is_ext_shared" => external,
           "is_private" => private
         },
         %{channel_ref: channel_ref},
         current_channel_ref
       )
       when is_boolean(archived) and is_boolean(external) and is_boolean(private) do
    if not external and (not private or channel_ref == current_channel_ref),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp source_authorized(_conversation, _source, _current_channel_ref),
    do: {:error, :slack_protocol_error}

  defp read_source(options, %{kind: :bookmark} = source, view, _document, conversation, _binding)
       when view in [:document, :metadata] do
    with {:ok, bookmarks} <- options.api.list_bookmarks(options.client, source.channel_ref),
         {:ok, bookmark} <- exact_bookmark(bookmarks, source),
         {:ok, normalized} <-
           normalize_bookmark(bookmark, source.workspace_ref, source.channel_ref) do
      read_bookmark_target(options, source, view, conversation, bookmark, normalized)
    end
  end

  defp read_source(options, %{kind: kind} = source, view, _document, conversation, _binding)
       when kind in [:canvas, :file] and view in [:document, :metadata] do
    with {:ok, file} <- options.api.file_info(options.client, source.resource_ref),
         :ok <- file_authorized(file, source),
         {:ok, document} <- file_document(file, source) do
      {:ok,
       %{
         "complete" => document["content_complete"],
         "conversation" => conversation,
         "cursor" => "",
         "document" => document,
         "source_ref" => source_ref(source),
         "view" => Atom.to_string(view)
       }}
    end
  end

  defp read_source(_options, source, :metadata, _document, conversation, _binding)
       when source.kind in [:channel, :message, :thread] do
    {:ok,
     %{
       "complete" => true,
       "conversation" => conversation,
       "cursor" => "",
       "messages" => [],
       "source_ref" => source_ref(source),
       "view" => "metadata"
     }}
  end

  defp read_source(options, source, view, document, conversation, binding) do
    thread_ref = if(view == :thread, do: source.message_ref, else: nil)

    with {:ok, document} <- open_source_cursor(document, source, view, binding),
         {:ok, anchor, root} <- source_anchor(options, source, thread_ref),
         {:ok, %{"cursor" => cursor, "messages" => messages} = page} <-
           source_page(options, source, thread_ref, document, anchor, root),
         {:ok, messages} <-
           decorate_source_messages(messages, source.workspace_ref, source.channel_ref),
         {:ok, continuation} <- seal_source_cursor(cursor, document, source, view, binding) do
      result = %{
        "anchor" => anchor,
        "thread_root" => root,
        "complete" =>
          Map.get(
            page,
            "complete",
            cursor == "" and page["has_more"] != true and page["is_limited"] != true
          ),
        "coverage" => Map.get(page, "coverage"),
        "conversation" => conversation,
        "cursor" => continuation,
        "messages" => messages,
        "source_ref" => source_ref(source),
        "view" => Atom.to_string(view)
      }

      result = Map.merge(result, Map.take(page, ["source_reads"]))
      add_thread_channel_context(options, source, document, root, result, binding)
    end
  end

  defp add_thread_channel_context(_options, %{kind: :thread}, _document, nil, result, _binding),
    do: {:ok, Map.put(result, "channel_context", %{"coverage" => %{"status" => "unavailable"}})}

  defp add_thread_channel_context(
         options,
         %{kind: :thread} = source,
         document,
         root,
         result,
         binding
       ) do
    channel_source =
      %{source | kind: :message, message_ref: root["ts"]} |> Map.delete(:anchor_message_ref)

    arguments = %{
      "source_ref" => source_ref(channel_source),
      "view" => "surrounding",
      "limit" => 4,
      "after" => source_datetime(document["oldest"]),
      "before" => source_datetime(document["latest"])
    }

    case read_document(arguments, source.workspace_ref) do
      {:ok, ^channel_source, :surrounding, channel_document} ->
        with {:ok, context} <-
               channel_window(
                 options,
                 channel_source,
                 channel_document,
                 root,
                 binding,
                 document["cursor"]
               ) do
          {:ok, Map.put(result, "channel_context", link_channel_context(context, arguments))}
        end

      {:error, _unusable_window} ->
        # The channel layer is optional context around an already authorized thread.
        {:ok, Map.put(result, "channel_context", %{"coverage" => %{"status" => "unavailable"}})}
    end
  end

  defp add_thread_channel_context(_options, _source, _document, _root, result, _binding),
    do: {:ok, result}

  defp link_channel_context(context, arguments) do
    cursor = context["cursor"]

    arguments =
      if cursor in [nil, ""],
        do: Map.put(arguments, "limit", 20),
        else: Map.put(arguments, "cursor", cursor)

    Map.put(context, "source_read", %{"tool" => "read_slack_source", "arguments" => arguments})
  end

  defp channel_window(_options, _source, _document, _root, _binding, cursor)
       when not is_nil(cursor),
       do: {:ok, %{"messages" => [], "coverage" => %{"status" => "previous_page"}}}

  defp channel_window(options, source, document, root, binding, nil) do
    read = &message_page(options, source, nil, &1)

    with {:ok, page} <- SourceWindow.read(read, source, document, root, nil),
         {:ok, messages} <-
           decorate_source_messages(page["messages"], source.workspace_ref, source.channel_ref),
         {:ok, cursor} <-
           seal_source_cursor(page["cursor"], document, source, :surrounding, binding) do
      {:ok, %{"messages" => messages, "coverage" => page["coverage"], "cursor" => cursor}}
    end
  end

  defp source_datetime(nil), do: nil

  defp source_datetime(timestamp),
    do:
      timestamp |> timestamp_value() |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()

  defp source_page(options, %{kind: :channel} = source, thread, document, _anchor, _root),
    do: message_page(options, source, thread, document)

  defp source_page(options, source, thread, document, anchor, root) do
    read = &message_page(options, source, thread, &1)
    SourceWindow.read(read, source, document, anchor, root)
  end

  defp message_page(options, source, thread, document) do
    with {:ok, page} <-
           options.api.read_messages(options.client, source.channel_ref, thread, document) do
      {:ok,
       if(is_nil(thread), do: Map.update(page, "messages", nil, &channel_originals/1), else: page)}
    end
  end

  defp channel_originals(messages) when is_list(messages),
    do: Enum.filter(messages, &channel_original?/1)

  defp channel_originals(messages), do: messages
  defp channel_original?(%{"thread_ts" => thread, "ts" => ts}), do: is_nil(thread) or thread == ts
  defp channel_original?(_message), do: true

  defp open_source_cursor(%{"cursor" => nil} = document, _source, _view, _binding),
    do: {:ok, document}

  defp open_source_cursor(document, source, view, %{cursor_secret: secret} = binding)
       when is_binary(secret) and byte_size(secret) >= 16 do
    scope = source_cursor_scope(document, source, view, binding)

    case Plug.Crypto.verify(secret, "slack-source-read", document["cursor"], max_age: 3_600) do
      {:ok, {^scope, cursor}} when is_binary(cursor) or is_map(cursor) ->
        {:ok, Map.put(document, "cursor", cursor)}

      _ ->
        {:error, :invalid_source_cursor}
    end
  end

  defp open_source_cursor(_document, _source, _view, _binding),
    do: {:error, :invalid_source_cursor}

  defp seal_source_cursor("", _document, _source, _view, _binding), do: {:ok, ""}

  defp seal_source_cursor(cursor, document, source, view, %{cursor_secret: secret} = binding)
       when is_binary(secret) and byte_size(secret) >= 16 do
    scope = source_cursor_scope(document, source, view, binding)
    {:ok, Plug.Crypto.sign(secret, "slack-source-read", {scope, cursor}, max_age: 3_600)}
  end

  defp seal_source_cursor(_cursor, _document, _source, _view, _binding),
    do: {:error, :invalid_source_cursor}

  defp source_cursor_scope(document, source, view, binding),
    do:
      {source_ref(source), Map.get(source, :anchor_message_ref), view,
       Map.delete(document, "cursor"), binding.episode.id, binding.turn.id}

  defp decorate_source_messages(messages, workspace_ref, channel_ref) when is_list(messages) do
    Enum.reduce_while(messages, {:ok, []}, fn
      %{"ts" => message_ref} = message, {:ok, decorated} when is_binary(message_ref) ->
        try do
          ref = SourceRef.message(workspace_ref, channel_ref, message_ref)
          {:cont, {:ok, [Map.put(message, "source_ref", ref) | decorated]}}
        rescue
          _error -> {:halt, {:error, :slack_protocol_error}}
        end

      _invalid, _result ->
        {:halt, {:error, :slack_protocol_error}}
    end)
    |> case do
      {:ok, decorated} -> {:ok, Enum.reverse(decorated)}
      {:error, _reason} = error -> error
    end
  end

  defp decorate_source_messages(_messages, _workspace_ref, _channel_ref),
    do: {:error, :slack_protocol_error}

  defp source_anchor(_options, %{kind: :channel}, _thread_ref), do: {:ok, nil, nil}

  defp source_anchor(options, source, thread_ref) do
    # Page contents are not source identity. Recheck the exact original on every
    # page, including a continuation that no longer contains the anchor.
    timestamp = Map.get(source, :anchor_message_ref, source.message_ref)

    with {:ok, originals} <- exact_source_originals(options, source, thread_ref, timestamp),
         {:ok, anchor} <- required_original(originals, timestamp),
         {:ok, root} <- source_root(options, source, thread_ref, originals),
         do: {:ok, anchor, root}
  end

  defp required_original(originals, timestamp) do
    case Enum.find(originals, &(&1["ts"] == timestamp)) do
      nil -> {:error, :slack_source_not_found}
      original -> {:ok, original}
    end
  end

  defp source_root(_options, _source, nil, _originals), do: {:ok, nil}

  defp source_root(options, source, thread_ref, originals) do
    case Enum.find(originals, &(&1["ts"] == thread_ref)) do
      nil ->
        with {:ok, roots} <- exact_source_originals(options, source, thread_ref, thread_ref),
             do: {:ok, Enum.find(roots, &(&1["ts"] == thread_ref))}

      root ->
        {:ok, root}
    end
  end

  defp exact_source_originals(options, source, thread_ref, timestamp) do
    document = %{
      "oldest" => timestamp,
      "latest" => timestamp,
      "inclusive" => true,
      "limit" => 1
    }

    with {:ok, %{"messages" => messages}} <-
           options.api.read_messages(options.client, source.channel_ref, thread_ref, document),
         do: decorate_source_messages(messages, source.workspace_ref, source.channel_ref)
  end

  defp source_ref(%{kind: :channel, workspace_ref: workspace_ref, channel_ref: channel_ref}),
    do: SourceRef.channel(workspace_ref, channel_ref)

  defp source_ref(%{
         kind: :message,
         workspace_ref: workspace_ref,
         channel_ref: channel_ref,
         message_ref: message_ref
       }),
       do: SourceRef.message(workspace_ref, channel_ref, message_ref)

  defp source_ref(%{
         kind: :thread,
         workspace_ref: workspace_ref,
         channel_ref: channel_ref,
         message_ref: message_ref
       }),
       do: SourceRef.thread(workspace_ref, channel_ref, message_ref)

  defp source_ref(%{
         kind: :bookmark,
         workspace_ref: workspace_ref,
         channel_ref: channel_ref,
         resource_ref: resource_ref
       }),
       do: SourceRef.bookmark(workspace_ref, channel_ref, resource_ref)

  defp source_ref(%{
         kind: :canvas,
         workspace_ref: workspace_ref,
         channel_ref: channel_ref,
         resource_ref: resource_ref
       }),
       do: SourceRef.canvas(workspace_ref, channel_ref, resource_ref)

  defp source_ref(%{
         kind: :file,
         workspace_ref: workspace_ref,
         channel_ref: channel_ref,
         resource_ref: resource_ref
       }),
       do: SourceRef.file(workspace_ref, channel_ref, resource_ref)

  defp filter_conversations(
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

  defp filter_conversations(
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
      query_match?(filters.query, text ++ [repository_ref(configured)])
    ])
  end

  defp listed_conversation_result(false, _attributes), do: {:ok, nil}

  defp listed_conversation_result(true, attributes) do
    {:ok,
     %{
       "configured" => not is_nil(attributes.configured),
       "configured_repository_ref" => repository_ref(attributes.configured),
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

  defp hydrate_resources(listed, false, _options), do: {:ok, listed}

  defp hydrate_resources(%{"conversations" => conversations} = listed, true, options)
       when is_list(conversations) do
    conversations
    |> Enum.reduce_while({:ok, []}, fn conversation, {:ok, hydrated} ->
      with {:ok, %{channel_ref: channel_ref}} <-
             SourceRef.parse(conversation["source_ref"], options.workspace_ref),
           {:ok, bookmarks} <- options.api.list_bookmarks(options.client, channel_ref),
           {:ok, bookmarks} <-
             normalize_bookmarks(bookmarks, options.workspace_ref, channel_ref) do
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

  defp hydrate_resources(_listed, true, _options), do: {:error, :slack_protocol_error}

  defp normalize_bookmarks(bookmarks, workspace_ref, channel_ref)
       when is_list(bookmarks) and length(bookmarks) <= 100 do
    bookmarks
    |> Enum.reduce_while({:ok, []}, fn bookmark, {:ok, normalized} ->
      case normalize_bookmark(bookmark, workspace_ref, channel_ref) do
        {:ok, resource} -> {:cont, {:ok, [resource | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_bookmarks(_bookmarks, _workspace_ref, _channel_ref),
    do: {:error, :slack_protocol_error}

  defp normalize_bookmark(
         %{
           "channel_id" => channel_ref,
           "id" => bookmark_ref,
           "title" => title,
           "type" => type
         } = bookmark,
         workspace_ref,
         channel_ref
       )
       when is_binary(bookmark_ref) and is_binary(title) and is_binary(type) do
    {:ok,
     %{
       "kind" => "bookmark",
       "link" => optional_resource_text(bookmark["link"], 8_192),
       "resource_type" => type,
       "source_ref" => SourceRef.bookmark(workspace_ref, channel_ref, bookmark_ref),
       "target_source_ref" => bookmark_target(bookmark, workspace_ref, channel_ref),
       "title" => bounded_resource_text(title, 1_024)
     }
     |> drop_nil_values()}
  rescue
    _error -> {:error, :slack_protocol_error}
  end

  defp normalize_bookmark(_bookmark, _workspace_ref, _channel_ref),
    do: {:error, :slack_protocol_error}

  defp bookmark_target(%{"entity_id" => entity_ref, "type" => "file"}, workspace_ref, channel_ref)
       when is_binary(entity_ref),
       do: SourceRef.file(workspace_ref, channel_ref, entity_ref)

  defp bookmark_target(
         %{"entity_id" => entity_ref, "type" => "canvas"},
         workspace_ref,
         channel_ref
       )
       when is_binary(entity_ref),
       do: SourceRef.canvas(workspace_ref, channel_ref, entity_ref)

  defp bookmark_target(_bookmark, _workspace_ref, _channel_ref), do: nil

  defp exact_bookmark(bookmarks, source) when is_list(bookmarks) do
    case Enum.find(bookmarks, fn
           %{"channel_id" => channel_ref, "id" => bookmark_ref} ->
             channel_ref == source.channel_ref and bookmark_ref == source.resource_ref

           _bookmark ->
             false
         end) do
      %{} = bookmark -> {:ok, bookmark}
      nil -> {:error, :slack_source_not_found}
    end
  end

  defp exact_bookmark(_bookmarks, _source), do: {:error, :slack_protocol_error}

  defp read_bookmark_target(_options, source, :metadata, conversation, _bookmark, normalized) do
    {:ok,
     %{
       "bookmark" => normalized,
       "complete" => true,
       "conversation" => conversation,
       "cursor" => "",
       "source_ref" => source_ref(source),
       "view" => "metadata"
     }}
  end

  defp read_bookmark_target(
         options,
         source,
         :document,
         conversation,
         %{"entity_id" => entity_ref, "type" => type},
         normalized
       )
       when is_binary(entity_ref) and type in ["canvas", "file"] do
    kind = String.to_existing_atom(type)

    target = %{source | kind: kind, resource_ref: entity_ref}

    with {:ok, file} <- options.api.file_info(options.client, entity_ref),
         :ok <- file_authorized(file, target),
         {:ok, document} <- file_document(file, target) do
      {:ok,
       %{
         "bookmark" => normalized,
         "complete" => document["content_complete"],
         "conversation" => conversation,
         "cursor" => "",
         "document" => document,
         "source_ref" => source_ref(source),
         "view" => "document"
       }}
    end
  end

  defp read_bookmark_target(_options, source, :document, conversation, _bookmark, normalized) do
    {:ok,
     %{
       "bookmark" => normalized,
       "complete" => true,
       "conversation" => conversation,
       "cursor" => "",
       "source_ref" => source_ref(source),
       "view" => "document"
     }}
  end

  defp file_authorized(%{} = file, %{channel_ref: channel_ref, kind: kind, resource_ref: file_ref}) do
    refs = file_channel_refs(file)

    authorized =
      file["id"] == file_ref and channel_ref in refs and
        (kind != :canvas or Map.get(file, "linked_channel_id", channel_ref) == channel_ref)

    if authorized, do: :ok, else: {:error, :unauthorized}
  end

  defp file_authorized(_file, _source), do: {:error, :slack_protocol_error}

  defp file_channel_refs(file) do
    direct =
      ~w(channels groups ims mpims)
      |> Enum.flat_map(fn field ->
        case file[field] do
          values when is_list(values) -> Enum.filter(values, &is_binary/1)
          _value -> []
        end
      end)

    shared =
      case file["shares"] do
        %{} = shares ->
          shares
          |> Map.values()
          |> Enum.filter(&is_map/1)
          |> Enum.flat_map(&Map.keys/1)

        _shares ->
          []
      end

    [file["linked_channel_id"] | direct ++ shared]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp file_document(%{"id" => file_ref} = file, %{kind: kind} = source)
       when is_binary(file_ref) and kind in [:canvas, :file] do
    title = file["title"] || file["name"] || file_ref
    {content, content_complete} = file_content(file)

    try do
      {:ok,
       %{
         "content" => content,
         "content_complete" => content_complete,
         "created" => optional_nonnegative_integer(file["created"]),
         "filetype" => optional_resource_text(file["filetype"], 128),
         "kind" => Atom.to_string(kind),
         "media_type" => optional_resource_text(file["mimetype"], 128),
         "permalink" => optional_resource_text(file["permalink"], 8_192),
         "size" => optional_nonnegative_integer(file["size"]),
         "source_context" => file_source_context(file, source),
         "title" => bounded_resource_text(title, 1_024),
         "updated" => optional_nonnegative_integer(file["updated"])
       }
       |> drop_nil_values()}
    rescue
      _error -> {:error, :slack_protocol_error}
    end
  end

  defp file_document(_file, _source), do: {:error, :slack_protocol_error}

  defp file_source_context(file, source) do
    shares = file["shares"] || %{}

    originals =
      ~w(public private)
      |> Enum.flat_map(&(get_in(shares, [&1, source.channel_ref]) || []))
      |> Enum.filter(&(Map.get(&1, "team_id", source.workspace_ref) == source.workspace_ref))
      |> Enum.uniq_by(& &1["ts"])
      |> Enum.take(4)
      |> Enum.map(&file_share(&1, source))

    %{
      "channel_source_ref" => SourceRef.channel(source.workspace_ref, source.channel_ref),
      "origin" => "not_established",
      "shares" => originals,
      "coverage" => %{
        "basis" => "known_shares_in_requested_channel",
        "status" => "partial",
        "limit" => 4
      }
    }
  end

  defp file_share(share, source) do
    original =
      %{
        "source_ref" => SourceRef.message(source.workspace_ref, source.channel_ref, share["ts"]),
        "thread_source_ref" =>
          if(share["thread_ts"],
            do: SourceRef.thread(source.workspace_ref, source.channel_ref, share["thread_ts"])
          )
      }
      |> drop_nil_values()

    arguments = original |> search_expansion_arguments(%{}) |> Map.put("limit", 20)
    Map.put(original, "source_read", %{"tool" => "read_slack_source", "arguments" => arguments})
  end

  defp file_content(file) do
    value = file["plain_text"] || file["preview_plain_text"] || file["preview"]

    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..(128 * 1_024) and
         :binary.match(value, <<0>>) == :nomatch do
      {value, is_binary(file["plain_text"]) and file["preview_is_truncated"] != true}
    else
      {nil, false}
    end
  end

  defp bounded_resource_text(value, maximum) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: value,
       else: raise(ArgumentError, "invalid Slack resource text")
  end

  defp optional_resource_text(nil, _maximum), do: nil
  defp optional_resource_text(value, maximum), do: bounded_resource_text(value, maximum)

  defp optional_nonnegative_integer(nil), do: nil
  defp optional_nonnegative_integer(value) when is_integer(value) and value >= 0, do: value

  defp optional_nonnegative_integer(_value),
    do: raise(ArgumentError, "invalid Slack resource size")

  defp drop_nil_values(document),
    do: Map.reject(document, fn {_key, value} -> is_nil(value) end)

  defp repository_ref(%{repository_ref: repository_ref}) when is_binary(repository_ref),
    do: repository_ref

  defp repository_ref(_configuration), do: nil

  defp query_match?(nil, _values), do: true

  defp query_match?(query, values) do
    query = String.downcase(query)

    Enum.any?(values, fn
      value when is_binary(value) -> String.contains?(String.downcase(value), query)
      _value -> false
    end)
  end

  defp bounded_query(query, conversations, author) do
    suffix =
      Enum.map(conversations, &"in:<##{&1}>") ++
        if(author, do: ["from:<@#{author}>"], else: [])

    prepared = Enum.join([query | suffix], " ")
    if byte_size(prepared) <= 4_096, do: {:ok, prepared}, else: {:error, :query}
  end

  defp binding(
         %{
           episode: %Episode{
             destination_conversation_ref: "slack:" <> _rest = conversation_ref,
             destination_transport: "slack"
           },
           turn: %Turn{id: turn_id}
         },
         workspace_ref
       )
       when is_binary(turn_id) do
    case conversation(conversation_ref, workspace_ref) do
      {:ok, channel_ref} -> {:ok, channel_ref}
      {:error, _reason} -> {:error, :unauthorized}
    end
  end

  defp binding(_binding, _workspace_ref), do: {:error, :unauthorized}

  defp current_slack_input(%{episode: %Episode{} = episode}, source) do
    conversation_ref = "slack:#{source.workspace_ref}:#{source.channel_ref}"

    episode
    |> active_input_events()
    |> Enum.find_value({:error, :unauthorized}, fn event ->
      case event.payload do
        %{
          "payload" =>
            %{
              "actor" => %{"kind" => "user"},
              "destination" => %{
                "conversation_ref" => ^conversation_ref,
                "transport" => "slack"
              },
              "source" => %{"kind" => "slack", "ref" => workspace_ref},
              "source_capabilities" => %{"react" => _capability},
              "source_item_ref" => message_ref
            } = input
        }
        when workspace_ref == source.workspace_ref and message_ref == source.message_ref ->
          {:ok, input}

        _other ->
          nil
      end
    end)
  end

  defp current_slack_input(_binding, _source), do: {:error, :unauthorized}

  @doc false
  @spec authorized_post_instruction?(map(), String.t()) :: boolean()
  def authorized_post_instruction?(
        %{
          "source_capabilities" => %{
            "post_slack_message" => %{"destination_refs" => destination_refs}
          }
        },
        destination_ref
      )
      when is_list(destination_refs) and is_binary(destination_ref) do
    destination_ref in destination_refs
  end

  def authorized_post_instruction?(_input, _destination_ref), do: false

  defp current_slack_instruction(%{episode: %Episode{} = episode}, source, destination_ref) do
    conversation_ref = "slack:#{source.workspace_ref}:#{source.channel_ref}"

    episode
    |> active_input_events()
    |> Enum.find_value(
      {:error, :unauthorized},
      &post_instruction_authority(&1, source, conversation_ref, destination_ref)
    )
  end

  defp current_slack_instruction(_binding, _source, _destination_ref),
    do: {:error, :unauthorized}

  defp post_instruction_authority(
         %{
           payload: %{
             "actor_ref" => "slack:user:" <> _user_ref = actor_ref,
             "payload" =>
               %{
                 "actor" => %{"kind" => "user"},
                 "destination" => %{
                   "conversation_ref" => conversation_ref,
                   "transport" => "slack"
                 },
                 "source" => %{"kind" => "slack", "ref" => workspace_ref},
                 "source_item_ref" => message_ref
               } = input
           }
         },
         %{workspace_ref: workspace_ref, message_ref: message_ref},
         conversation_ref,
         destination_ref
       ) do
    if authorized_post_instruction?(input, destination_ref),
      do: {:ok, %{actor_ref: actor_ref}},
      else: nil
  end

  defp post_instruction_authority(_event, _source, _conversation_ref, _destination_ref),
    do: nil

  defp current_event_ref(%{episode: %Episode{} = episode}) do
    episode
    |> active_input_events()
    |> Enum.find_value({:error, :slack_action_token_unavailable}, fn event ->
      input = get_in(event.payload, ["payload"])

      if get_in(input, ["source", "kind"]) == "slack" and is_binary(input["event_ref"]),
        do: {:ok, input["event_ref"]}
    end)
  end

  defp current_event_ref(_binding), do: {:error, :slack_action_token_unavailable}

  defp current_requester_ref(%{episode: %Episode{} = episode}) do
    episode
    |> active_input_events()
    |> Enum.find_value({:error, :slack_requester_unavailable}, fn event ->
      case event.payload do
        # Attribution is not authorization: channel visibility was checked
        # before this audit. Retain the host-admitted actor, including durable
        # system wakeups; never invent a human requester for automated work.
        %{"actor_ref" => actor_ref} when is_binary(actor_ref) and byte_size(actor_ref) > 0 ->
          {:ok, actor_ref}

        _payload ->
          nil
      end
    end)
  end

  defp current_requester_ref(_binding), do: {:error, :slack_requester_unavailable}

  defp active_input_events(%Episode{id: episode_id, active_input_refs: refs}) do
    refs = Enum.uniq(refs)

    if refs == [] do
      []
    else
      Repo.all(
        from(event in Event,
          where:
            event.episode_id == ^episode_id and event.kind == :input_admitted and
              event.dedupe_key in ^refs,
          order_by: [desc: event.sequence]
        )
      )
    end
  end

  defp audit_call(
         options,
         binding,
         tool,
         capability,
         request,
         source_ref,
         result_count,
         complete
       ) do
    with {:ok, requester_ref} <- options.requester_ref.(binding) do
      options.audit.(%{
        authorized: true,
        capability: capability,
        channel_ref: source_channel_ref(source_ref, options.workspace_ref),
        complete: complete,
        episode_id: binding.episode.id,
        range: Map.take(request, ~w(after before cursor limit view)),
        request: request,
        requester_ref: requester_ref,
        result_count: result_count,
        source_ref: source_ref,
        tool: tool,
        turn_id: binding.turn.id,
        workspace_ref: options.workspace_ref
      })
    end
  end

  defp source_channel_ref(nil, _workspace_ref), do: nil

  defp source_channel_ref(source_ref, workspace_ref) do
    case SourceRef.parse(source_ref, workspace_ref) do
      {:ok, source} -> source.channel_ref
      {:error, _reason} -> nil
    end
  end

  defp result_count(%{"conversations" => conversations}) when is_list(conversations),
    do: length(conversations)

  defp result_count(%{"messages" => messages} = result) when is_list(messages) do
    [
      result["anchor"],
      result["thread_root"] | messages ++ (get_in(result, ["channel_context", "messages"]) || [])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1["source_ref"])
    |> length()
  end

  defp result_count(%{"bookmark" => bookmark}) when is_map(bookmark), do: 1
  defp result_count(%{"document" => document}) when is_map(document), do: 1

  defp result_count(%{"results" => results}) when is_map(results) do
    Enum.reduce(results, 0, fn
      {_key, values}, count when is_list(values) -> count + length(values)
      {_key, _value}, count -> count
    end)
  end

  defp result_count(_result), do: 0

  defp search_complete?(response),
    do: response["complete"] != false and Map.get(response, "next_cursor") in [nil, ""]

  defp expand_search_context(
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

  defp expand_search_context(response, _arguments, _binding, _options), do: {:ok, response}

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
    read = search_expansion_arguments(hit, arguments)
    hit = Map.put(hit, "source_read", %{"tool" => "read_slack_source", "arguments" => read})

    cond do
      hit["context_coverage"]["status"] != "unavailable" -> {:ok, hit, remaining}
      remaining == 0 -> {:ok, put_in(hit, ["context_coverage", "reason"], "expansion_budget"), 0}
      true -> expand_search_original(hit, read, binding, options, remaining - 1)
    end
  end

  defp search_expansion_arguments(hit, arguments) do
    base = %{
      "source_ref" => hit["source_ref"],
      "view" => "surrounding",
      "limit" => 4,
      "after" => arguments["after"],
      "before" => arguments["before"]
    }

    if hit["thread_source_ref"],
      do:
        Map.merge(base, %{
          "source_ref" => hit["thread_source_ref"],
          "view" => "thread",
          "anchor_ref" => hit["source_ref"]
        }),
      else: base
  end

  defp expand_search_original(hit, read, binding, options, remaining) do
    with {:ok, source, view, document} <- read_document(read, options.workspace_ref),
         thread = if(view == :thread, do: source.message_ref),
         {:ok, anchor, root} <- source_anchor(options, source, thread),
         {:ok, page} <- source_page(options, source, thread, document, anchor, root),
         {:ok, messages} <-
           decorate_source_messages(page["messages"], source.workspace_ref, source.channel_ref),
         {:ok, cursor} <- seal_source_cursor(page["cursor"], document, source, view, binding) do
      {before, after_messages} =
        Enum.split_with(messages, &(timestamp_value(&1["ts"]) < timestamp_value(anchor["ts"])))

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

  defp source_capability(%{kind: :bookmark}, _view), do: "bookmarks.list"
  defp source_capability(%{kind: kind}, _view) when kind in [:canvas, :file], do: "files.info"
  defp source_capability(_source, :metadata), do: "conversations.info"
  defp source_capability(_source, :thread), do: "conversations.replies"
  defp source_capability(_source, _view), do: "conversations.history"

  defp checkout({module, server}, event_ref, turn_id),
    do: module.checkout(server, event_ref, turn_id)

  defp search_destination_authorized(
         %{
           "id" => channel_ref,
           "is_archived" => archived,
           "is_ext_shared" => external,
           "is_private" => private
         },
         channel_ref
       )
       when is_boolean(archived) and is_boolean(external) and is_boolean(private) do
    if not archived and not external, do: :ok, else: {:error, :unauthorized}
  end

  defp search_destination_authorized(_conversation, _channel_ref),
    do: {:error, :slack_protocol_error}

  defp public_search_scopes_authorized(channel_refs, options) when is_list(channel_refs) do
    Enum.reduce_while(channel_refs, :ok, fn channel_ref, :ok ->
      case public_search_channel(options, channel_ref) do
        {:ok, true} -> {:cont, :ok}
        {:ok, false} -> {:halt, {:error, :unauthorized}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp authorize_search_response(%{"results" => %{} = results} = response, options) do
    if Map.keys(results) -- @content_types == [] do
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

  defp authorize_search_response(_response, _options), do: {:error, :slack_protocol_error}

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

        if slack_id?(user_ref) and team_ref == options.workspace_ref do
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
           decorate_source_messages(messages, workspace_ref, anchor["channel_id"]) do
      originals =
        messages
        |> Enum.uniq_by(& &1["source_ref"])
        |> Enum.reject(&(&1["ts"] == anchor["message_ts"]))
        |> Enum.sort_by(&timestamp_value(&1["ts"]))

      {before_messages, after_messages} =
        Enum.split_while(
          originals,
          &(timestamp_value(&1["ts"]) < timestamp_value(anchor["message_ts"]))
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

    with {:ok, document} <- file_document(file, source) do
      {:ok,
       result
       |> Map.merge(Map.drop(document, ["content", "content_complete"]))
       |> Map.put("channel_id", channel_ref)
       |> Map.put("source_ref", source_ref(source))
       |> Map.put("source_read", %{
         "tool" => "read_slack_source",
         "arguments" => %{"source_ref" => source_ref(source), "view" => "document"}
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
      public_search_conversation(conversation, channel_ref)
    end
  end

  defp public_search_conversation(
         %{
           "id" => channel_ref,
           "is_archived" => archived,
           "is_ext_shared" => external,
           "is_private" => private
         },
         channel_ref
       )
       when is_boolean(archived) and is_boolean(external) and is_boolean(private),
       do: {:ok, not archived and not external and not private}

  defp public_search_conversation(_conversation, _channel_ref),
    do: {:error, :slack_protocol_error}

  defp first_public_file_channel(%{} = file, options) do
    file
    |> file_channel_refs()
    |> Enum.reduce_while({:ok, nil}, fn channel_ref, {:ok, nil} ->
      case public_search_channel(options, channel_ref) do
        {:ok, true} -> {:halt, {:ok, channel_ref}}
        {:ok, false} -> {:cont, {:ok, nil}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp search_result_channel_ref(%{"channel_id" => channel_ref}) when is_binary(channel_ref) do
    if slack_id?(channel_ref), do: {:ok, channel_ref}, else: {:error, :slack_protocol_error}
  end

  defp search_result_channel_ref(%{"permalink" => permalink}) when is_binary(permalink) do
    with %URI{host: host, path: path, scheme: "https"} when is_binary(host) and is_binary(path) <-
           URI.parse(permalink),
         true <- host == "slack.com" or String.ends_with?(host, ".slack.com"),
         ["", "archives", channel_ref] <- String.split(path, "/"),
         true <- slack_id?(channel_ref) do
      {:ok, channel_ref}
    else
      _invalid -> {:error, :slack_protocol_error}
    end
  end

  defp search_result_channel_ref(_result), do: {:error, :slack_protocol_error}

  defp conversations(values, workspace_ref)
       when is_list(values) and length(values) <= 5 do
    if values == Enum.uniq(values) do
      Enum.reduce_while(values, {:ok, []}, fn value, {:ok, channels} ->
        reduce_conversation(value, workspace_ref, channels)
      end)
    else
      {:error, :conversation}
    end
  end

  defp conversations(_values, _workspace_ref), do: {:error, :conversation}

  defp reduce_conversation(value, workspace_ref, channels) do
    case conversation(value, workspace_ref) do
      {:ok, channel_ref} -> {:cont, {:ok, channels ++ [channel_ref]}}
      {:error, :unauthorized} -> {:halt, {:error, :unauthorized}}
      {:error, _reason} -> {:halt, {:error, :conversation}}
    end
  end

  defp conversation(value, workspace_ref) do
    case String.split(value || "", ":", parts: 3) do
      ["slack", ^workspace_ref, channel_ref] ->
        if slack_id?(channel_ref), do: {:ok, channel_ref}, else: {:error, :conversation}

      _invalid ->
        {:error, :unauthorized}
    end
  end

  defp author(nil), do: {:ok, nil}

  defp author("slack-user:" <> user_ref) do
    if slack_id?(user_ref), do: {:ok, user_ref}, else: {:error, :author}
  end

  defp author(_value), do: {:error, :author}

  defp content_types(values) when is_list(values) and length(values) in 1..4 do
    if values == Enum.uniq(values) and Enum.all?(values, &(&1 in @content_types)),
      do: {:ok, values},
      else: {:error, :content_types}
  end

  defp content_types(_values), do: {:error, :content_types}

  defp timestamp(nil), do: {:ok, nil}

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, DateTime.to_unix(datetime)}
      _invalid -> {:error, :timestamp}
    end
  end

  defp timestamp(_value), do: {:error, :timestamp}

  defp slack_timestamp(nil), do: {:ok, nil}

  defp slack_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, "#{DateTime.to_unix(datetime)}.000000"}
      _invalid -> {:error, :timestamp}
    end
  end

  defp slack_timestamp(_value), do: {:error, :timestamp}

  defp optional_text(nil, _maximum), do: {:ok, nil}
  defp optional_text(value, maximum), do: text(value, maximum)

  defp text(value, maximum) do
    if is_binary(value) and String.valid?(value) and String.trim(value) != "" and
         byte_size(value) <= maximum and :binary.match(value, <<0>>) == :nomatch,
       do: {:ok, value},
       else: {:error, :text}
  end

  defp boolean(value) when is_boolean(value), do: {:ok, value}
  defp boolean(_value), do: {:error, :boolean}

  defp limit(value) when is_integer(value) and value in 1..20, do: {:ok, value}
  defp limit(_value), do: {:error, :limit}

  defp channel_limit(value) when is_integer(value) and value in 1..200, do: {:ok, value}
  defp channel_limit(_value), do: {:error, :limit}

  defp source_limit(value) when is_integer(value) and value in 1..100, do: {:ok, value}
  defp source_limit(_value), do: {:error, :limit}

  defp kinds(values) when is_list(values) and length(values) in 1..2 do
    allowed = ["public_channel", "private_channel"]

    if values == Enum.uniq(values) and Enum.all?(values, &(&1 in allowed)),
      do: {:ok, values},
      else: {:error, :kinds}
  end

  defp kinds(_values), do: {:error, :kinds}

  defp nullable_string(description) do
    %{
      "anyOf" => [
        %{"type" => "null"},
        %{"maxLength" => 4_096, "minLength" => 1, "type" => "string"}
      ],
      "description" => description
    }
  end

  defp put_optional(document, _key, nil), do: document
  defp put_optional(document, key, value), do: Map.put(document, key, value)

  defp action_tokens?({module, _server}), do: module_callback?(module, :checkout, 3)
  defp action_tokens?(_value), do: false

  defp module_callback?(module, function, arity),
    do:
      is_atom(module) and Code.ensure_loaded?(module) and
        function_exported?(module, function, arity)

  defp slack_id?(value),
    do: is_binary(value) and Regex.match?(~r/\A[A-Z0-9]+\z/, value)

  defp error_code(:invalid_arguments), do: "invalid_arguments"
  defp error_code(:invalid_source_cursor), do: "invalid_source_cursor"
  defp error_code(:unauthorized), do: "unauthorized"
  defp error_code(:slack_action_token_not_authorized), do: "unauthorized"
  defp error_code(:slack_search_budget_exhausted), do: "search_budget_exhausted"
  defp error_code(:slack_source_not_found), do: "not_found"
  defp error_code(_reason), do: "temporarily_unavailable"
end
