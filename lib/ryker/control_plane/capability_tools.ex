defmodule Ryker.ControlPlane.CapabilityTools do
  @moduledoc """
  Local-only implementations of the Slack chat capability contract.

  Chat receives the same tool names and argument schemas as a
  Slack turn, but every source and effect is fenced to the exact loopback Lab
  conversation. No call in this module owns or receives Slack credentials.
  """

  import Ecto.Query

  alias Ryker.Artifacts
  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.SourcePage
  alias Ryker.Delivery.PlatformActionCustody
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Repo
  alias Ryker.Slack.CapabilityTools, as: SlackCapabilityTools
  alias Ryker.State.Records
  alias Ryker.StateTools.Binding
  alias Ryker.Work.Turn

  @list_fields ~w(configured_only cursor include_archived include_resources kinds limit query)
  @search_fields ~w(after author_ref before content_types conversation_refs cursor limit query)
  @read_fields ~w(after anchor_ref before cursor limit source_ref view)
  @reaction_fields ~w(action emoji message_ref)
  @post_fields ~w(destination_ref instruction_ref message)
  @emoji_name ~r/\A[a-z0-9_+\-]{1,100}\z/
  @lab_prefix "control-plane:lab:"
  @maximum_messages 200
  @maximum_document_bytes 128 * 1_024
  @text_media_types ~w(text/plain text/markdown text/csv application/json application/yaml application/x-yaml)
  @implemented_tools ~w(
    list_slack_channels
    search_slack
    read_slack_source
    set_slack_reaction
    post_slack_message
  )

  @spec list() :: [map()]
  def list do
    definitions = SlackCapabilityTools.definitions()
    advertised_tools = Enum.map(definitions, & &1["name"])

    if advertised_tools == @implemented_tools do
      definitions
    else
      raise ArgumentError,
            "Chat Slack capability parity is incomplete: " <>
              "implemented=#{inspect(@implemented_tools)} advertised=#{inspect(advertised_tools)}"
    end
  end

  @spec call(String.t(), map(), map()) :: {:ok, map()} | {:error, String.t()}
  def call(name, arguments, binding) when is_binary(name) and is_map(arguments) do
    case lab_binding(binding) do
      {:ok, context} ->
        local_call(name, arguments, context)

      {:error, reason} ->
        {:error, error_code(reason)}
    end
  rescue
    _error -> {:error, "temporarily_unavailable"}
  end

  def call(_name, _arguments, _binding), do: {:error, "invalid_arguments"}

  defp local_call(name, arguments, context) do
    case Repo.transaction(fn -> dispatch_current(name, arguments, context) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, error_code(reason)}
    end
  end

  defp dispatch_current(name, arguments, context) do
    Repo.query!("SET LOCAL statement_timeout = '5000ms'")

    case Binding.lock_current(context.binding) do
      {:ok, _current} -> dispatch(name, arguments, context)
      {:error, _reason} -> Repo.rollback(:unauthorized)
    end
  end

  defp dispatch("list_slack_channels", arguments, context) do
    with :ok <- exact_optional_fields(arguments, @list_fields),
         {:ok, kinds} <-
           enum_list(
             Map.get(arguments, "kinds", ["public_channel"]),
             ~w(public_channel private_channel),
             2
           ),
         {:ok, query} <- optional_text(Map.get(arguments, "query"), 256),
         {:ok, _cursor} <- optional_text(Map.get(arguments, "cursor"), 4_096),
         {:ok, _configured_only} <- boolean(Map.get(arguments, "configured_only", false)),
         {:ok, _include_archived} <- boolean(Map.get(arguments, "include_archived", false)),
         {:ok, include_resources} <- boolean(Map.get(arguments, "include_resources", true)),
         {:ok, limit} <- integer(Map.get(arguments, "limit", 50), 1, 200) do
      conversations =
        if "public_channel" in kinds and
             query_matches?(query, [context.name, context.conversation_ref]) and
             limit > 0,
           do: [conversation_document(context, include_resources)],
           else: []

      {:ok,
       %{
         "conversations" => conversations,
         "cursor" => "",
         "emulated" => true,
         "external_effects" => false,
         "visibility" => "current_local_conversation"
       }}
    else
      {:error, reason} -> {:error, error_code(reason)}
    end
  end

  defp dispatch("search_slack", arguments, context) do
    with :ok <- exact_required_fields(arguments, @search_fields, ["query"]),
         {:ok, query} <- text(arguments["query"], 2_048),
         {:ok, conversations} <-
           conversation_refs(Map.get(arguments, "conversation_refs", []), context),
         {:ok, content_types} <-
           enum_list(
             Map.get(arguments, "content_types", ["messages"]),
             ~w(messages files channels users),
             4
           ),
         {:ok, author_ref} <- optional_text(Map.get(arguments, "author_ref"), 1_024),
         {:ok, after_time} <- optional_timestamp(Map.get(arguments, "after")),
         {:ok, before_time} <- optional_timestamp(Map.get(arguments, "before")),
         {:ok, _cursor} <- optional_text(Map.get(arguments, "cursor"), 4_096),
         {:ok, limit} <- integer(Map.get(arguments, "limit", 20), 1, 20) do
      messages =
        if "messages" in content_types and
             (conversations != [] or Map.get(arguments, "conversation_refs", []) == []) do
          originals =
            messages(context)
            |> Enum.filter(&within_time?(&1["occurred_at"], after_time, before_time))

          originals
          |> Enum.filter(&message_matches?(&1, query, author_ref, after_time, before_time))
          |> Enum.map(&with_message_context(&1, originals))
        else
          []
        end

      files =
        if "files" in content_types and
             (conversations != [] or Map.get(arguments, "conversation_refs", []) == []) do
          context
          |> file_metadata()
          |> Enum.filter(&file_matches?(&1, query, author_ref, after_time, before_time))
          |> Enum.map(&file_result(&1, context))
        else
          []
        end

      results =
        %{}
        |> maybe_put_result("messages", messages, "messages" in content_types)
        |> maybe_put_result("files", files, "files" in content_types)
        |> maybe_put_result("channels", [], "channels" in content_types)
        |> maybe_put_result("users", [], "users" in content_types)

      case search_page(results, arguments, context, limit) do
        {:ok, results, cursor} ->
          {:ok,
           %{
             "complete" => cursor == "",
             "coverage" => %{
               "basis" => "retained_conversation",
               "retained_message_limit" => @maximum_messages,
               "after" => arguments["after"],
               "before" => arguments["before"]
             },
             "emulated" => true,
             "external_effects" => false,
             "next_cursor" => cursor,
             "results" => results
           }}

        {:error, reason} ->
          {:error, error_code(reason)}
      end
    else
      {:error, reason} -> {:error, error_code(reason)}
    end
  end

  defp dispatch("read_slack_source", arguments, context) do
    with :ok <- exact_required_fields(arguments, @read_fields, ~w(source_ref view)),
         {:ok, source_ref} <- text(arguments["source_ref"], 1_024),
         {:ok, view} <- enum(arguments["view"], ~w(surrounding thread channel document metadata)),
         {:ok, anchor_ref} <- optional_text(Map.get(arguments, "anchor_ref"), 1_024),
         {:ok, read_ref, read_view} <- source_read_target(source_ref, view, anchor_ref, context),
         {:ok, after_time} <- optional_timestamp(Map.get(arguments, "after")),
         {:ok, before_time} <- optional_timestamp(Map.get(arguments, "before")),
         {:ok, _cursor} <- optional_text(Map.get(arguments, "cursor"), 4_096),
         {:ok, limit} <- integer(Map.get(arguments, "limit", 100), 1, 100),
         {:ok, payload} <-
           source_payload(read_ref, read_view, context, limit, after_time, before_time, arguments) do
      {:ok,
       %{
         "conversation" => conversation_document(context),
         "cursor" => "",
         "emulated" => true,
         "external_effects" => false,
         "source_ref" => source_ref,
         "view" => view
       }
       |> Map.merge(payload)}
    else
      {:error, reason} -> {:error, error_code(reason)}
    end
  end

  defp dispatch("set_slack_reaction", arguments, context) do
    with :ok <- exact_required_fields(arguments, @reaction_fields, @reaction_fields),
         {:ok, action} <- enum(arguments["action"], ~w(add remove)),
         {:ok, emoji} <- emoji(arguments["emoji"]),
         {:ok, input} <- active_input(context, arguments["message_ref"]),
         :ok <- removal_authorized(action, context, input, emoji),
         {:ok, %{action: frozen}} <-
           PlatformActionCustody.enqueue(context.binding, %{
             conversation_ref: context.conversation_ref,
             document: %{"action" => action, "emoji_name" => emoji},
             host_slot: "reaction",
             kind: :reaction,
             source_item_ref: input["source_item_ref"],
             thread_ref: context.conversation_ref,
             tool: :set_slack_reaction,
             transport: "control_plane"
           }) do
      {:ok, %{"action_ref" => frozen.action_ref, "status" => Atom.to_string(frozen.status)}}
    else
      {:error, reason} -> {:error, error_code(reason)}
    end
  end

  defp dispatch("post_slack_message", arguments, context) do
    with :ok <- exact_required_fields(arguments, @post_fields, @post_fields),
         {:ok, destination_ref} <- text(arguments["destination_ref"], 1_024),
         true <- destination_ref == context.conversation_ref,
         {:ok, input} <- active_input(context, arguments["instruction_ref"]),
         true <- post_granted?(input, destination_ref),
         {:ok, message} <- text(arguments["message"], 20_000),
         payload <- post_offer_payload(context, input, destination_ref, message),
         operation_id <- "lab-post:" <> CanonicalJSON.digest(payload),
         {:ok, record} <-
           Records.create(context.binding.state_token, operation_id, "slack_post_offer", payload) do
      {:ok,
       %{
         "kind" => "slack_post_offer",
         "record_ref" => record.ref,
         "status" => Atom.to_string(record.status)
       }}
    else
      false -> {:error, "unauthorized"}
      {:error, reason} -> {:error, error_code(reason)}
    end
  end

  defp dispatch(_name, _arguments, _context), do: {:error, "unknown_tool"}

  defp search_page(results, arguments, context, limit) do
    scope =
      {context.conversation_ref, context.binding.episode.id, context.binding.turn.id,
       Map.delete(arguments, "cursor")}

    secret = Map.get(context.binding, :cursor_secret)

    with {:ok, position} <- search_position(arguments["cursor"], scope, secret) do
      remaining =
        results
        |> Enum.flat_map(fn {kind, items} -> Enum.map(items, &{kind, &1}) end)
        |> Enum.sort_by(&search_key/1)
        |> Enum.drop_while(&(not is_nil(position) and search_key(&1) <= position))

      selected = Enum.take(remaining, limit)

      with {:ok, cursor} <- search_continuation(remaining, selected, scope, secret) do
        page = search_result_kinds(results, selected)

        {:ok, page, cursor}
      end
    end
  end

  defp search_result_kinds(results, selected),
    do: Map.new(results, fn {kind, _} -> {kind, for({^kind, item} <- selected, do: item)} end)

  defp search_key({kind, item}), do: {item["occurred_at"], kind, item["source_ref"]}
  defp search_position(nil, _scope, _secret), do: {:ok, nil}

  defp search_position(cursor, scope, secret)
       when is_binary(secret) and byte_size(secret) >= 16 do
    case Plug.Crypto.verify(secret, "lab-source-search", cursor, max_age: 3_600) do
      {:ok, {^scope, position}} -> {:ok, position}
      _ -> {:error, :invalid_source_cursor}
    end
  end

  defp search_position(_cursor, _scope, _secret), do: {:error, :invalid_source_cursor}

  defp search_continuation(remaining, selected, _scope, _secret)
       when length(remaining) == length(selected),
       do: {:ok, ""}

  defp search_continuation(_remaining, selected, scope, secret)
       when is_binary(secret) and byte_size(secret) >= 16,
       do:
         {:ok,
          Plug.Crypto.sign(secret, "lab-source-search", {scope, search_key(List.last(selected))},
            max_age: 3_600
          )}

  defp search_continuation(_remaining, _selected, _scope, _secret),
    do: {:error, :invalid_source_cursor}

  defp source_read_target(source_ref, view, nil, _context), do: {:ok, source_ref, view}

  defp source_read_target(source_ref, "thread", anchor_ref, %{conversation_ref: source_ref}),
    do: {:ok, anchor_ref, "surrounding"}

  defp source_read_target(_source_ref, _view, _anchor_ref, _context),
    do: {:error, :invalid_arguments}

  defp lab_binding(
         %{
           episode:
             %Episode{
               destination_conversation_ref: @lab_prefix <> conversation_id = conversation_ref,
               destination_thread_ref: conversation_ref,
               destination_transport: "control_plane",
               id: episode_id,
               owner_kind: :turn,
               owner_ref: turn_ref,
               state: :working
             } = episode,
           state_token: state_token,
           turn: %Turn{
             episode_id: episode_id,
             id: turn_id,
             status: :pending,
             turn_ref: turn_ref
           }
         } = binding
       )
       when is_binary(state_token) and is_binary(turn_id) do
    case Ecto.UUID.cast(conversation_id) do
      {:ok, _normalized} ->
        {:ok,
         %{
           binding: binding,
           conversation_id: conversation_id,
           conversation_ref: conversation_ref,
           episode: episode,
           name: "conversation-lab-" <> String.slice(conversation_id, 0, 8)
         }}

      :error ->
        {:error, :unauthorized}
    end
  end

  defp lab_binding(_binding), do: {:error, :unauthorized}

  defp conversation_document(context, include_resources \\ true) do
    document = %{
      "configured" => true,
      "configured_environment_ref" => context.binding.session.environment_ref,
      "conversation_ref" => context.conversation_ref,
      "is_archived" => false,
      "kind" => "public_channel",
      "name" => context.name,
      "purpose" => "Local Slack-parity testing without external traffic",
      "source_ref" => context.conversation_ref,
      "topic" => "Chat"
    }

    if include_resources do
      Map.merge(document, %{
        "resources" =>
          context
          |> file_metadata()
          |> Enum.map(&%{"kind" => "file", "source_ref" => &1.ref}),
        "resources_complete" => true
      })
    else
      document
    end
  end

  defp messages(context) do
    inputs =
      context
      |> input_events()
      |> Enum.flat_map(&input_message(&1, context))

    replies =
      Repo.all(
        from(turn in Turn,
          join: episode in Episode,
          on: episode.id == turn.episode_id,
          where:
            episode.destination_transport == "control_plane" and
              episode.destination_conversation_ref == ^context.conversation_ref and
              episode.destination_thread_ref == ^context.conversation_ref and
              turn.status == :settled and not is_nil(turn.accepted_at) and
              not is_nil(turn.delivery_document) and not is_nil(turn.external_receipt),
          order_by: [desc: turn.accepted_at, desc: turn.id],
          limit: @maximum_messages
        )
      )
      |> Enum.flat_map(&reply_message(&1, context))

    inputs
    |> Kernel.++(replies)
    |> Enum.sort_by(&{&1["occurred_at"], &1["source_ref"]}, :desc)
    |> Enum.take(@maximum_messages)
    |> Enum.sort_by(&{&1["occurred_at"], &1["source_ref"]})
  end

  defp input_message(%{payload: payload} = event, context) do
    case payload do
      %{
        "actor_ref" => actor_ref,
        "payload" => %{
          "content" => %{"text" => text},
          "destination" => %{
            "conversation_ref" => conversation_ref,
            "transport" => "control_plane"
          },
          "event_kind" => event_kind,
          "source" => %{"kind" => "control_plane", "ref" => "local"}
        }
      }
      when conversation_ref == context.conversation_ref and event_kind in ["message", "edit"] and
             is_binary(text) ->
        [
          %{
            "actor_ref" => actor_ref,
            "content" => text,
            "occurred_at" => DateTime.to_iso8601(event.occurred_at),
            "source_ref" => event.dedupe_key
          }
        ]

      _other ->
        []
    end
  end

  defp reply_message(
         %Turn{
           accepted_at: accepted_at,
           delivery_document: %{"message" => message},
           delivery_ref: delivery_ref
         },
         _context
       )
       when is_binary(message) and is_binary(delivery_ref) do
    [
      %{
        "actor_ref" => "ryker",
        "content" => message,
        "occurred_at" => DateTime.to_iso8601(accepted_at),
        "source_ref" => delivery_ref
      }
    ]
  end

  defp reply_message(_turn, _context), do: []

  defp with_message_context(message, originals) do
    index = Enum.find_index(originals, &(&1["source_ref"] == message["source_ref"]))
    before_messages = originals |> Enum.take(index) |> Enum.take(-2)
    after_messages = originals |> Enum.drop(index + 1) |> Enum.take(2)

    Map.merge(message, %{
      "context_messages" => %{"before" => before_messages, "after" => after_messages},
      "context_coverage" => %{
        "status" => "partial",
        "basis" => "retained_conversation",
        "neighbor_limit" => 2,
        "truncated" => length(before_messages) + length(after_messages) + 1 < length(originals)
      }
    })
  end

  defp source_payload(source_ref, view, context, limit, after_time, before_time, arguments)
       when view in ["document", "metadata"] do
    case Enum.find(file_metadata(context), &(&1.ref == source_ref)) do
      nil when view == "document" ->
        if Enum.any?(messages(context), &(&1["source_ref"] == source_ref)),
          do: {:error, :invalid_arguments},
          else: {:error, :unauthorized}

      nil ->
        source_messages(source_ref, view, context, limit, after_time, before_time, arguments)

      file ->
        file_payload(file, context)
    end
  end

  defp source_payload(source_ref, view, context, limit, after_time, before_time, arguments),
    do: source_messages(source_ref, view, context, limit, after_time, before_time, arguments)

  defp source_messages(source_ref, view, context, limit, after_time, before_time, arguments) do
    all = messages(context)
    bounded = Enum.filter(all, &within_time?(&1["occurred_at"], after_time, before_time))

    cond do
      source_ref == context.conversation_ref and view in ["channel", "thread", "metadata"] ->
        source_page(bounded, nil, view, arguments, context, limit)

      view in ["surrounding", "metadata"] ->
        case Enum.find(all, &(&1["source_ref"] == source_ref)) do
          nil -> {:error, :unauthorized}
          anchor -> source_page(bounded, anchor, view, arguments, context, limit)
        end

      true ->
        unsupported_source_view(all, source_ref)
    end
  end

  defp source_page(_messages, _anchor, "metadata", _arguments, _context, _limit),
    do: {:ok, %{"messages" => [], "complete" => true}}

  defp source_page(messages, anchor, _view, arguments, context, limit),
    do: SourcePage.read(messages, anchor, arguments, context.binding, limit)

  defp unsupported_source_view(messages, source_ref) do
    if Enum.any?(messages, &(&1["source_ref"] == source_ref)),
      do: {:error, :invalid_arguments},
      else: {:error, :unauthorized}
  end

  defp file_metadata(context) do
    context
    |> input_events()
    |> Enum.flat_map(&input_files(&1, context))
    |> Enum.uniq_by(& &1.ref)
    |> Enum.take(@maximum_messages)
  end

  defp input_events(context) do
    latest =
      from(event in Event,
        join: episode in Episode,
        on: episode.id == event.episode_id,
        where:
          episode.destination_transport == "control_plane" and
            episode.destination_conversation_ref == ^context.conversation_ref and
            episode.destination_thread_ref == ^context.conversation_ref and
            event.kind == :input_admitted,
        distinct: fragment("(?::jsonb ->> 'native_input_id')", event.payload),
        order_by: [
          asc: fragment("(?::jsonb ->> 'native_input_id')", event.payload),
          desc: fragment("((?::jsonb ->> 'revision')::bigint)", event.payload),
          desc: event.occurred_at,
          desc: event.id
        ],
        select: %{
          dedupe_key: event.dedupe_key,
          episode_id: event.episode_id,
          sequence: event.sequence,
          id: event.id,
          occurred_at: event.occurred_at,
          payload: event.payload
        }
      )

    Repo.all(
      from(event in subquery(latest),
        # Select the latest revision BEFORE excluding pending inputs, otherwise
        # an edit queued for the next turn could resurrect its superseded text.
        where:
          event.episode_id != ^context.episode.id or
            (event.sequence < ^context.episode.next_sequence and
               event.dedupe_key not in ^context.episode.queued_input_refs),
        order_by: [desc: event.occurred_at, desc: event.id],
        limit: @maximum_messages
      )
    )
  end

  defp input_files(%{payload: payload} = event, context) do
    case payload do
      %{
        "actor_ref" => actor_ref,
        "payload" => %{
          "content" => %{"files" => files},
          "destination" => %{
            "conversation_ref" => conversation_ref,
            "thread_ref" => conversation_ref,
            "transport" => "control_plane"
          },
          "event_kind" => event_kind,
          "source" => %{"kind" => "control_plane", "ref" => "local"}
        }
      }
      when conversation_ref == context.conversation_ref and event_kind in ["message", "edit"] and
             is_list(files) ->
        Enum.flat_map(files, &input_file(&1, actor_ref, event.occurred_at, event.dedupe_key))

      _other ->
        []
    end
  end

  defp input_file(
         %{
           "artifact_ref" => ref,
           "bytes" => bytes,
           "media_type" => media_type,
           "name" => name,
           "sha256" => sha256,
           "status" => "available"
         },
         actor_ref,
         occurred_at,
         message_ref
       )
       when is_binary(ref) and is_integer(bytes) and bytes > 0 and is_binary(media_type) and
              is_binary(name) and is_binary(sha256) do
    [
      %{
        actor_ref: actor_ref,
        bytes: bytes,
        media_type: media_type,
        message_ref: message_ref,
        name: name,
        occurred_at: DateTime.to_iso8601(occurred_at),
        ref: ref,
        sha256: sha256
      }
    ]
  end

  defp input_file(_file, _actor_ref, _occurred_at, _message_ref), do: []

  defp file_matches?(file, query, author_ref, after_time, before_time) do
    query_matches?(query, [file.name, file.media_type]) and
      (is_nil(author_ref) or file.actor_ref == author_ref) and
      within_time?(file.occurred_at, after_time, before_time)
  end

  defp file_result(file, context) do
    %{
      "channel_id" => context.conversation_ref,
      "file_id" => file.ref,
      "media_type" => file.media_type,
      "occurred_at" => file.occurred_at,
      "sha256" => file.sha256,
      "size" => file.bytes,
      "source_ref" => file.ref,
      "source_context" => file_source_context(file, context),
      "title" => file.name
    }
  end

  defp file_payload(file, context) do
    with {:ok, [artifact]} <- Artifacts.fetch_many([file.ref]),
         true <- exact_artifact?(artifact, file) do
      {content, complete} = artifact_content(artifact)

      document =
        %{
          "content" => content,
          "content_complete" => complete,
          "kind" => "file",
          "media_type" => artifact.media_type,
          "occurred_at" => file.occurred_at,
          "sha256" => artifact.sha256,
          "size" => artifact.byte_size,
          "source_context" => file_source_context(file, context),
          "title" => artifact.name
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      {:ok, %{"complete" => complete, "document" => document}}
    else
      _missing_or_changed -> {:error, :unauthorized}
    end
  end

  defp file_source_context(file, context) do
    %{
      "conversation_ref" => context.conversation_ref,
      "source_ref" => file.message_ref,
      "source_read" => %{
        "tool" => "read_slack_source",
        "arguments" => %{"source_ref" => file.message_ref, "view" => "surrounding", "limit" => 20}
      }
    }
  end

  defp exact_artifact?(artifact, file) do
    artifact.source_kind == "control_plane" and artifact.ref == file.ref and
      artifact.byte_size == file.bytes and artifact.media_type == file.media_type and
      artifact.name == file.name and artifact.sha256 == file.sha256
  end

  defp artifact_content(%{media_type: media_type, data: data})
       when media_type in @text_media_types do
    if byte_size(data) <= @maximum_document_bytes,
      do: {data, true},
      else: {String.byte_slice(data, 0, @maximum_document_bytes), false}
  end

  defp artifact_content(_artifact), do: {nil, false}

  defp active_input(context, source_ref) when is_binary(source_ref) do
    if source_ref in context.episode.active_input_refs,
      do: load_active_input(context.episode.id, source_ref),
      else: {:error, :unauthorized}
  end

  defp active_input(_context, _source_ref), do: {:error, :invalid_arguments}

  defp load_active_input(episode_id, source_ref) do
    case Repo.one(
           from(event in Event,
             where:
               event.episode_id == ^episode_id and event.kind == :input_admitted and
                 event.dedupe_key == ^source_ref,
             limit: 1
           )
         ) do
      %Event{payload: %{"payload" => %{} = input}} -> {:ok, input}
      _missing -> {:error, :unauthorized}
    end
  end

  defp removal_authorized("add", _context, _input, _emoji), do: :ok

  defp removal_authorized("remove", context, input, emoji) do
    if PlatformActionCustody.delivered_reaction_added?(
         context.episode.id,
         context.conversation_ref,
         input["source_item_ref"],
         emoji
       ),
       do: :ok,
       else: {:error, :unauthorized}
  end

  defp post_granted?(input, destination_ref) do
    case input do
      %{
        "source_capabilities" => %{
          "post_slack_message" => %{"destination_refs" => destinations}
        }
      }
      when is_list(destinations) ->
        destination_ref in destinations

      _input ->
        false
    end
  end

  defp post_offer_payload(context, input, destination_ref, message) do
    %{
      "conversation_ref" => context.conversation_ref,
      "destination_ref" => destination_ref,
      "instruction_ref" => active_input_ref(context, input),
      "message" => message,
      "requested_by_actor_ref" => "control-plane:local",
      "thread_ref" => context.conversation_ref,
      "transport" => "control_plane"
    }
  end

  defp active_input_ref(context, input) do
    Enum.find(context.episode.active_input_refs, fn ref ->
      case Repo.one(
             from(event in Event,
               where: event.episode_id == ^context.episode.id and event.dedupe_key == ^ref,
               select: event.payload,
               limit: 1
             )
           ) do
        %{"payload" => ^input} -> true
        _other -> false
      end
    end)
  end

  defp conversation_refs([], context), do: {:ok, [context.conversation_ref]}

  defp conversation_refs([conversation_ref], %{conversation_ref: conversation_ref}),
    do: {:ok, [conversation_ref]}

  defp conversation_refs(_refs, _context), do: {:error, :unauthorized}

  defp message_matches?(message, query, author_ref, after_time, before_time) do
    query_matches?(query, [message["content"]]) and
      (is_nil(author_ref) or message["actor_ref"] == author_ref) and
      within_time?(message["occurred_at"], after_time, before_time)
  end

  defp within_time?(occurred_at, after_time, before_time) do
    case DateTime.from_iso8601(occurred_at) do
      {:ok, occurred, 0} ->
        (is_nil(after_time) or DateTime.compare(occurred, after_time) in [:eq, :gt]) and
          (is_nil(before_time) or DateTime.compare(occurred, before_time) in [:eq, :lt])

      _invalid ->
        false
    end
  end

  defp query_matches?(nil, _values), do: true

  defp query_matches?(query, values) do
    query = String.downcase(query)

    Enum.any?(values, fn value ->
      is_binary(value) and value |> String.downcase() |> String.contains?(query)
    end)
  end

  defp maybe_put_result(results, key, value, true), do: Map.put(results, key, value)
  defp maybe_put_result(results, _key, _value, false), do: results

  defp exact_optional_fields(arguments, allowed) do
    if Enum.all?(Map.keys(arguments), &(&1 in allowed)),
      do: :ok,
      else: {:error, :invalid_arguments}
  end

  defp exact_required_fields(arguments, allowed, required) do
    if Enum.all?(Map.keys(arguments), &(&1 in allowed)) and
         Enum.all?(required, &Map.has_key?(arguments, &1)),
       do: :ok,
       else: {:error, :invalid_arguments}
  end

  defp text(value, maximum) do
    if is_binary(value) and String.valid?(value) and String.trim(value) != "" and
         byte_size(value) <= maximum,
       do: {:ok, value},
       else: {:error, :invalid_arguments}
  end

  defp optional_text(nil, _maximum), do: {:ok, nil}
  defp optional_text(value, maximum), do: text(value, maximum)

  defp enum(value, allowed) when is_binary(value) do
    if value in allowed, do: {:ok, value}, else: {:error, :invalid_arguments}
  end

  defp enum(_value, _allowed), do: {:error, :invalid_arguments}

  defp enum_list(values, allowed, maximum)
       when is_list(values) and values != [] and length(values) <= maximum do
    if values == Enum.uniq(values) and Enum.all?(values, &(&1 in allowed)),
      do: {:ok, values},
      else: {:error, :invalid_arguments}
  end

  defp enum_list(_values, _allowed, _maximum), do: {:error, :invalid_arguments}

  defp boolean(value) when is_boolean(value), do: {:ok, value}
  defp boolean(_value), do: {:error, :invalid_arguments}

  defp integer(value, minimum, maximum)
       when is_integer(value) and value in minimum..maximum//1,
       do: {:ok, value}

  defp integer(_value, _minimum, _maximum), do: {:error, :invalid_arguments}

  defp optional_timestamp(nil), do: {:ok, nil}

  defp optional_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, 0} -> {:ok, timestamp}
      _invalid -> {:error, :invalid_arguments}
    end
  end

  defp optional_timestamp(_value), do: {:error, :invalid_arguments}

  defp emoji(value) do
    if is_binary(value) and Regex.match?(@emoji_name, value),
      do: {:ok, value},
      else: {:error, :invalid_arguments}
  end

  defp error_code(value) when is_binary(value), do: value
  defp error_code(:unauthorized), do: "unauthorized"
  defp error_code(:invalid_arguments), do: "invalid_arguments"
  defp error_code(:invalid_source_cursor), do: "invalid_source_cursor"
  defp error_code(:state_record_unauthorized), do: "unauthorized"
  defp error_code(:state_record_confirmation_unsupported), do: "unauthorized"
  defp error_code({:invalid_state_record, _field}), do: "invalid_arguments"
  defp error_code(_reason), do: "temporarily_unavailable"
end
