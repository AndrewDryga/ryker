defmodule Ryker.Admission.Decision do
  @moduledoc """
  The complete model-controlled portion of source admission.

  Candidate references are opaque values supplied by the host. The decision
  never contains a channel, thread, delivery destination, or raw episode identity.
  """

  alias Ryker.Work.RepositorySource

  @actions [:start_episode, :continue_episode, :reply, :react, :ignore]
  @relations [:same_work, :history_only, :unrelated]
  @work_classes [:conversational, :standard, :deep]
  @fields ~w(action episode_ref reaction relation reason repository_source work_class)
  @nonblank_pattern "^[^\\x00]*[^\\s\\x00][^\\x00]*$"

  @enforce_keys [
    :action,
    :episode_ref,
    :reaction,
    :relation,
    :reason,
    :repository_source,
    :work_class
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          action: :start_episode | :continue_episode | :reply | :react | :ignore,
          episode_ref: String.t() | nil,
          reaction: %{emoji_name: String.t()} | nil,
          relation: :same_work | :history_only | :unrelated,
          reason: String.t(),
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
         {:ok, reaction} <- parse_reaction(value["reaction"]),
         :ok <- validate_reason(value["reason"]),
         :ok <- validate_shape(action, value["episode_ref"], reaction, relation),
         :ok <- validate_work_class(action, work_class),
         {:ok, repository_source} <-
           parse_repository_source(action, value["repository_source"]) do
      {:ok,
       %__MODULE__{
         action: action,
         episode_ref: value["episode_ref"],
         reaction: reaction,
         relation: relation,
         reason: value["reason"],
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
      "reaction" => reaction_document(decision.reaction),
      "relation" => Atom.to_string(decision.relation),
      "reason" => decision.reason,
      "repository_source" => decision.repository_source,
      "work_class" => work_class_document(decision.work_class)
    }
  end

  @doc """
  Fingerprints the durable decision, excluding explanatory prose.

  A provider may paraphrase its reason after a lost response. The natural
  Slack-input slot still reconciles that retry when the chosen action,
  candidate, relation, and reaction are unchanged.
  """
  @spec fingerprint(t()) :: String.t()
  def fingerprint(%__MODULE__{} = decision) do
    decision
    |> document()
    |> Map.delete("reason")
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

  @doc """
  Publishes the decision contract for one source.

  `repository_source?` is host-owned: only a route whose repository Ryker
  already selected may offer a source selector, and only on a new episode.
  """
  @spec json_schema([atom()], :any | [String.t()] | nil, boolean()) :: map()
  def json_schema(allowed_actions, reaction_names, repository_source?)
      when is_list(allowed_actions) and is_boolean(repository_source?) do
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
        "reaction" => %{
          "anyOf" => [
            reaction_schema(reaction_names),
            %{"type" => "null"}
          ]
        },
        "relation" => %{"enum" => Enum.map(@relations, &Atom.to_string/1)},
        "reason" => bounded_string_schema(512),
        "repository_source" => repository_source_schema(repository_source?),
        "work_class" => %{
          "anyOf" => [
            %{"enum" => Enum.map(@work_classes, &Atom.to_string/1), "type" => "string"},
            %{"type" => "null"}
          ]
        }
      },
      "oneOf" => decision_shapes(actions, reaction_names, repository_source?),
      "required" => @fields,
      "title" => "Ryker admission decision",
      "type" => "object"
    }
  end

  defp decision_shapes(actions, reaction_names, repository_source?) do
    selectable = repository_source? and :start_episode in actions

    [
      shape("start_episode", nil, nil, "unrelated", :investigation, selectable),
      shape("start_episode", :reference, nil, "history_only", :investigation, selectable),
      shape("continue_episode", :reference, nil, "same_work", :investigation, false),
      shape("reply", nil, nil, "unrelated", :conversation, false),
      shape("reply", :reference, nil, "same_work", :conversation, false),
      shape("reply", :reference, nil, "history_only", :conversation, false),
      shape("react", nil, {:reaction, reaction_names}, "unrelated", nil, false),
      shape("ignore", nil, nil, "unrelated", nil, false)
    ]
    |> Enum.filter(fn %{"properties" => %{"action" => %{"const" => action}}} ->
      String.to_existing_atom(action) in actions
    end)
  end

  defp shape(action, episode_ref, reaction, relation, work_class, selectable) do
    %{
      "properties" => %{
        "action" => %{"const" => action},
        "episode_ref" => reference_shape(episode_ref),
        "reaction" => reaction_shape(reaction),
        "relation" => %{"const" => relation},
        "repository_source" => repository_source_schema(selectable),
        "work_class" => work_class_shape(work_class)
      }
    }
  end

  defp repository_source_schema(false), do: %{"type" => "null"}

  defp repository_source_schema(true),
    do: %{"anyOf" => [RepositorySource.json_schema(), %{"type" => "null"}]}

  defp reference_shape(nil), do: %{"type" => "null"}

  defp reference_shape(:reference),
    do: bounded_string_schema(128)

  defp reaction_shape(nil), do: %{"type" => "null"}

  defp reaction_shape({:reaction, reaction_names}), do: reaction_schema(reaction_names)

  defp work_class_shape(:conversation), do: %{"const" => "conversational"}
  defp work_class_shape(:investigation), do: %{"enum" => ~w(standard deep)}
  defp work_class_shape(nil), do: %{"type" => "null"}

  defp reaction_schema(reaction_names) do
    %{
      "additionalProperties" => false,
      "properties" => %{
        "emoji_name" => emoji_name_schema(reaction_names)
      },
      "required" => ["emoji_name"],
      "type" => "object"
    }
  end

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
    if Enum.all?(@fields, &Map.has_key?(value, &1)) and
         Enum.all?(Map.keys(value), &(&1 in @fields)),
       do: :ok,
       else: {:error, {:invalid_decision, :fields}}
  end

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

  defp parse_reaction(nil), do: {:ok, nil}

  defp parse_reaction(%{"emoji_name" => emoji_name} = reaction) when map_size(reaction) == 1 do
    if emoji_name?(emoji_name),
      do: {:ok, %{emoji_name: emoji_name}},
      else: {:error, {:invalid_decision, :reaction}}
  end

  defp parse_reaction(_reaction), do: {:error, {:invalid_decision, :reaction}}

  defp reaction_document(nil), do: nil
  defp reaction_document(%{emoji_name: emoji_name}), do: %{"emoji_name" => emoji_name}

  defp work_class_document(nil), do: nil
  defp work_class_document(work_class), do: Atom.to_string(work_class)

  defp validate_work_class(:reply, :conversational), do: :ok

  defp validate_work_class(action, work_class)
       when action in [:start_episode, :continue_episode] and work_class in [:standard, :deep],
       do: :ok

  defp validate_work_class(action, nil) when action in [:react, :ignore], do: :ok
  defp validate_work_class(_action, _work_class), do: invalid(:work_class)

  defp validate_shape(:continue_episode, ref, nil, :same_work) when is_binary(ref), do: :ok
  defp validate_shape(:continue_episode, _ref, nil, :same_work), do: invalid(:episode_ref)
  defp validate_shape(:continue_episode, _ref, _reaction, :same_work), do: invalid(:reaction)
  defp validate_shape(:continue_episode, _ref, _reaction, _relation), do: invalid(:relation)

  defp validate_shape(:start_episode, nil, nil, :unrelated), do: :ok
  defp validate_shape(:start_episode, ref, nil, :history_only) when is_binary(ref), do: :ok
  defp validate_shape(:start_episode, nil, nil, :history_only), do: invalid(:episode_ref)

  defp validate_shape(:start_episode, _ref, reaction, _relation) when not is_nil(reaction),
    do: invalid(:reaction)

  defp validate_shape(:start_episode, _ref, _reaction, _relation), do: invalid(:relation)

  defp validate_shape(:reply, nil, nil, :unrelated), do: :ok

  defp validate_shape(:reply, ref, nil, relation)
       when is_binary(ref) and relation in [:same_work, :history_only],
       do: :ok

  defp validate_shape(:reply, _ref, reaction, _relation) when not is_nil(reaction),
    do: invalid(:reaction)

  defp validate_shape(:reply, nil, _reaction, _relation), do: invalid(:episode_ref)
  defp validate_shape(:reply, _ref, _reaction, _relation), do: invalid(:relation)

  defp validate_shape(:react, nil, %{emoji_name: _emoji_name}, :unrelated), do: :ok
  defp validate_shape(:react, _ref, nil, :unrelated), do: invalid(:reaction)
  defp validate_shape(:react, _ref, _reaction, _relation), do: invalid(:relation)

  defp validate_shape(:ignore, nil, nil, :unrelated), do: :ok

  defp validate_shape(:ignore, _ref, _reaction, _relation),
    do: invalid(:relation)

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
