defmodule Responder.Slack.Input do
  @moduledoc """
  One normalized Slack event at the trusted ingress boundary.

  Slack identifiers own deduplication and routing. Message content remains
  arbitrary bounded JSON for the model to interpret; it cannot choose an
  episode or destination by smuggling routing fields into that content.
  """

  alias Responder.CanonicalJSON
  alias Responder.Episodes.Command

  # The episode command that carries this content has a 64 KiB bound. Keeping
  # content below 48 KiB leaves room for Slack identity and actor metadata, so
  # an input accepted here cannot fail only when it reaches the kernel.
  @content_limit 49_152
  @envelope_episode_id "00000000-0000-0000-0000-000000000001"
  @model_content_limit 12_288
  @fields [
    :actor,
    :channel_ref,
    :content,
    :event_kind,
    :event_ref,
    :message_ref,
    :occurred_at,
    :revision,
    :thread_ref,
    :workspace_ref
  ]
  @event_kinds [:message, :edit, :delete]
  @actor_kinds [:user, :app, :bot]

  @enforce_keys @fields
  defstruct @fields

  @type actor :: %{kind: :user | :app | :bot, ref: String.t()}
  @type t :: %__MODULE__{
          actor: actor(),
          channel_ref: String.t(),
          content: map(),
          event_kind: :message | :edit | :delete,
          event_ref: String.t(),
          message_ref: String.t(),
          occurred_at: DateTime.t(),
          revision: pos_integer(),
          thread_ref: String.t() | nil,
          workspace_ref: String.t()
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

  @spec destination(t()) :: map()
  def destination(%__MODULE__{} = input) do
    %{
      conversation_ref: "slack:#{input.workspace_ref}:#{input.channel_ref}",
      thread_ref: input.thread_ref || input.message_ref,
      transport: "slack"
    }
  end

  @spec actor_ref(t()) :: String.t()
  def actor_ref(%__MODULE__{} = input), do: "slack:#{input.actor.kind}:#{input.actor.ref}"

  @spec dedupe_key(t()) :: String.t()
  def dedupe_key(%__MODULE__{} = input) do
    digest = CanonicalJSON.digest([input.workspace_ref, input.event_ref])
    "slack-event:#{digest}"
  end

  @spec message_key(t()) :: String.t()
  def message_key(%__MODULE__{} = input) do
    digest =
      CanonicalJSON.digest([input.workspace_ref, input.channel_ref, input.message_ref])

    "slack-message:#{digest}"
  end

  @spec fingerprint(t()) :: String.t()
  def fingerprint(%__MODULE__{} = input), do: input |> document() |> CanonicalJSON.digest()

  @spec document(t()) :: map()
  def document(%__MODULE__{} = input) do
    %{
      "actor" => %{"kind" => Atom.to_string(input.actor.kind), "ref" => input.actor.ref},
      "channel_ref" => input.channel_ref,
      "content" => input.content,
      "event_kind" => Atom.to_string(input.event_kind),
      "event_ref" => input.event_ref,
      "message_ref" => input.message_ref,
      "occurred_at" => DateTime.to_iso8601(input.occurred_at),
      "revision" => input.revision,
      "thread_ref" => input.thread_ref,
      "workspace_ref" => input.workspace_ref
    }
  end

  @spec model_document(t()) :: map()
  def model_document(%__MODULE__{} = input) do
    %{
      "actor" => %{"kind" => Atom.to_string(input.actor.kind), "ref" => input.actor.ref},
      "content" => model_content(input.content),
      "event_kind" => Atom.to_string(input.event_kind),
      "is_thread_reply" => not is_nil(input.thread_ref),
      "occurred_at" => DateTime.to_iso8601(input.occurred_at)
    }
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
      {reference?(input.channel_ref), :channel_ref},
      {input.event_kind in @event_kinds, :event_kind},
      {reference?(input.event_ref), :event_ref},
      {reference?(input.message_ref), :message_ref},
      {optional_reference?(input.thread_ref), :thread_ref},
      {reference?(input.workspace_ref), :workspace_ref},
      {is_integer(input.revision) and input.revision > 0, :revision},
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
      destination: destination(input),
      episode_id: @envelope_episode_id,
      episode_key: "slack-input-envelope",
      linked_episode_id: nil,
      native_input_id: message_key(input),
      occurred_at: input.occurred_at,
      payload: document(input),
      revision: input.revision,
      turn_ref: "slack-input-envelope-turn"
    }

    case Command.prepare(command) do
      {:ok, _command} -> :ok
      {:error, {:invalid_command, field}} -> {:error, {:invalid_input, :episode_envelope, field}}
    end
  end

  defp validate_fields(fields) do
    Enum.reduce_while(fields, :ok, fn
      {true, _field}, :ok -> {:cont, :ok}
      {false, field}, :ok -> {:halt, {:error, {:invalid_input, field}}}
    end)
  end

  defp valid_actor?(%{kind: kind, ref: ref} = actor) when kind in @actor_kinds,
    do: map_size(actor) == 2 and reference?(ref)

  defp valid_actor?(_actor), do: false

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
