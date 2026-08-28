defmodule Responder.Ingress.Input do
  @moduledoc """
  One source-neutral event at Responder's trusted ingress boundary.

  Adapters own source identity, actor identity, capabilities, and destination.
  Arbitrary source content remains bounded JSON for the model to interpret; it
  cannot choose routing or authority by smuggling fields into that content.
  """

  alias Responder.CanonicalJSON
  alias Responder.Episodes.Command

  @content_limit 49_152
  @maximum_revision 9_223_372_036_854_775_807
  @envelope_episode_id "00000000-0000-0000-0000-000000000001"
  @model_content_limit 12_288
  @fields [
    :actor,
    :can_react,
    :content,
    :destination,
    :event_kind,
    :event_ref,
    :native_input_id,
    :occurred_at,
    :occurred_at_source,
    :revision,
    :source,
    :source_item_ref
  ]
  @event_kinds [:message, :edit, :delete, :event]
  @occurred_at_sources [:source, :ingress]
  @actor_kinds [:user, :app, :bot, :system]
  @source_kinds [:slack, :webhook]

  @enforce_keys @fields
  defstruct @fields

  @type actor :: %{kind: :user | :app | :bot | :system, ref: String.t()}
  @type source :: %{kind: :slack | :webhook, ref: String.t()}
  @type destination :: %{
          transport: String.t(),
          conversation_ref: String.t(),
          thread_ref: String.t() | nil
        }
  @type t :: %__MODULE__{
          actor: actor(),
          can_react: boolean(),
          content: map(),
          destination: destination(),
          event_kind: :message | :edit | :delete | :event,
          event_ref: String.t(),
          native_input_id: String.t(),
          occurred_at: DateTime.t(),
          occurred_at_source: :source | :ingress,
          revision: pos_integer(),
          source: source(),
          source_item_ref: String.t() | nil
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attributes) do
    with {:ok, attributes} <- normalize_attributes(attributes),
         input <- struct!(__MODULE__, attributes),
         input <- normalize(input),
         :ok <- validate(input) do
      {:ok, input}
    end
  end

  @spec prepare(t()) :: {:ok, t()} | {:error, term()}
  def prepare(%__MODULE__{} = input) do
    input
    |> Map.from_struct()
    |> new()
  end

  def prepare(_input), do: {:error, {:invalid_input, :type}}

  @spec dedupe_key(t()) :: String.t()
  def dedupe_key(%__MODULE__{} = input) do
    digest =
      CanonicalJSON.digest([Atom.to_string(input.source.kind), input.source.ref, input.event_ref])

    "ingress-event:#{digest}"
  end

  @spec fingerprint(t()) :: String.t()
  def fingerprint(%__MODULE__{} = input) do
    input
    |> fingerprint_document()
    |> CanonicalJSON.digest()
  end

  @spec document(t()) :: map()
  def document(%__MODULE__{} = input) do
    %{
      "actor" => %{"kind" => Atom.to_string(input.actor.kind), "ref" => input.actor.ref},
      "can_react" => input.can_react,
      "content" => input.content,
      "event_kind" => Atom.to_string(input.event_kind),
      "event_ref" => input.event_ref,
      "native_input_id" => input.native_input_id,
      "occurred_at" => DateTime.to_iso8601(input.occurred_at),
      "occurred_at_source" => Atom.to_string(input.occurred_at_source),
      "revision" => input.revision,
      "source" => %{"kind" => Atom.to_string(input.source.kind), "ref" => input.source.ref},
      "source_item_ref" => input.source_item_ref,
      "destination" => %{
        "conversation_ref" => input.destination.conversation_ref,
        "thread_ref" => input.destination.thread_ref,
        "transport" => input.destination.transport
      }
    }
  end

  @spec model_document(t()) :: map()
  def model_document(%__MODULE__{} = input) do
    %{
      "actor" => %{"kind" => Atom.to_string(input.actor.kind), "ref" => input.actor.ref},
      "content" => model_content(input.content),
      "event_kind" => Atom.to_string(input.event_kind),
      "occurred_at" => DateTime.to_iso8601(input.occurred_at),
      "source" => %{"kind" => Atom.to_string(input.source.kind), "ref" => input.source.ref}
    }
  end

  @spec allowed_actions(t()) :: [:start_episode | :continue_episode | :reply | :react | :ignore]
  def allowed_actions(%__MODULE__{can_react: true, source_item_ref: source_item_ref})
      when is_binary(source_item_ref),
      do: [:start_episode, :continue_episode, :reply, :react, :ignore]

  def allowed_actions(%__MODULE__{can_react: false}),
    do: [:start_episode, :continue_episode, :reply, :ignore]

  @spec actor_ref(t()) :: String.t()
  def actor_ref(%__MODULE__{} = input) do
    "#{input.source.kind}:#{input.actor.kind}:#{input.actor.ref}"
  end

  defp model_content(content) do
    encoded = CanonicalJSON.encode!(content)

    if byte_size(encoded) <= @model_content_limit do
      content
    else
      %{
        "json_preview" => String.byte_slice(encoded, 0, @model_content_limit),
        "original_bytes" => byte_size(encoded),
        "truncated" => true
      }
    end
  end

  defp normalize_attributes(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes) do
      attributes |> Map.new() |> normalize_attributes()
    else
      {:error, {:invalid_input, :fields}}
    end
  end

  defp normalize_attributes(%{} = attributes) do
    if Map.keys(attributes) |> Enum.sort() == Enum.sort(@fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_input, :fields}}
  end

  defp normalize_attributes(_attributes), do: {:error, {:invalid_input, :fields}}

  defp normalize(%__MODULE__{occurred_at: %DateTime{microsecond: {microsecond, _}}} = input) do
    %{input | occurred_at: %{input.occurred_at | microsecond: {microsecond, 6}}}
  end

  defp normalize(input), do: input

  defp validate(%__MODULE__{} = input) do
    validations = [
      {valid_actor?(input.actor), :actor},
      {is_boolean(input.can_react), :can_react},
      {valid_destination?(input.destination), :destination},
      {input.event_kind in @event_kinds, :event_kind},
      {reference?(input.event_ref), :event_ref},
      {reference?(input.native_input_id), :native_input_id},
      {input.occurred_at_source in @occurred_at_sources, :occurred_at_source},
      {is_integer(input.revision) and input.revision > 0 and
         input.revision <= @maximum_revision, :revision},
      {valid_source?(input.source), :source},
      {optional_reference?(input.source_item_ref), :source_item_ref},
      {not input.can_react or not is_nil(input.source_item_ref), :source_item_ref},
      {utc_datetime?(input.occurred_at), :occurred_at}
    ]

    with :ok <- validate_fields(validations),
         :ok <- validate_content(input.content) do
      validate_episode_envelope(input)
    end
  end

  defp validate_content(content) when is_map(content) do
    case CanonicalJSON.validate(content, max_bytes: @content_limit) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_input, :content, reason}}
    end
  end

  defp validate_content(_content), do: {:error, {:invalid_input, :content}}

  defp validate_episode_envelope(input) do
    command = %Command.AdmitInput{
      actor_ref: actor_ref(input),
      destination: input.destination,
      episode_id: @envelope_episode_id,
      episode_key: "ingress-input-envelope",
      linked_episode_id: nil,
      native_input_id: input.native_input_id,
      occurred_at: input.occurred_at,
      payload: document(input),
      revision: input.revision,
      turn_ref: "ingress-input-envelope-turn"
    }

    case Command.prepare(command) do
      {:ok, _command} -> :ok
      {:error, {:invalid_command, field}} -> {:error, {:invalid_input, :episode_envelope, field}}
    end
  end

  # Webhook occurrence time is optional and may be assigned by Responder. It is
  # therefore receipt metadata, not part of the sender's retry identity. The
  # stable event id, revision, actor, content, and destination still conflict if
  # a sender reuses an event id for different work.
  defp fingerprint_document(
         %__MODULE__{source: %{kind: :webhook}, occurred_at_source: :ingress} = input
       ) do
    input |> document() |> Map.delete("occurred_at")
  end

  defp fingerprint_document(input), do: document(input)

  defp validate_fields(fields) do
    Enum.reduce_while(fields, :ok, fn
      {true, _field}, :ok -> {:cont, :ok}
      {false, field}, :ok -> {:halt, {:error, {:invalid_input, field}}}
    end)
  end

  defp valid_actor?(%{kind: kind, ref: ref} = actor) when kind in @actor_kinds,
    do: map_size(actor) == 2 and reference?(ref)

  defp valid_actor?(_actor), do: false

  defp valid_source?(%{kind: kind, ref: ref} = source) when kind in @source_kinds,
    do: map_size(source) == 2 and reference?(ref)

  defp valid_source?(_source), do: false

  defp valid_destination?(
         %{transport: transport, conversation_ref: conversation, thread_ref: thread} = destination
       ) do
    map_size(destination) == 3 and reference?(transport) and reference?(conversation) and
      optional_reference?(thread)
  end

  defp valid_destination?(_destination), do: false

  defp optional_reference?(nil), do: true
  defp optional_reference?(value), do: reference?(value)

  defp reference?(value) do
    is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      String.trim(value) != "" and byte_size(value) <= 1_024
  end

  defp utc_datetime?(%DateTime{} = value) do
    value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0
  end

  defp utc_datetime?(_value), do: false
end
