defmodule Responder.GitHub.CapabilityTools do
  @moduledoc """
  Turn-bound GitHub action capabilities backed by Responder's generic action outbox.

  The model receives only opaque host-issued source references. Credentials,
  repository bindings, discussion routing, and delivery retries remain host-owned.
  """

  import Ecto.Query

  alias Responder.Delivery.PlatformActionCustody
  alias Responder.Episodes.{Episode, Event}
  alias Responder.GitHub.SourceRef
  alias Responder.Repo

  @emoji_names ~w(+1 -1 confused eyes heart hooray laugh rocket)
  @fields ~w(emoji item_ref)

  @spec list(map() | keyword()) :: [map()]
  def list(options) do
    _validated = options!(options)

    [
      %{
        "description" =>
          "Add one native GitHub reaction to an exact current issue or pull-request review comment. This cannot approve, review, merge, or change repository content.",
        "inputSchema" => %{
          "additionalProperties" => false,
          "properties" => %{
            "emoji" => %{"enum" => @emoji_names, "type" => "string"},
            "item_ref" => %{"maxLength" => 256, "minLength" => 1, "type" => "string"}
          },
          "required" => ["item_ref", "emoji"],
          "type" => "object"
        },
        "name" => "set_github_reaction"
      }
    ]
  end

  @spec call(String.t(), map(), map(), map() | keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def call("set_github_reaction", arguments, binding, options) do
    options = options!(options)

    with {:ok, source, emoji_name} <- document(arguments),
         true <- MapSet.member?(options.bindings, source.binding),
         {:ok, input} <- options.current_input.(binding, source),
         {:ok, %{action: frozen}} <-
           options.enqueue_action.(binding, action_attributes(input, source, emoji_name)) do
      {:ok, %{"action_ref" => frozen.action_ref, "status" => Atom.to_string(frozen.status)}}
    else
      false -> {:error, "unauthorized"}
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
      else: raise(ArgumentError, "GitHub capability-tool options are invalid")
  end

  def options!(%{} = options) do
    allowed = [:bindings, :current_input, :enqueue_action]

    unless Map.keys(options) -- allowed == [] and Map.has_key?(options, :bindings),
      do: raise(ArgumentError, "GitHub capability-tool options are invalid")

    bindings = prepare_bindings(options.bindings)
    current_input = Map.get(options, :current_input, &current_github_input/2)
    enqueue_action = Map.get(options, :enqueue_action, &PlatformActionCustody.enqueue/2)

    unless is_function(current_input, 2) and is_function(enqueue_action, 2),
      do: raise(ArgumentError, "GitHub capability-tool authority is invalid")

    %{bindings: bindings, current_input: current_input, enqueue_action: enqueue_action}
  end

  def options!(_options), do: raise(ArgumentError, "GitHub capability-tool options are invalid")

  defp document(%{} = arguments) do
    with true <- Map.keys(arguments) |> Enum.sort() == @fields,
         {:ok, source} <- SourceRef.parse(arguments["item_ref"]),
         emoji_name when emoji_name in @emoji_names <- arguments["emoji"] do
      {:ok, source, emoji_name}
    else
      {:error, :invalid_github_source_ref} -> {:error, :unauthorized}
      _invalid -> {:error, :invalid_arguments}
    end
  end

  defp document(_arguments), do: {:error, :invalid_arguments}

  defp action_attributes(input, source, emoji_name) do
    %{
      conversation_ref: input["destination"]["conversation_ref"],
      document: %{"action" => "add", "emoji_name" => emoji_name},
      host_slot: "reaction",
      kind: :reaction,
      source_item_ref: "github:#{source.item_kind}:#{source.item_id}",
      thread_ref: input["destination"]["thread_ref"],
      tool: :set_github_reaction,
      transport: "github"
    }
  end

  defp current_github_input(%{episode: %Episode{} = episode}, source) do
    source_item_ref = "github:#{source.item_kind}:#{source.item_id}"

    episode
    |> active_input_events()
    |> Enum.find_value({:error, :unauthorized}, fn event ->
      case event.payload do
        %{
          "payload" =>
            %{
              "actor" => %{"kind" => actor_kind},
              "destination" => %{"transport" => "github"},
              "source" => %{"kind" => "github", "ref" => binding},
              "source_capabilities" => %{"react" => %{"emoji_names" => emoji_names}},
              "source_item_ref" => ^source_item_ref
            } = input
        }
        when actor_kind in ["user", "bot"] and binding == source.binding and
               is_list(emoji_names) ->
          {:ok, input}

        _other ->
          nil
      end
    end)
  end

  defp current_github_input(_binding, _source), do: {:error, :unauthorized}

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

  defp prepare_bindings(%MapSet{} = bindings) do
    if Enum.all?(bindings, &binding?/1),
      do: bindings,
      else: raise(ArgumentError, "GitHub capability-tool bindings are invalid")
  end

  defp prepare_bindings(bindings) when is_map(bindings) do
    names = Map.keys(bindings)

    if Enum.all?(names, &binding?/1),
      do: MapSet.new(names),
      else: raise(ArgumentError, "GitHub capability-tool bindings are invalid")
  end

  defp prepare_bindings(_bindings),
    do: raise(ArgumentError, "GitHub capability-tool bindings are invalid")

  defp binding?(value),
    do: is_binary(value) and Regex.match?(~r/\A[a-z][a-z0-9_-]{0,63}\z/, value)

  defp error_code(:unauthorized), do: "unauthorized"
  defp error_code(:invalid_arguments), do: "invalid_arguments"
  defp error_code(_reason), do: "temporarily_unavailable"
end
