defmodule Ryker.Slack.CapabilityTools do
  @moduledoc """
  Turn-bound Slack source capabilities exposed beside Ryker's fixed tools.

  The model receives no Slack credential. Workspace search checks out the
  triggering event's process-local action token and Slack remains the final
  visibility authority for every result.

  This module publishes the tool definitions and dispatches each call: it
  validates the options, audits the call and maps every failure to the small
  set of error codes the model can act on. The work happens in the modules
  under `Ryker.Slack.CapabilityTools`: `Arguments` validates each tool's
  arguments into a provider document, `Authority` decides what the binding may
  touch, `ChannelListing`, `Search` and `SourceReader` read, `Resources`
  shape bookmarks, canvases and files, and `Actions` freeze a reaction, a Work
  update or an offered post into durable custody.
  """
  alias Ryker.Delivery
  alias Ryker.{Options, Rescued}
  alias Ryker.Slack.CapabilityTools.{Actions, Arguments, Authority, ChannelListing, Search}
  alias Ryker.Slack.CapabilityTools.SourceReader
  alias Ryker.Slack.{ChannelConfigurations, Mentions, SourceAudits, SourceRef}

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
            "include_resources" => %{
              "description" =>
                "Also list each channel's bookmarks, one Slack call per channel; ask for 25 channels or fewer with it.",
              "type" => "boolean"
            },
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
              nullable_string("Optional channel name, topic, purpose, or environment filter.")
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
              "items" => %{"enum" => Arguments.content_types(), "type" => "string"},
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
          "Add or remove one deliberate reaction on an exact current human Slack message. Each call is one reaction: a turn makes at most #{Delivery.PlatformActionCustody.maximum_per_turn()}, delivered in the order called, and the same call again is the same reaction. Removal is limited to a reaction previously added by Ryker.",
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
      },
      %{
        "description" =>
          "Post one short message in this conversation right away, before your final answer: an early acknowledgement when the work will take a while, a partial finding someone can act on now, or what you are doing next. It goes at once to the thread your answer goes to, at most #{Delivery.PlatformActionCustody.maximum_per_turn()} per turn, in the order posted. It never replaces the final answer, and the final answer is accepted only once every update has been delivered.",
        "inputSchema" => %{
          "additionalProperties" => false,
          "properties" => %{
            "message" => %{
              "description" => "The words to post, written like the final answer.",
              "maxLength" => Arguments.maximum_update(),
              "minLength" => 1,
              "type" => "string"
            }
          },
          "required" => ["message"],
          "type" => "object"
        },
        "name" => "post_slack_update"
      }
    ]
  end

  @spec call(String.t(), map(), map(), map() | keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def call("list_slack_channels", arguments, binding, options) do
    options = options!(options)

    with {:ok, current_channel_ref} <- Authority.binding(binding, options.workspace_ref),
         {:ok, document, filters} <- Arguments.list_document(arguments),
         {:ok, response} <- options.api.list_conversations(options.client, document),
         {:ok, listed} <-
           ChannelListing.filter_conversations(
             response,
             current_channel_ref,
             options.workspace_ref,
             filters,
             options.configuration
           ),
         {:ok, listed} <-
           ChannelListing.hydrate_resources(listed, filters.include_resources, options),
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
    error -> Rescued.tool("Slack tool list_slack_channels", error, __STACKTRACE__)
  end

  def call("search_slack", arguments, binding, options) do
    options = options!(options)

    with {:ok, current_channel_ref} <- Authority.binding(binding, options.workspace_ref),
         {:ok, document, scoped_channel_refs} <-
           Arguments.search_document(arguments, options.workspace_ref),
         {:ok, current_conversation} <-
           options.api.conversation_info(options.client, current_channel_ref),
         :ok <- Authority.search_destination_authorized(current_conversation, current_channel_ref),
         :ok <- Search.public_search_scopes_authorized(scoped_channel_refs, options),
         {:ok, event_ref} <- options.event_ref.(binding),
         {:ok, token} <- checkout(options.action_tokens, event_ref, binding.turn.id),
         {:ok, response} <- options.api.search_context(options.client, token, document),
         {:ok, decorated} <- Search.authorize_search_response(response, options),
         {:ok, decorated} <- Search.expand_search_context(decorated, arguments, binding, options),
         :ok <-
           audit_call(
             options,
             binding,
             :search_slack,
             "assistant.search.context",
             arguments,
             nil,
             result_count(decorated),
             Search.complete?(decorated)
           ) do
      {:ok, decorated}
    else
      {:error, reason} -> {:error, error_code(reason)}
    end
  rescue
    error -> Rescued.tool("Slack tool search_slack", error, __STACKTRACE__)
  end

  def call("read_slack_source", arguments, binding, options) do
    options = options!(options)

    with {:ok, current_channel_ref} <- Authority.binding(binding, options.workspace_ref),
         {:ok, source, view, document} <-
           Arguments.read_document(arguments, options.workspace_ref),
         {:ok, conversation} <-
           options.api.conversation_info(options.client, source.channel_ref),
         :ok <- Authority.source_authorized(conversation, source, current_channel_ref),
         {:ok, result} <-
           SourceReader.read_source(options, source, view, document, conversation, binding),
         :ok <-
           audit_call(
             options,
             binding,
             :read_slack_source,
             source_capability(source, view),
             arguments,
             SourceRef.encode(source),
             result_count(result),
             result["complete"]
           ) do
      {:ok, result}
    else
      {:error, reason} -> {:error, error_code(reason)}
    end
  rescue
    error -> Rescued.tool("Slack tool read_slack_source", error, __STACKTRACE__)
  end

  def call("set_slack_reaction", arguments, binding, options) do
    options = options!(options)

    with {:ok, _current_channel_ref} <- Authority.binding(binding, options.workspace_ref),
         {:ok, source, action, emoji_name} <-
           Arguments.reaction_document(arguments, options.workspace_ref),
         {:ok, input} <- options.current_input.(binding, source),
         :ok <- Actions.removal_authorized(action, binding, source, emoji_name, options),
         {:ok, %{action: frozen}} <-
           options.enqueue_action.(
             binding,
             Actions.reaction_attributes(input, source, action, emoji_name)
           ) do
      {:ok, %{"action_ref" => frozen.action_ref, "status" => Atom.to_string(frozen.status)}}
    else
      {:error, reason} -> {:error, error_code(reason)}
    end
  rescue
    error -> Rescued.tool("Slack tool set_slack_reaction", error, __STACKTRACE__)
  end

  def call("post_slack_message", arguments, binding, options) do
    options = options!(options)

    with {:ok, current_channel_ref} <- Authority.binding(binding, options.workspace_ref),
         {:ok, destination, instruction, message} <-
           Arguments.post_document(arguments, options.workspace_ref),
         destination_ref = SourceRef.encode(destination),
         {:ok, instruction_authority} <-
           options.current_instruction.(binding, instruction, destination_ref),
         {:ok, conversation} <-
           options.api.conversation_info(options.client, destination.channel_ref),
         :ok <-
           Authority.post_destination_authorized(conversation, destination, current_channel_ref),
         payload <-
           Actions.post_offer_payload(
             destination,
             instruction,
             message,
             instruction_authority.actor_ref
           ),
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
    error -> Rescued.tool("Slack tool post_slack_message", error, __STACKTRACE__)
  end

  def call("post_slack_update", arguments, binding, options) do
    options = options!(options)

    with {:ok, _current_channel_ref} <- Authority.binding(binding, options.workspace_ref),
         {:ok, message} <- Arguments.update_message(arguments),
         :ok <- update_mentions(message, options.mention_authority.(binding)),
         {:ok, destination} <- options.update_destination.(binding),
         {:ok, %{action: frozen}} <-
           options.enqueue_action.(binding, Actions.update_attributes(destination, message)) do
      {:ok, %{"action_ref" => frozen.action_ref, "status" => Atom.to_string(frozen.status)}}
    else
      {:error, reason} -> {:error, error_code(reason)}
    end
  rescue
    error -> Rescued.tool("Slack tool post_slack_update", error, __STACKTRACE__)
  end

  def call(_name, _arguments, _binding, _options), do: {:error, "unknown_tool"}

  @doc """
  Whether a Work update's typed Slack entities are ones its answer may name:
  the same check the final reply passes, so an update can mention no one the
  answer could not.
  """
  @spec update_mentions(String.t(), map() | nil) :: :ok | {:error, term()}
  def update_mentions(message, authority) do
    case Mentions.violations(message, authority) do
      [] -> :ok
      violations -> {:error, {:invalid_update_mentions, violations}}
    end
  end

  @doc false
  defdelegate authorized_post_instruction?(input, destination_ref), to: Authority

  @doc false
  @spec options!(map() | keyword()) :: map()
  def options!(options) do
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
      :mention_authority,
      :propose_post,
      :reaction_added,
      :requester_ref,
      :update_destination,
      :workspace_ref
    ]

    options =
      Options.normalize!(
        options,
        allowed,
        [:action_tokens, :api, :client, :workspace_ref],
        "Slack capability-tool options are invalid"
      )

    api = options.api
    action_tokens = options.action_tokens
    event_ref = Map.get(options, :event_ref, &Authority.current_event_ref/1)
    audit = Map.get(options, :audit, &SourceAudits.record/1)
    requester_ref = Map.get(options, :requester_ref, &Authority.current_requester_ref/1)
    current_input = Map.get(options, :current_input, &Authority.current_slack_input/2)

    current_instruction =
      Map.get(options, :current_instruction, &Authority.current_slack_instruction/3)

    enqueue_action =
      Map.get(options, :enqueue_action, &Delivery.PlatformActionCustody.enqueue_in_turn/2)

    mention_authority = Map.get(options, :mention_authority, &Authority.mention_authority/1)
    update_destination = Map.get(options, :update_destination, &Authority.update_destination/1)
    propose_post = Map.get(options, :propose_post, &Actions.propose_slack_post/2)

    reaction_added =
      Map.get(
        options,
        :reaction_added,
        &Delivery.PlatformActionCustody.delivered_reaction_added?/4
      )

    configuration =
      Map.get(options, :configuration, &ChannelConfigurations.fetch_configuration/2)

    callbacks = %{
      audit: audit,
      configuration: configuration,
      current_input: current_input,
      current_instruction: current_instruction,
      enqueue_action: enqueue_action,
      event_ref: event_ref,
      mention_authority: mention_authority,
      propose_post: propose_post,
      reaction_added: reaction_added,
      requester_ref: requester_ref,
      update_destination: update_destination
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
    |> Map.put(:mention_authority, mention_authority)
    |> Map.put(:propose_post, propose_post)
    |> Map.put(:reaction_added, reaction_added)
    |> Map.put(:requester_ref, requester_ref)
    |> Map.put(:update_destination, update_destination)
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
      is_function(callbacks.mention_authority, 1),
      is_function(callbacks.update_destination, 1),
      is_function(callbacks.propose_post, 2),
      is_function(callbacks.reaction_added, 4),
      is_function(callbacks.configuration, 2),
      SourceRef.slack_id?(workspace_ref)
    ])
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

  defp source_capability(%{kind: :bookmark}, _view), do: "bookmarks.list"
  defp source_capability(%{kind: kind}, _view) when kind in [:canvas, :file], do: "files.info"
  defp source_capability(_source, :metadata), do: "conversations.info"
  defp source_capability(_source, :thread), do: "conversations.replies"
  defp source_capability(_source, _view), do: "conversations.history"

  defp checkout({module, server}, event_ref, turn_id),
    do: module.checkout(server, event_ref, turn_id)

  defp nullable_string(description) do
    %{
      "anyOf" => [
        %{"type" => "null"},
        %{"maxLength" => 4_096, "minLength" => 1, "type" => "string"}
      ],
      "description" => description
    }
  end

  defp action_tokens?({module, _server}), do: module_callback?(module, :checkout, 3)
  defp action_tokens?(_value), do: false

  defp module_callback?(module, function, arity) do
    is_atom(module) and Code.ensure_loaded?(module) and
      function_exported?(module, function, arity)
  end

  defp error_code(:invalid_arguments), do: "invalid_arguments"

  defp error_code({:invalid_update_mentions, _violations} = reason), do: refusal_code(reason)
  defp error_code(:update_limit_reached), do: refusal_code(:update_limit_reached)
  defp error_code(:reaction_limit_reached), do: refusal_code(:reaction_limit_reached)
  defp error_code(:invalid_source_cursor), do: "invalid_source_cursor"
  defp error_code(:unauthorized), do: "unauthorized"
  defp error_code(:slack_action_token_not_authorized), do: "unauthorized"
  defp error_code(:slack_search_budget_exhausted), do: "search_budget_exhausted"

  # Slack lets Ryker search only with the permission some of a person's own
  # messages carry, such as one that mentions it, kept for fifteen minutes.
  # Without it no retry can work; "temporarily_unavailable" told the model to
  # try again, and every search from 27 to 28 Sep failed that way.
  defp error_code(:slack_action_token_unavailable) do
    "search_unavailable: Slack lets Ryker search only for a short time after a message that mentions it, and this turn has no such permission. Do not retry. Read the channels and threads you know with read_slack_source, or say in the answer what a search would have checked."
  end

  defp error_code(:slack_source_not_found), do: "not_found"

  # Slack refusing what it will refuse again, such as a channel that is gone or
  # one Ryker is not in, is no outage: "temporarily_unavailable" had the model
  # retry it.
  defp error_code({:slack_api_error, code} = reason) when is_binary(code) do
    if Delivery.Retry.retryable?(reason) or not Regex.match?(~r/\A[a-z_]{1,64}\z/, code),
      do: "temporarily_unavailable",
      else:
        "slack_refused: Slack answered #{code} and will answer the same again. Do not retry this call."
  end

  defp error_code(_reason), do: "temporarily_unavailable"

  @doc """
  What a refused reaction or Work update reads, the same in Slack and Chat:
  what happened and what to do instead, never a code the model reads as "try
  the same call again". Nil for a refusal every tool shares.
  """
  @spec refusal_code(term()) :: String.t() | nil
  def refusal_code({:invalid_update_mentions, violations}),
    do: "invalid_arguments: " <> Enum.join(violations, " ") <> " Nothing was posted."

  def refusal_code(:update_limit_reached) do
    "update_limit_reached: this turn has already posted its #{Delivery.PlatformActionCustody.maximum_per_turn()} updates. Nothing was posted; say anything more in the final answer."
  end

  def refusal_code(:reaction_limit_reached) do
    "reaction_limit_reached: at most #{Delivery.PlatformActionCustody.maximum_per_turn()} reactions per turn, and this turn has made them. Nothing was changed; say anything more in the final answer."
  end

  def refusal_code(_reason), do: nil
end
