defmodule Ryker.Admission.Decision do
  @moduledoc """
  The complete model-controlled portion of source admission.

  Candidate references are opaque values supplied by the host. The decision
  never contains a channel, thread, delivery destination, or raw episode identity.
  On a new episode in an environment with several repositories it names, by
  ref, the one the work changes, from the choices the host offered.

  A quick reply is routing answering a simple message itself (a greeting, a
  thanks) without starting the work model; it starts and continues no work
  (Andrew, 2026-09-26). Its `messages` are one to three short messages sent in
  order, and its optional `reactions` up to three emoji added to the person's
  message. A reaction alone is one to three emoji in `reactions` (Andrew,
  2026-09-26: "Now both reply and add a reaction" had to start a work run).
  """

  alias Ryker.Work.RepositorySource

  @actions [:start_episode, :continue_episode, :reply, :quick_reply, :react, :ignore]
  @relations [:same_work, :history_only, :unrelated]
  @work_classes [:conversational, :standard, :deep]
  @fields ~w(action episode_ref messages reactions relation reason repository repository_source work_class)
  @sorted_fields Enum.sort(@fields)
  @maximum_message 1_000
  @maximum_messages 3
  @maximum_reactions 3
  @nonblank_pattern "^[^\\x00]*[^\\s\\x00][^\\x00]*$"

  @enforce_keys [
    :action,
    :episode_ref,
    :relation,
    :reason,
    :repository_source,
    :work_class
  ]
  # A decision built without a repository chose none, and one without
  # messages or reactions sends nothing by itself.
  defstruct @enforce_keys ++ [messages: nil, reactions: nil, repository: nil]

  @type t :: %__MODULE__{
          action: :start_episode | :continue_episode | :reply | :quick_reply | :react | :ignore,
          episode_ref: String.t() | nil,
          messages: [String.t()] | nil,
          reactions: [String.t()] | nil,
          relation: :same_work | :history_only | :unrelated,
          reason: String.t(),
          repository: String.t() | nil,
          repository_source: map() | nil,
          work_class: :conversational | :standard | :deep | nil
        }

  @spec parse(map()) :: {:ok, t()} | {:error, term()}
  def parse(%{} = value) do
    with :ok <- exact_fields(value),
         {:ok, action} <- parse_enum(value["action"], @actions, :action),
         {:ok, relation} <- parse_enum(value["relation"], @relations, :relation),
         {:ok, work_class} <- parse_work_class(value["work_class"]),
         :ok <- validate_reference(value["episode_ref"]),
         :ok <- validate_reason(value["reason"]),
         {:ok, messages} <- parse_messages(action, value["messages"]),
         {:ok, reactions} <- parse_reactions(action, value["reactions"]),
         :ok <- validate_shape(action, value["episode_ref"], relation),
         :ok <- validate_work_class(action, work_class),
         {:ok, repository} <- parse_repository(action, value["repository"]),
         {:ok, repository_source} <-
           parse_repository_source(action, value["repository_source"]) do
      {:ok,
       %__MODULE__{
         action: action,
         episode_ref: value["episode_ref"],
         messages: messages,
         reactions: reactions,
         relation: relation,
         reason: value["reason"],
         repository: repository,
         repository_source: repository_source,
         work_class: work_class
       }}
    end
  end

  def parse(_value), do: {:error, {:invalid_decision, :type}}

  @spec prepare(t()) :: {:ok, t()} | {:error, term()}
  def prepare(%__MODULE__{} = decision), do: decision |> document() |> parse()
  def prepare(_decision), do: {:error, {:invalid_decision, :type}}

  @spec document(t()) :: map()
  def document(%__MODULE__{} = decision) do
    %{
      "action" => Atom.to_string(decision.action),
      "episode_ref" => decision.episode_ref,
      "messages" => decision.messages,
      "reactions" => decision.reactions,
      "relation" => Atom.to_string(decision.relation),
      "reason" => decision.reason,
      "repository" => decision.repository,
      "repository_source" => decision.repository_source,
      "work_class" => work_class_document(decision.work_class)
    }
  end

  @doc """
  Fingerprints the durable decision, excluding its prose: the reason and a
  quick reply's words.

  A provider may paraphrase either after a lost response. The natural
  Slack-input slot still reconciles that retry when the chosen action,
  candidate, relation, and reactions are unchanged; the first recorded words
  are the ones sent.
  """
  @spec fingerprint(t()) :: String.t()
  def fingerprint(%__MODULE__{} = decision) do
    decision
    |> document()
    |> Map.drop(["reason", "messages"])
    |> Ryker.CanonicalJSON.digest()
  end

  @spec json_schema() :: map()
  def json_schema, do: json_schema(@actions, :any, false)

  @spec json_schema([atom()]) :: map()
  def json_schema(allowed_actions) when is_list(allowed_actions),
    do: json_schema(allowed_actions, :any, false)

  @spec json_schema([atom()], :any | [String.t()] | nil) :: map()
  def json_schema(allowed_actions, reaction_names) when is_list(allowed_actions),
    do: json_schema(allowed_actions, reaction_names, false)

  @spec json_schema([atom()], :any | [String.t()] | nil, boolean()) :: map()
  def json_schema(allowed_actions, reaction_names, repository_source?)
      when is_list(allowed_actions) and is_boolean(repository_source?),
      do: json_schema(allowed_actions, reaction_names, repository_source?, [])

  @doc """
  Publishes the decision contract for one source.

  Both selectors are host-owned. `repository_source?` is offered only on a
  route whose repository Ryker already selected, and only on a new episode.
  `repository_choices` are the repositories of the route's environment when
  it has more than one: a new episode must name one of them, and every other
  action sends null. With one repository or none there is nothing to choose.
  """
  @spec json_schema([atom()], :any | [String.t()] | nil, boolean(), [String.t()]) :: map()
  def json_schema(allowed_actions, reaction_names, repository_source?, repository_choices)
      when is_list(allowed_actions) and is_boolean(repository_source?) and
             is_list(repository_choices) do
    actions = Enum.filter(@actions, &(&1 in allowed_actions))

    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "additionalProperties" => false,
      "properties" => %{
        "action" => %{"enum" => Enum.map(actions, &Atom.to_string/1)},
        "episode_ref" => %{
          "anyOf" => [
            bounded_string_schema(128),
            %{"type" => "null"}
          ]
        },
        "messages" => %{"anyOf" => [messages_schema(), %{"type" => "null"}]},
        "reactions" => %{"anyOf" => [reactions_schema(reaction_names), %{"type" => "null"}]},
        "relation" => %{"enum" => Enum.map(@relations, &Atom.to_string/1)},
        "reason" => bounded_string_schema(512),
        "repository" => nullable_repository_schema(repository_choices),
        "repository_source" => repository_source_schema(repository_source?),
        "work_class" => %{
          "anyOf" => [
            %{"enum" => Enum.map(@work_classes, &Atom.to_string/1), "type" => "string"},
            %{"type" => "null"}
          ]
        }
      },
      "oneOf" => decision_shapes(actions, reaction_names, repository_source?, repository_choices),
      "required" => @fields,
      "title" => "Ryker admission decision",
      "type" => "object"
    }
  end

  @doc """
  Today's decision contract for a source a recorded contract was published
  for: the actions, emoji, repository selector and repository choices it
  offered, rebuilt with today's shapes, so a recorded routing decision can be
  asked again under a changed contract (`mix ryker.eval routing-replay`).
  """
  @spec replay_schema(map()) :: {:ok, map()} | {:error, {:invalid_decision, :schema}}
  def replay_schema(%{"properties" => properties, "oneOf" => shapes}) do
    with %{"action" => %{"enum" => names}} when is_list(names) <- properties,
         actions = Enum.map(names, &String.to_existing_atom/1),
         true <- actions != [] and Enum.all?(actions, &(&1 in @actions)) do
      {:ok,
       json_schema(
         actions,
         recorded_reactions(shapes, properties),
         properties["repository_source"] != %{"type" => "null"},
         recorded_choices(properties["repository"])
       )}
    else
      _unrecognised -> {:error, {:invalid_decision, :schema}}
    end
  rescue
    ArgumentError -> {:error, {:invalid_decision, :schema}}
  end

  def replay_schema(_recorded), do: {:error, {:invalid_decision, :schema}}

  # A quick reply that can carry no emoji names a source that takes none;
  # otherwise the offered names, or any.
  defp recorded_reactions(shapes, properties) do
    quick_reply =
      Enum.find(shapes, &(get_in(&1, ["properties", "action", "const"]) == "quick_reply"))

    cond do
      quick_reply && quick_reply["properties"]["reactions"] == %{"type" => "null"} ->
        nil

      match?(%{"anyOf" => [%{"items" => %{"enum" => _}} | _]}, properties["reactions"]) ->
        get_in(properties, ["reactions", "anyOf", Access.at(0), "items", "enum"])

      true ->
        :any
    end
  end

  defp recorded_choices(%{"anyOf" => [%{"enum" => choices} | _]}) when is_list(choices),
    do: choices

  defp recorded_choices(_repository), do: []

  defp decision_shapes(actions, reaction_names, repository_source?, repository_choices) do
    selectable = repository_source? and :start_episode in actions
    new_episode = %{choices: repository_choices, source: selectable}
    pinned = %{choices: [], source: false}

    [
      shape("start_episode", nil, "unrelated", :investigation, new_episode),
      shape("start_episode", :reference, "history_only", :investigation, new_episode),
      shape("continue_episode", :reference, "same_work", :investigation, pinned),
      shape("reply", nil, "unrelated", :conversation, pinned),
      shape("reply", :reference, "same_work", :conversation, pinned),
      shape("reply", :reference, "history_only", :conversation, pinned),
      "quick_reply"
      |> shape(nil, "unrelated", nil, pinned)
      |> sends("messages", messages_schema())
      |> sends("reactions", optional_reactions_schema(reaction_names)),
      "react"
      |> shape(nil, "unrelated", nil, pinned)
      |> sends("reactions", reactions_schema(reaction_names)),
      shape("ignore", nil, "unrelated", nil, pinned)
    ]
    |> Enum.filter(fn %{"properties" => %{"action" => %{"const" => action}}} ->
      String.to_existing_atom(action) in actions
    end)
  end

  defp shape(action, episode_ref, relation, work_class, selectors) do
    %{
      "properties" => %{
        "action" => %{"const" => action},
        "episode_ref" => reference_shape(episode_ref),
        "messages" => %{"type" => "null"},
        "reactions" => %{"type" => "null"},
        "relation" => %{"const" => relation},
        "repository" => repository_shape(selectors.choices),
        "repository_source" => repository_source_schema(selectors.source),
        "work_class" => work_class_shape(work_class)
      }
    }
  end

  # Only a quick reply carries words, and it always does; it and a reaction
  # are the only shapes that add emoji to the person's message.
  defp sends(shape, field, schema), do: put_in(shape, ["properties", field], schema)

  defp messages_schema do
    %{
      "items" => bounded_string_schema(@maximum_message),
      "maxItems" => @maximum_messages,
      "minItems" => 1,
      "type" => "array"
    }
  end

  defp reactions_schema(reaction_names) do
    %{
      "items" => emoji_name_schema(reaction_names),
      "maxItems" => @maximum_reactions,
      "minItems" => 1,
      "type" => "array",
      "uniqueItems" => true
    }
  end

  # A source that cannot take a reaction offers a quick answer in words only.
  defp optional_reactions_schema(nil), do: %{"type" => "null"}

  defp optional_reactions_schema(reaction_names),
    do: %{"anyOf" => [reactions_schema(reaction_names), %{"type" => "null"}]}

  defp repository_source_schema(false), do: %{"type" => "null"}

  defp repository_source_schema(true),
    do: %{"anyOf" => [RepositorySource.json_schema(), %{"type" => "null"}]}

  # Offered choices are required on the shapes that take them: a new episode
  # in an environment with several repositories always names one.
  defp repository_shape([]), do: %{"type" => "null"}
  defp repository_shape(choices), do: %{"enum" => choices, "type" => "string"}

  defp nullable_repository_schema([]), do: %{"type" => "null"}

  defp nullable_repository_schema(choices),
    do: %{"anyOf" => [repository_shape(choices), %{"type" => "null"}]}

  defp reference_shape(nil), do: %{"type" => "null"}

  defp reference_shape(:reference),
    do: bounded_string_schema(128)

  defp work_class_shape(:conversation), do: %{"const" => "conversational"}
  defp work_class_shape(:investigation), do: %{"enum" => ~w(standard deep)}
  defp work_class_shape(nil), do: %{"type" => "null"}

  defp emoji_name_schema(names) when is_list(names), do: %{"enum" => names, "type" => "string"}

  defp emoji_name_schema(_names) do
    %{
      "maxLength" => 80,
      "minLength" => 1,
      "pattern" => "^[a-z0-9_+\\-]+$",
      "type" => "string"
    }
  end

  defp exact_fields(value) do
    if Enum.sort(Map.keys(value)) == @sorted_fields,
      do: :ok,
      else: {:error, {:invalid_decision, :fields}}
  end

  # A repository is chosen once, when the episode is created, from the
  # environment's repositories the host offered. Continuing, replying,
  # reacting and ignoring inherit whatever their work already pinned.
  defp parse_repository(_action, nil), do: {:ok, nil}

  defp parse_repository(:start_episode, value) do
    if bounded_text?(value, 256), do: {:ok, value}, else: invalid(:repository)
  end

  defp parse_repository(_action, _value), do: invalid(:repository)

  defp parse_enum(value, allowed, field) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, {:invalid_decision, field}}
      parsed -> {:ok, parsed}
    end
  end

  defp parse_enum(_value, _allowed, field), do: {:error, {:invalid_decision, field}}

  # A source is chosen once, when the episode is created. Continuing, replying,
  # reacting and ignoring inherit whatever their work already pinned.
  defp parse_repository_source(_action, nil), do: {:ok, nil}

  defp parse_repository_source(:start_episode, value) do
    case RepositorySource.parse(value) do
      {:ok, source} -> {:ok, source}
      {:error, _reason} -> invalid(:repository_source)
    end
  end

  defp parse_repository_source(_action, _value), do: invalid(:repository_source)

  # A quick reply always says something, in one to three messages sent in order.
  defp parse_messages(:quick_reply, messages)
       when is_list(messages) and length(messages) in 1..@maximum_messages do
    if Enum.all?(messages, &bounded_text?(&1, @maximum_message)),
      do: {:ok, messages},
      else: invalid(:messages)
  end

  defp parse_messages(action, nil) when action != :quick_reply, do: {:ok, nil}
  defp parse_messages(_action, _messages), do: invalid(:messages)

  # A reaction is one to three different emoji; a quick reply may add them to
  # its words or not. No other action touches the person's message.
  defp parse_reactions(action, reactions)
       when action in [:react, :quick_reply] and is_list(reactions) and
              length(reactions) in 1..@maximum_reactions do
    if Enum.all?(reactions, &emoji_name?/1) and Enum.uniq(reactions) == reactions,
      do: {:ok, reactions},
      else: invalid(:reactions)
  end

  defp parse_reactions(action, nil) when action != :react, do: {:ok, nil}
  defp parse_reactions(_action, _reactions), do: invalid(:reactions)

  defp parse_work_class(nil), do: {:ok, nil}
  defp parse_work_class(value), do: parse_enum(value, @work_classes, :work_class)

  defp validate_reference(nil), do: :ok

  defp validate_reference(value) do
    if bounded_text?(value, 128),
      do: :ok,
      else: {:error, {:invalid_decision, :episode_ref}}
  end

  defp validate_reason(value) do
    if bounded_text?(value, 512),
      do: :ok,
      else: {:error, {:invalid_decision, :reason}}
  end

  defp work_class_document(nil), do: nil
  defp work_class_document(work_class), do: Atom.to_string(work_class)

  defp validate_work_class(:reply, :conversational), do: :ok

  defp validate_work_class(action, work_class)
       when action in [:start_episode, :continue_episode] and work_class in [:standard, :deep],
       do: :ok

  defp validate_work_class(action, nil) when action in [:quick_reply, :react, :ignore], do: :ok
  defp validate_work_class(_action, _work_class), do: invalid(:work_class)

  defp validate_shape(:continue_episode, ref, :same_work) when is_binary(ref), do: :ok
  defp validate_shape(:continue_episode, _ref, :same_work), do: invalid(:episode_ref)
  defp validate_shape(:continue_episode, _ref, _relation), do: invalid(:relation)

  defp validate_shape(:start_episode, nil, :unrelated), do: :ok
  defp validate_shape(:start_episode, ref, :history_only) when is_binary(ref), do: :ok
  defp validate_shape(:start_episode, nil, :history_only), do: invalid(:episode_ref)
  defp validate_shape(:start_episode, _ref, _relation), do: invalid(:relation)

  defp validate_shape(:reply, nil, :unrelated), do: :ok

  defp validate_shape(:reply, ref, relation)
       when is_binary(ref) and relation in [:same_work, :history_only],
       do: :ok

  defp validate_shape(:reply, nil, _relation), do: invalid(:episode_ref)
  defp validate_shape(:reply, _ref, _relation), do: invalid(:relation)

  defp validate_shape(action, nil, :unrelated) when action in [:quick_reply, :react, :ignore],
    do: :ok

  defp validate_shape(_action, _ref, _relation), do: invalid(:relation)

  defp invalid(field), do: {:error, {:invalid_decision, field}}

  defp bounded_string_schema(maximum) do
    %{
      "maxLength" => maximum,
      "minLength" => 1,
      "pattern" => @nonblank_pattern,
      "type" => "string"
    }
  end

  defp bounded_text?(value, maximum) do
    is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      String.trim(value) != "" and codepoint_length(value) <= maximum
  end

  defp codepoint_length(value), do: value |> String.codepoints() |> length()

  defp emoji_name?(value) do
    bounded_text?(value, 80) and Regex.match?(~r/^[a-z0-9_+\-]+$/, value)
  end
end
