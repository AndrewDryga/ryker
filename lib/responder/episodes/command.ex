defmodule Responder.Episodes.Command do
  @moduledoc """
  Commands accepted by the episode kernel.

  Their identities come from owning-system references. Their fingerprints cover
  the full command so a lost response can be retried safely, while changed
  content in the same natural slot becomes an explicit conflict.

  `transfer_ref`, `wait_ref`, `result_ref`, and delivery refs are host-issued
  occurrence identities. The trusted caller never reuses one for a later
  transition; retrying the same occurrence returns its stored event.
  `resolution_ref` is the exact dedupe key returned by the admitted input that
  triggered a wait, so unrelated queued input cannot wake it.
  """

  alias Responder.CanonicalJSON

  defmodule AdmitInput do
    @moduledoc false
    @enforce_keys [
      :actor_ref,
      :destination,
      :episode_id,
      :episode_key,
      :native_input_id,
      :occurred_at,
      :payload,
      :revision,
      :turn_ref
    ]
    defstruct @enforce_keys ++ [execution_mode: :live, linked_episode_id: nil]

    @type t :: %__MODULE__{
            actor_ref: String.t(),
            destination: map(),
            episode_id: Ecto.UUID.t(),
            episode_key: String.t(),
            execution_mode: :live | :shadow,
            linked_episode_id: Ecto.UUID.t() | nil,
            native_input_id: String.t(),
            occurred_at: DateTime.t(),
            payload: map(),
            revision: pos_integer(),
            turn_ref: String.t()
          }
  end

  defmodule TransferOwner do
    @moduledoc false
    @enforce_keys [:episode_key, :expected_owner, :new_owner, :occurred_at, :transfer_ref]
    defstruct @enforce_keys ++ [required_input_ref: nil]

    @type t :: %__MODULE__{
            episode_key: String.t(),
            expected_owner: map(),
            new_owner: map(),
            occurred_at: DateTime.t(),
            required_input_ref: String.t() | nil,
            transfer_ref: String.t()
          }
  end

  defmodule StartWait do
    @moduledoc false
    @enforce_keys [:episode_key, :expected_turn_ref, :kind, :occurred_at, :wait_ref]
    defstruct @enforce_keys ++ [deadline_at: nil]

    @type t :: %__MODULE__{
            deadline_at: DateTime.t() | nil,
            episode_key: String.t(),
            expected_turn_ref: String.t(),
            kind: :input | :event,
            occurred_at: DateTime.t(),
            wait_ref: String.t()
          }
  end

  defmodule ResumeWait do
    @moduledoc false
    @enforce_keys [:episode_key, :expected_wait, :occurred_at, :resolution_ref, :turn_ref]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            episode_key: String.t(),
            expected_wait: map(),
            occurred_at: DateTime.t(),
            resolution_ref: String.t(),
            turn_ref: String.t()
          }
  end

  defmodule AcceptResult do
    @moduledoc false
    @enforce_keys [
      :delivery,
      :episode_key,
      :expected_turn_ref,
      :occurred_at,
      :result_ref
    ]
    defstruct @enforce_keys ++
                [decision_reason: nil, delivery_ref: nil, next_turn_ref: nil, next_wait: nil]

    @type t :: %__MODULE__{
            decision_reason: String.t() | nil,
            delivery: :reply | :none,
            delivery_ref: String.t() | nil,
            episode_key: String.t(),
            expected_turn_ref: String.t(),
            next_turn_ref: String.t() | nil,
            next_wait: map() | nil,
            occurred_at: DateTime.t(),
            result_ref: String.t()
          }
  end

  defmodule ConfirmDelivery do
    @moduledoc false
    @enforce_keys [:episode_key, :expected_delivery_ref, :occurred_at]
    defstruct @enforce_keys ++ [next_turn_ref: nil, next_wait: nil]

    @type t :: %__MODULE__{
            episode_key: String.t(),
            expected_delivery_ref: String.t(),
            next_turn_ref: String.t() | nil,
            next_wait: map() | nil,
            occurred_at: DateTime.t()
          }
  end

  defmodule CancelEpisode do
    @moduledoc false
    @enforce_keys [:cancel_ref, :episode_key, :expected_owner, :occurred_at, :reason]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            cancel_ref: String.t(),
            episode_key: String.t(),
            expected_owner: map(),
            occurred_at: DateTime.t(),
            reason: String.t()
          }
  end

  defmodule RecordReaction do
    @moduledoc false
    @enforce_keys [
      :action,
      :actor_ref,
      :emoji_name,
      :episode_key,
      :event_ref,
      :occurred_at,
      :source,
      :target_delivery_ref,
      :target_message_ref
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            action: :add | :remove,
            actor_ref: String.t(),
            emoji_name: String.t(),
            episode_key: String.t(),
            event_ref: String.t(),
            occurred_at: DateTime.t(),
            source: %{kind: String.t(), ref: String.t()},
            target_delivery_ref: String.t(),
            target_message_ref: String.t()
          }
  end

  @type t ::
          AdmitInput.t()
          | TransferOwner.t()
          | StartWait.t()
          | ResumeWait.t()
          | AcceptResult.t()
          | ConfirmDelivery.t()
          | CancelEpisode.t()
          | RecordReaction.t()

  @doc """
  Normalizes valid timestamps to the precision required by durable storage.

  Elixir DateTimes preserve the precision of their input text, so the same
  instant may arrive as either whole seconds or six-digit microseconds. The
  kernel uses one representation for fingerprints, replay, and Postgres.
  """
  @spec normalize(t()) :: t()
  def normalize(%StartWait{} = command) do
    %{
      command
      | deadline_at: normalize_datetime(command.deadline_at),
        occurred_at: normalize_datetime(command.occurred_at)
    }
  end

  def normalize(%AdmitInput{} = command) do
    %{
      command
      | episode_id: normalize_uuid(command.episode_id),
        linked_episode_id: normalize_uuid(command.linked_episode_id),
        occurred_at: normalize_datetime(command.occurred_at)
    }
  end

  def normalize(%TransferOwner{} = command) do
    %{command | occurred_at: normalize_datetime(command.occurred_at)}
  end

  def normalize(%ResumeWait{} = command) do
    %{command | occurred_at: normalize_datetime(command.occurred_at)}
  end

  def normalize(%AcceptResult{} = command) do
    %{
      command
      | next_wait: normalize_wait(command.next_wait),
        occurred_at: normalize_datetime(command.occurred_at)
    }
  end

  def normalize(%ConfirmDelivery{} = command) do
    %{
      command
      | next_wait: normalize_wait(command.next_wait),
        occurred_at: normalize_datetime(command.occurred_at)
    }
  end

  def normalize(%CancelEpisode{} = command) do
    %{command | occurred_at: normalize_datetime(command.occurred_at)}
  end

  def normalize(%RecordReaction{} = command) do
    %{command | occurred_at: normalize_datetime(command.occurred_at)}
  end

  def normalize(command), do: command

  @doc false
  @spec bind_episode(t(), map() | nil) :: t()
  def bind_episode(%AdmitInput{} = command, %{id: id}), do: %{command | episode_id: id}
  def bind_episode(command, _episode), do: command

  @spec prepare(term()) :: {:ok, t()} | {:error, term()}
  def prepare(command) do
    command = normalize(command)

    case validate(command) do
      :ok -> {:ok, command}
      {:error, _reason} = error -> error
    end
  end

  @spec dedupe_key(t()) :: String.t()
  def dedupe_key(command) do
    command
    |> identity()
    |> CanonicalJSON.digest()
    |> then(&"#{kind(command)}:#{&1}")
  end

  @spec document(t()) :: map()
  def document(%AdmitInput{} = command) do
    %{
      "actor_ref" => command.actor_ref,
      "destination" => stringify_keys(command.destination),
      "episode_id" => command.episode_id,
      "episode_key" => command.episode_key,
      "execution_mode" => Atom.to_string(command.execution_mode),
      "kind" => "admit_input",
      "linked_episode_id" => command.linked_episode_id,
      "native_input_id" => command.native_input_id,
      "occurred_at" => iso8601(command.occurred_at),
      "payload" => command.payload,
      "revision" => command.revision,
      "turn_ref" => command.turn_ref
    }
  end

  def document(%TransferOwner{} = command) do
    document = %{
      "episode_key" => command.episode_key,
      "expected_owner" => stringify_keys(command.expected_owner),
      "kind" => "transfer_owner",
      "new_owner" => stringify_keys(command.new_owner),
      "occurred_at" => iso8601(command.occurred_at),
      "transfer_ref" => command.transfer_ref
    }

    if command.required_input_ref,
      do: Map.put(document, "required_input_ref", command.required_input_ref),
      else: document
  end

  def document(%StartWait{} = command) do
    %{
      "deadline_at" => iso8601(command.deadline_at),
      "episode_key" => command.episode_key,
      "expected_turn_ref" => command.expected_turn_ref,
      "kind" => "start_wait",
      "occurred_at" => iso8601(command.occurred_at),
      "wait_kind" => Atom.to_string(command.kind),
      "wait_ref" => command.wait_ref
    }
  end

  def document(%ResumeWait{} = command) do
    %{
      "episode_key" => command.episode_key,
      "expected_wait" => stringify_keys(command.expected_wait),
      "kind" => "resume_wait",
      "occurred_at" => iso8601(command.occurred_at),
      "resolution_ref" => command.resolution_ref,
      "turn_ref" => command.turn_ref
    }
  end

  def document(%AcceptResult{} = command) do
    document = %{
      "delivery" => Atom.to_string(command.delivery),
      "decision_reason" => command.decision_reason,
      "delivery_ref" => command.delivery_ref,
      "episode_key" => command.episode_key,
      "expected_turn_ref" => command.expected_turn_ref,
      "kind" => "accept_result",
      "next_turn_ref" => command.next_turn_ref,
      "occurred_at" => iso8601(command.occurred_at),
      "result_ref" => command.result_ref
    }

    if command.next_wait,
      do: Map.put(document, "next_wait", wait_document(command.next_wait)),
      else: document
  end

  def document(%ConfirmDelivery{} = command) do
    document = %{
      "episode_key" => command.episode_key,
      "expected_delivery_ref" => command.expected_delivery_ref,
      "kind" => "confirm_delivery",
      "next_turn_ref" => command.next_turn_ref,
      "occurred_at" => iso8601(command.occurred_at)
    }

    if command.next_wait,
      do: Map.put(document, "next_wait", wait_document(command.next_wait)),
      else: document
  end

  def document(%CancelEpisode{} = command) do
    %{
      "cancel_ref" => command.cancel_ref,
      "episode_key" => command.episode_key,
      "expected_owner" => stringify_keys(command.expected_owner),
      "kind" => "cancel_episode",
      "occurred_at" => iso8601(command.occurred_at),
      "reason" => command.reason
    }
  end

  def document(%RecordReaction{} = command) do
    %{
      "action" => Atom.to_string(command.action),
      "actor_ref" => command.actor_ref,
      "emoji_name" => command.emoji_name,
      "episode_key" => command.episode_key,
      "event_ref" => command.event_ref,
      "kind" => "record_reaction",
      "occurred_at" => iso8601(command.occurred_at),
      "source" => stringify_keys(command.source),
      "target_delivery_ref" => command.target_delivery_ref,
      "target_message_ref" => command.target_message_ref
    }
  end

  @spec fingerprint(t()) :: String.t()
  def fingerprint(command), do: command |> document() |> CanonicalJSON.digest()

  @spec kind(t()) :: String.t()
  def kind(%AdmitInput{}), do: "admit_input"
  def kind(%TransferOwner{}), do: "transfer_owner"
  def kind(%StartWait{}), do: "start_wait"
  def kind(%ResumeWait{}), do: "resume_wait"
  def kind(%AcceptResult{}), do: "accept_result"
  def kind(%ConfirmDelivery{}), do: "confirm_delivery"
  def kind(%CancelEpisode{}), do: "cancel_episode"
  def kind(%RecordReaction{}), do: "record_reaction"

  defp identity(%AdmitInput{} = command) do
    [command.episode_key, command.native_input_id, command.revision]
  end

  defp identity(%TransferOwner{} = command) do
    [command.episode_key, command.transfer_ref]
  end

  defp identity(%StartWait{} = command) do
    [command.episode_key, command.wait_ref]
  end

  defp identity(%ResumeWait{} = command) do
    [command.episode_key, stringify_keys(command.expected_wait), command.resolution_ref]
  end

  defp identity(%AcceptResult{} = command) do
    [command.episode_key, command.result_ref]
  end

  defp identity(%ConfirmDelivery{} = command) do
    [command.episode_key, command.expected_delivery_ref]
  end

  defp identity(%CancelEpisode{} = command) do
    [command.episode_key, command.cancel_ref]
  end

  defp identity(%RecordReaction{} = command) do
    [command.episode_key, command.source.kind, command.source.ref, command.event_ref]
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp normalize_datetime(%DateTime{microsecond: {microsecond, _precision}} = value) do
    %{value | microsecond: {microsecond, 6}}
  end

  defp normalize_datetime(value), do: value

  defp normalize_uuid(nil), do: nil

  defp normalize_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, normalized} -> normalized
      :error -> value
    end
  end

  defp stringify_keys(%{} = value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp stringify_keys(value), do: value

  defp validate(%AdmitInput{} = command) do
    validate_fields([
      {reference?(command.episode_key), :episode_key},
      {uuid?(command.episode_id), :episode_id},
      {optional_uuid?(command.linked_episode_id) and
         command.linked_episode_id != command.episode_id, :linked_episode_id},
      {reference?(command.actor_ref), :actor_ref},
      {reference?(command.native_input_id), :native_input_id},
      {reference?(command.turn_ref), :turn_ref},
      {command.execution_mode in [:live, :shadow], :execution_mode},
      {is_integer(command.revision) and command.revision >= 1, :revision},
      {valid_destination?(command.destination), :destination},
      {is_map(command.payload) and
         CanonicalJSON.validate(command.payload, max_bytes: 65_536) == :ok, :payload},
      {utc_datetime?(command.occurred_at), :occurred_at}
    ])
  end

  defp validate(%TransferOwner{} = command) do
    validate_fields([
      {reference?(command.episode_key), :episode_key},
      {valid_owner?(command.expected_owner), :expected_owner},
      {valid_owner?(command.new_owner), :new_owner},
      {optional_ref?(command.required_input_ref), :required_input_ref},
      {reference?(command.transfer_ref), :transfer_ref},
      {utc_datetime?(command.occurred_at), :occurred_at}
    ])
  end

  defp validate(%StartWait{} = command) do
    validate_fields([
      {reference?(command.episode_key), :episode_key},
      {reference?(command.expected_turn_ref), :expected_turn_ref},
      {command.kind in [:input, :event], :kind},
      {reference?(command.wait_ref), :wait_ref},
      {command.kind != :input or is_nil(command.deadline_at), :deadline_at},
      {is_nil(command.deadline_at) or utc_datetime?(command.deadline_at), :deadline_at},
      {utc_datetime?(command.occurred_at), :occurred_at}
    ])
  end

  defp validate(%ResumeWait{} = command) do
    validate_fields([
      {reference?(command.episode_key), :episode_key},
      {valid_wait_owner?(command.expected_wait), :expected_wait},
      {reference?(command.resolution_ref), :resolution_ref},
      {reference?(command.turn_ref), :turn_ref},
      {utc_datetime?(command.occurred_at), :occurred_at}
    ])
  end

  defp validate(%AcceptResult{} = command) do
    validate_fields([
      {reference?(command.episode_key), :episode_key},
      {reference?(command.expected_turn_ref), :expected_turn_ref},
      {reference?(command.result_ref), :result_ref},
      {command.delivery in [:reply, :none], :delivery},
      {valid_delivery_ref?(command), :delivery_ref},
      {valid_decision_reason?(command), :decision_reason},
      {valid_accept_next_ref?(command), :next_turn_ref},
      {valid_next_wait?(command.next_wait), :next_wait},
      {is_nil(command.next_wait) or command.delivery == :none, :next_wait},
      {is_nil(command.next_turn_ref) or is_nil(command.next_wait), :continuation},
      {utc_datetime?(command.occurred_at), :occurred_at}
    ])
  end

  defp validate(%ConfirmDelivery{} = command) do
    validate_fields([
      {reference?(command.episode_key), :episode_key},
      {reference?(command.expected_delivery_ref), :expected_delivery_ref},
      {optional_ref?(command.next_turn_ref), :next_turn_ref},
      {valid_next_wait?(command.next_wait), :next_wait},
      {is_nil(command.next_turn_ref) or is_nil(command.next_wait), :continuation},
      {utc_datetime?(command.occurred_at), :occurred_at}
    ])
  end

  defp validate(%CancelEpisode{} = command) do
    validate_fields([
      {reference?(command.episode_key), :episode_key},
      {valid_owner?(command.expected_owner), :expected_owner},
      {reference?(command.cancel_ref), :cancel_ref},
      {bounded_text?(command.reason, 512), :reason},
      {utc_datetime?(command.occurred_at), :occurred_at}
    ])
  end

  defp validate(%RecordReaction{} = command) do
    validate_fields([
      {reference?(command.episode_key), :episode_key},
      {command.action in [:add, :remove], :action},
      {reference?(command.actor_ref), :actor_ref},
      {emoji_name?(command.emoji_name), :emoji_name},
      {reference?(command.event_ref), :event_ref},
      {valid_reaction_source?(command.source), :source},
      {reference?(command.target_delivery_ref), :target_delivery_ref},
      {reference?(command.target_message_ref), :target_message_ref},
      {utc_datetime?(command.occurred_at), :occurred_at}
    ])
  end

  defp validate(_command), do: {:error, {:invalid_command, :type}}

  defp validate_fields(fields) do
    Enum.reduce_while(fields, :ok, fn
      {true, _field}, :ok -> {:cont, :ok}
      {false, field}, :ok -> {:halt, {:error, {:invalid_command, field}}}
    end)
  end

  defp valid_destination?(
         %{
           conversation_ref: conversation,
           thread_ref: thread,
           transport: transport
         } = destination
       ) do
    exact_keys?(destination, [:conversation_ref, :thread_ref, :transport]) and
      reference?(conversation) and optional_ref?(thread) and reference?(transport)
  end

  defp valid_destination?(_destination), do: false

  defp valid_owner?(%{kind: kind, ref: ref} = owner)
       when kind in [:turn, :delivery, :input, :event],
       do: exact_keys?(owner, [:kind, :ref]) and reference?(ref)

  defp valid_owner?(_owner), do: false

  defp valid_reaction_source?(%{kind: kind, ref: ref} = source) do
    exact_keys?(source, [:kind, :ref]) and reference?(kind) and reference?(ref)
  end

  defp valid_reaction_source?(_source), do: false

  defp emoji_name?(value) do
    is_binary(value) and byte_size(value) <= 100 and
      Regex.match?(~r/\A[a-z0-9_+\-]+\z/, value)
  end

  defp valid_wait_owner?(%{kind: kind, ref: ref} = owner) when kind in [:input, :event],
    do: exact_keys?(owner, [:kind, :ref]) and reference?(ref)

  defp valid_wait_owner?(_wait), do: false

  defp exact_keys?(map, expected) do
    map_size(map) == length(expected) and Enum.all?(expected, &Map.has_key?(map, &1))
  end

  defp valid_delivery_ref?(%AcceptResult{delivery: :reply, delivery_ref: ref}),
    do: reference?(ref)

  defp valid_delivery_ref?(%AcceptResult{delivery: :none, delivery_ref: nil}), do: true
  defp valid_delivery_ref?(_command), do: false

  defp valid_decision_reason?(%AcceptResult{delivery: :reply, decision_reason: nil}), do: true

  defp valid_decision_reason?(%AcceptResult{delivery: :none, decision_reason: reason}),
    do: bounded_unicode_text?(reason, 240, 960)

  defp valid_decision_reason?(_command), do: false

  defp valid_accept_next_ref?(%AcceptResult{delivery: :reply, next_turn_ref: nil}), do: true

  defp valid_accept_next_ref?(%AcceptResult{delivery: :none, next_turn_ref: ref}),
    do: optional_ref?(ref)

  defp valid_accept_next_ref?(_command), do: false

  defp valid_next_wait?(nil), do: true

  defp valid_next_wait?(%{kind: :input, ref: ref, deadline_at: nil} = wait),
    do: exact_keys?(wait, [:deadline_at, :kind, :ref]) and reference?(ref)

  defp valid_next_wait?(%{kind: :event, ref: ref, deadline_at: nil} = wait),
    do: exact_keys?(wait, [:deadline_at, :kind, :ref]) and reference?(ref)

  defp valid_next_wait?(%{kind: :event, ref: ref, deadline_at: %DateTime{} = deadline} = wait),
    do:
      exact_keys?(wait, [:deadline_at, :kind, :ref]) and reference?(ref) and
        utc_datetime?(deadline)

  defp valid_next_wait?(_wait), do: false

  defp normalize_wait(nil), do: nil

  defp normalize_wait(%{deadline_at: deadline_at} = wait),
    do: %{wait | deadline_at: normalize_datetime(deadline_at)}

  defp normalize_wait(wait), do: wait

  defp wait_document(%{deadline_at: deadline_at, kind: kind, ref: ref}) do
    %{
      "deadline_at" => iso8601(deadline_at),
      "kind" => Atom.to_string(kind),
      "ref" => ref
    }
  end

  defp reference?(value), do: bounded_text?(value, 1_024)
  defp optional_ref?(nil), do: true
  defp optional_ref?(value), do: reference?(value)
  defp optional_uuid?(nil), do: true
  defp optional_uuid?(value), do: uuid?(value)

  defp bounded_text?(value, maximum) do
    is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      String.trim(value) != "" and byte_size(value) <= maximum
  end

  defp bounded_unicode_text?(value, maximum_characters, maximum_bytes) do
    is_binary(value) and String.valid?(value) and
      String.length(value) in 1..maximum_characters and byte_size(value) <= maximum_bytes and
      :binary.match(value, <<0>>) == :nomatch and String.trim(value) != ""
  end

  defp utc_datetime?(%DateTime{} = value) do
    value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0
  end

  defp utc_datetime?(_value), do: false

  defp uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))
end
