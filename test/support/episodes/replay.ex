defmodule Ryker.Episodes.Replay do
  @moduledoc """
  Offline replay of harvested episode commands.

  Replay uses the production reducer directly, starts no application, touches no
  database, and rejects unknown commands. This is the deterministic regression
  lane; model behavior belongs in a separate eval lane.
  """

  alias Ryker.CanonicalJSON
  alias Ryker.Episodes.Command

  alias Ryker.Episodes.Command.{
    AcceptResult,
    AdmitInput,
    CancelEpisode,
    ConfirmDelivery,
    ResumeWait,
    StartWait,
    TransferOwner
  }

  alias Ryker.Episodes.{Kernel, Snapshot}

  defmodule Result do
    @moduledoc false
    @enforce_keys [:checkpoints, :episode, :events, :events_by_key, :linked_results]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            checkpoints: [map()],
            episode: Ryker.Episodes.Episode.t() | nil,
            events: [Ryker.Episodes.Event.t()],
            events_by_key: %{optional(String.t()) => Ryker.Episodes.Event.t()},
            linked_results: [t()]
          }
  end

  @spec encode_result!(Result.t()) :: String.t()
  def encode_result!(%Result{} = result) do
    result
    |> full_view()
    |> CanonicalJSON.encode!()
  end

  @spec encode_golden!(Result.t()) :: String.t()
  def encode_golden!(%Result{} = result) do
    result
    |> encode_result!()
    |> Jason.Formatter.pretty_print()
    |> then(&(&1 <> "\n"))
  end

  @spec read!(Path.t()) :: map()
  def read!(path) do
    path
    |> File.read!()
    |> decode!()
  end

  @spec decode!(iodata()) :: map()
  def decode!(json) do
    json
    |> Jason.decode!(objects: :ordered_objects)
    |> normalize_json!("$")
  end

  @spec run!(map()) :: Result.t()
  def run!(fixture) when is_map(fixture) do
    run_fixture!(fixture, &apply_pure/2)
  end

  def run!(_fixture), do: raise(ArgumentError, "fixture must be an object")

  @spec run_with!(map(), (Command.t() -> {:ok, map()} | {:error, term()})) :: Result.t()
  def run_with!(fixture, execute) when is_map(fixture) and is_function(execute, 1) do
    run_fixture!(fixture, fn _result, command -> execute.(command) end)
  end

  @spec commands!(map()) :: [Command.t()]
  def commands!(fixture) when is_map(fixture) do
    assert_fields!(fixture, ["schema_version", "source", "commands", "expected"], ["setup"])
    schema_version!(fixture["schema_version"])
    commands = fixture["commands"]
    if not is_list(commands), do: raise(ArgumentError, "fixture commands must be an array")

    decoded = Enum.map(commands, &decode_command!/1)
    validate_fixture_metadata!(fixture)
    decoded
  end

  def commands!(_fixture), do: raise(ArgumentError, "fixture must be an object")

  @spec setup_commands!(map()) :: [[Command.t()]]
  def setup_commands!(fixture) do
    fixture
    |> Map.get("setup", [])
    |> case do
      groups when is_list(groups) ->
        Enum.map(groups, fn
          commands when is_list(commands) -> Enum.map(commands, &decode_command!/1)
          _value -> raise ArgumentError, "fixture setup entries must be command arrays"
        end)

      _value ->
        raise ArgumentError, "fixture setup must be an array"
    end
  end

  @spec view(Result.t()) :: map()
  def view(%Result{} = result) do
    snapshot = Snapshot.from_episode(result.episode)

    %{
      "active_input_count" => length(result.episode.active_input_refs),
      "destination" => snapshot["destination"],
      "event_count" => length(result.events),
      "event_kinds" => Enum.map(result.events, &Atom.to_string(&1.kind)),
      "linked_episode_id" => snapshot["linked_episode_id"],
      "owner" => snapshot["owner"],
      "queued_input_count" => length(result.episode.queued_input_refs),
      "semantic_version" => snapshot["semantic_version"],
      "state" => snapshot["state"]
    }
  end

  defp run_fixture!(fixture, execute) do
    commands = commands!(fixture)
    setup = setup_commands!(fixture)

    linked_results =
      setup
      |> Enum.map(&run_commands!(&1, execute))

    result = run_commands!(commands, execute)
    validate_linked_history!(result, linked_results)
    %{result | linked_results: linked_results}
  end

  defp run_commands!(commands, execute) do
    commands
    |> Enum.with_index(1)
    |> Enum.reduce(new_result(), fn {command, index}, result ->
      apply_command!(result, command, index, execute)
    end)
  end

  defp new_result do
    %Result{checkpoints: [], episode: nil, events: [], events_by_key: %{}, linked_results: []}
  end

  defp apply_pure(result, command) do
    dedupe_key = Command.dedupe_key(command)
    existing_event = Map.get(result.events_by_key, dedupe_key)
    Kernel.apply(result.episode, existing_event, command)
  end

  defp apply_command!(result, command, index, execute) do
    case execute.(result, command) do
      {:ok, %{status: :duplicate, episode: episode}} ->
        result
        |> Map.put(:episode, episode)
        |> checkpoint(command, index, :duplicate)

      {:ok, %{status: :applied, episode: episode, event: event}} ->
        result
        |> Map.put(:episode, episode)
        |> Map.update!(:events, &(&1 ++ [event]))
        |> Map.update!(:events_by_key, &Map.put(&1, event.dedupe_key, event))
        |> checkpoint(command, index, :applied)

      {:error, reason} ->
        raise ArgumentError, "episode command #{index} failed: #{inspect(reason)}"
    end
  end

  defp checkpoint(result, command, index, status) do
    value = %{
      "command" => index,
      "command_kind" => Command.kind(command),
      "episode" => Snapshot.from_episode(result.episode),
      "event_count" => length(result.events),
      "status" => Atom.to_string(status)
    }

    Map.update!(result, :checkpoints, &(&1 ++ [value]))
  end

  defp decode_command!(%{"type" => "admit_input"} = value) do
    assert_fields!(
      value,
      [
        "type",
        "actor_ref",
        "destination",
        "episode_id",
        "episode_key",
        "native_input_id",
        "occurred_at",
        "payload",
        "revision",
        "turn_ref"
      ],
      ["linked_episode_id"]
    )

    struct!(AdmitInput, %{
      actor_ref: required!(value, "actor_ref"),
      destination: destination!(required!(value, "destination")),
      episode_id: required!(value, "episode_id"),
      episode_key: required!(value, "episode_key"),
      linked_episode_id: Map.get(value, "linked_episode_id"),
      native_input_id: required!(value, "native_input_id"),
      occurred_at: timestamp!(required!(value, "occurred_at")),
      payload: required!(value, "payload"),
      revision: required!(value, "revision"),
      turn_ref: required!(value, "turn_ref")
    })
  end

  defp decode_command!(%{"type" => "transfer_owner"} = value) do
    assert_fields!(
      value,
      ["type", "episode_key", "expected_owner", "new_owner", "occurred_at", "transfer_ref"],
      []
    )

    struct!(TransferOwner, %{
      episode_key: required!(value, "episode_key"),
      expected_owner: owner!(required!(value, "expected_owner")),
      new_owner: owner!(required!(value, "new_owner")),
      occurred_at: timestamp!(required!(value, "occurred_at")),
      transfer_ref: required!(value, "transfer_ref")
    })
  end

  defp decode_command!(%{"type" => "cancel_episode"} = value) do
    assert_fields!(
      value,
      ["type", "cancel_ref", "episode_key", "expected_owner", "occurred_at", "reason"],
      []
    )

    struct!(CancelEpisode, %{
      cancel_ref: required!(value, "cancel_ref"),
      episode_key: required!(value, "episode_key"),
      expected_owner: owner!(required!(value, "expected_owner")),
      occurred_at: timestamp!(required!(value, "occurred_at")),
      reason: required!(value, "reason")
    })
  end

  defp decode_command!(%{"type" => "start_wait"} = value) do
    assert_fields!(
      value,
      ["type", "episode_key", "expected_turn_ref", "kind", "occurred_at", "wait_ref"],
      ["deadline_at"]
    )

    struct!(StartWait, %{
      deadline_at: optional_timestamp!(Map.get(value, "deadline_at")),
      episode_key: required!(value, "episode_key"),
      expected_turn_ref: required!(value, "expected_turn_ref"),
      kind: wait_kind!(required!(value, "kind")),
      occurred_at: timestamp!(required!(value, "occurred_at")),
      wait_ref: required!(value, "wait_ref")
    })
  end

  defp decode_command!(%{"type" => "resume_wait"} = value) do
    assert_fields!(
      value,
      ["type", "episode_key", "expected_wait", "occurred_at", "resolution_ref", "turn_ref"],
      []
    )

    struct!(ResumeWait, %{
      episode_key: required!(value, "episode_key"),
      expected_wait: wait!(required!(value, "expected_wait")),
      occurred_at: timestamp!(required!(value, "occurred_at")),
      resolution_ref: required!(value, "resolution_ref"),
      turn_ref: required!(value, "turn_ref")
    })
  end

  defp decode_command!(%{"type" => "accept_result"} = value) do
    assert_fields!(
      value,
      ["type", "delivery", "episode_key", "expected_turn_ref", "occurred_at", "result_ref"],
      ["decision_reason", "delivery_ref", "next_turn_ref", "next_wait"]
    )

    struct!(AcceptResult, %{
      delivery: delivery!(required!(value, "delivery")),
      decision_reason: Map.get(value, "decision_reason"),
      next_wait: optional_next_wait!(Map.get(value, "next_wait")),
      delivery_ref: Map.get(value, "delivery_ref"),
      episode_key: required!(value, "episode_key"),
      expected_turn_ref: required!(value, "expected_turn_ref"),
      next_turn_ref: Map.get(value, "next_turn_ref"),
      occurred_at: timestamp!(required!(value, "occurred_at")),
      result_ref: required!(value, "result_ref")
    })
  end

  defp decode_command!(%{"type" => "confirm_delivery"} = value) do
    assert_fields!(
      value,
      ["type", "episode_key", "expected_delivery_ref", "occurred_at"],
      ["next_turn_ref", "next_wait"]
    )

    struct!(ConfirmDelivery, %{
      episode_key: required!(value, "episode_key"),
      expected_delivery_ref: required!(value, "expected_delivery_ref"),
      next_turn_ref: Map.get(value, "next_turn_ref"),
      next_wait: optional_next_wait!(Map.get(value, "next_wait")),
      occurred_at: timestamp!(required!(value, "occurred_at"))
    })
  end

  defp decode_command!(%{"type" => type}) do
    raise ArgumentError, "unknown episode command #{inspect(type)}"
  end

  defp decode_command!(_value), do: raise(ArgumentError, "episode command is missing type")

  defp full_view(result) do
    %{
      "checkpoints" => result.checkpoints,
      "episode" => Snapshot.from_episode(result.episode),
      "events" =>
        Enum.map(result.events, fn event ->
          %{
            "dedupe_key" => event.dedupe_key,
            "fingerprint" => event.fingerprint,
            "kind" => Atom.to_string(event.kind),
            "occurred_at" => DateTime.to_iso8601(event.occurred_at),
            "payload" => event.payload,
            "sequence" => event.sequence
          }
        end),
      "linked_history" => Enum.map(result.linked_results, &full_view/1)
    }
  end

  defp validate_linked_history!(%Result{episode: %{linked_episode_id: nil}}, []), do: :ok

  defp validate_linked_history!(%Result{episode: episode}, linked_results) do
    linked_ids = Enum.map(linked_results, & &1.episode.id)

    cond do
      episode.linked_episode_id in linked_ids ->
        :ok

      is_nil(episode.linked_episode_id) ->
        raise ArgumentError, "fixture has unused linked history"

      true ->
        raise ArgumentError, "fixture is missing linked episode #{episode.linked_episode_id}"
    end
  end

  defp validate_fixture_metadata!(fixture) do
    source = fixture["source"]
    expected = fixture["expected"]

    if not is_map(source) or CanonicalJSON.validate(source, max_bytes: 65_536) != :ok,
      do: raise(ArgumentError, "fixture source must be bounded JSON")

    validate_source!(source)

    if not is_map(expected), do: raise(ArgumentError, "fixture expected must be an object")

    assert_fields!(
      expected,
      [
        "active_input_count",
        "destination",
        "event_count",
        "event_kinds",
        "linked_episode_id",
        "owner",
        "queued_input_count",
        "semantic_version",
        "state"
      ],
      []
    )

    destination!(expected["destination"])
    validate_expected_owner!(expected["owner"])
  end

  defp validate_source!(source) do
    assert_fields!(
      source,
      ["database", "reason"],
      [
        "episode_ids",
        "incident_id",
        "observed_attempts",
        "observed_wakeups",
        "run_ids",
        "wakeup_ids"
      ]
    )

    validate_source_database!(source)
    validate_source_reason!(source)
    validate_source_references!(source)
    validate_source_counts!(source)
    validate_source_identity!(source)
  end

  defp validate_source_database!(source) do
    if source["database"] not in ["blitz responder.db", "emisar responder.db"],
      do: raise(ArgumentError, "fixture source database is unsupported")
  end

  defp validate_source_reason!(source) do
    if not bounded_text?(source["reason"], 1_024),
      do: raise(ArgumentError, "fixture source reason must be nonempty")
  end

  defp validate_source_references!(source) do
    Enum.each(["episode_ids", "run_ids", "wakeup_ids"], fn field ->
      if Map.has_key?(source, field) and not reference_list?(source[field]),
        do: raise(ArgumentError, "fixture source #{field} must be a nonempty reference array")
    end)

    if Map.has_key?(source, "incident_id") and not reference?(source["incident_id"]),
      do: raise(ArgumentError, "fixture source incident_id must be a reference")
  end

  defp validate_source_counts!(source) do
    Enum.each(["observed_attempts", "observed_wakeups"], fn field ->
      if Map.has_key?(source, field) and
           (not is_integer(source[field]) or source[field] < 0),
         do: raise(ArgumentError, "fixture source #{field} must be a nonnegative integer")
    end)
  end

  defp validate_source_identity!(source) do
    has_reference_list =
      Enum.any?(["episode_ids", "run_ids", "wakeup_ids"], &reference_list?(source[&1]))

    unless has_reference_list or reference?(source["incident_id"]),
      do: raise(ArgumentError, "fixture source must include at least one stable identity")
  end

  defp reference_list?(values) when is_list(values) and values != [],
    do: Enum.all?(values, &reference?/1)

  defp reference_list?(_values), do: false

  defp reference?(value), do: bounded_text?(value, 1_024)

  defp bounded_text?(value, maximum) do
    is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      String.trim(value) != "" and byte_size(value) <= maximum
  end

  defp validate_expected_owner!(nil), do: :ok

  defp validate_expected_owner!(%{"kind" => "event"} = value) do
    assert_fields!(value, ["deadline_at", "kind", "ref"], [])
    optional_timestamp!(Map.fetch!(value, "deadline_at"))
    required!(value, "ref")
    :ok
  end

  defp validate_expected_owner!(%{} = value) do
    owner!(value)
    :ok
  end

  defp validate_expected_owner!(_value), do: raise(ArgumentError, "invalid expected owner")

  defp optional_next_wait!(nil), do: nil

  defp optional_next_wait!(%{"deadline_at" => nil, "kind" => kind, "ref" => ref} = wait)
       when kind in ~w(input event) do
    assert_fields!(wait, ["deadline_at", "kind", "ref"], [])
    %{deadline_at: nil, kind: wait_kind!(kind), ref: ref}
  end

  defp optional_next_wait!(
         %{"deadline_at" => deadline_at, "kind" => "event", "ref" => ref} = wait
       ) do
    assert_fields!(wait, ["deadline_at", "kind", "ref"], [])
    %{deadline_at: timestamp!(deadline_at), kind: :event, ref: ref}
  end

  defp optional_next_wait!(_value), do: raise(ArgumentError, "invalid next wait")

  defp required!(value, key) do
    case Map.fetch(value, key) do
      {:ok, result} -> result
      :error -> raise ArgumentError, "episode command is missing #{inspect(key)}"
    end
  end

  defp assert_fields!(value, required, optional) do
    keys = Map.keys(value)
    missing = required -- keys
    unknown = keys -- (required ++ optional)

    if missing != [], do: raise(ArgumentError, "missing fields: #{inspect(Enum.sort(missing))}")
    if unknown != [], do: raise(ArgumentError, "unknown fields: #{inspect(Enum.sort(unknown))}")

    :ok
  end

  defp schema_version!(1), do: :ok

  defp schema_version!(version),
    do: raise(ArgumentError, "unknown fixture schema #{inspect(version)}")

  defp normalize_json!(%Jason.OrderedObject{values: values}, path) do
    keys = Enum.map(values, &elem(&1, 0))

    case keys -- Enum.uniq(keys) do
      [] ->
        Map.new(values, fn {key, value} -> {key, normalize_json!(value, "#{path}.#{key}")} end)

      [duplicate | _rest] ->
        raise ArgumentError, "duplicate JSON field #{inspect(duplicate)} at #{path}"
    end
  end

  defp normalize_json!(values, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {value, index} -> normalize_json!(value, "#{path}[#{index}]") end)
  end

  defp normalize_json!(value, _path), do: value

  defp destination!(%{} = value) do
    assert_fields!(value, ["conversation_ref", "thread_ref", "transport"], [])

    %{
      conversation_ref: required!(value, "conversation_ref"),
      thread_ref: required!(value, "thread_ref"),
      transport: required!(value, "transport")
    }
  end

  defp destination!(_value), do: raise(ArgumentError, "invalid episode destination")

  defp owner!(%{} = value) do
    assert_fields!(value, ["kind", "ref"], [])
    %{kind: owner_kind!(required!(value, "kind")), ref: required!(value, "ref")}
  end

  defp owner!(_value), do: raise(ArgumentError, "invalid episode owner")

  defp wait!(%{} = value) do
    assert_fields!(value, ["kind", "ref"], [])
    %{kind: wait_kind!(required!(value, "kind")), ref: required!(value, "ref")}
  end

  defp wait!(_value), do: raise(ArgumentError, "invalid episode wait")

  defp owner_kind!("turn"), do: :turn
  defp owner_kind!("delivery"), do: :delivery
  defp owner_kind!("input"), do: :input
  defp owner_kind!("event"), do: :event
  defp owner_kind!(value), do: raise(ArgumentError, "invalid owner kind #{inspect(value)}")

  defp wait_kind!("input"), do: :input
  defp wait_kind!("event"), do: :event
  defp wait_kind!(value), do: raise(ArgumentError, "invalid wait kind #{inspect(value)}")

  defp delivery!("reply"), do: :reply
  defp delivery!("none"), do: :none
  defp delivery!(value), do: raise(ArgumentError, "invalid delivery #{inspect(value)}")

  defp optional_timestamp!(nil), do: nil
  defp optional_timestamp!(value), do: timestamp!(value)

  defp timestamp!(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> timestamp
      {:error, reason} -> raise ArgumentError, "invalid timestamp #{inspect(value)}: #{reason}"
    end
  end

  defp timestamp!(value), do: raise(ArgumentError, "invalid timestamp #{inspect(value)}")
end
