defmodule Responder.CoopFleet.Protocol do
  @moduledoc """
  Versioned, bounded wire contract for outbound Coop workers.

  The protocol carries placement and operation identities plus the exact
  bounded submission a selected worker must execute. It never carries provider
  credentials, Slack/GitHub publication credentials, repository contents, or a
  generic remote command. Unknown fields and unsupported versions fail before
  any durable command or event mutation can occur.
  """

  @version 1
  @maximum_document_bytes 1_048_576
  @maximum_batch 100
  @maximum_payload_bytes 768 * 1_024
  @command_kinds ~w(
    ensure_workspace
    create_session
    get_session
    submit_turn
    get_turn
    get_output_artifact
    get_changes
    get_changes_page
    run_review
    plan_discard
    discard_session
    get_review_patch
    validate_candidate
    cancel_turn
    fence_operation
    checkpoint_workspace
    close_session
    reconcile_operation
  )
  @worker_states ~w(eligible busy draining needs_auth)
  @capacity_states ~w(eligible busy cooldown needs_auth)
  @storage_allocations ~w(open refused)
  @storage_refusal_reasons ~w(reserve_exhausted protected_storage_exceeds_budget)
  @storage_byte_fields [
    {"capacity_bytes", :capacity_bytes},
    {"free_bytes", :free_bytes},
    {"reserve_bytes", :reserve_bytes},
    {"high_watermark_bytes", :high_watermark_bytes},
    {"low_watermark_bytes", :low_watermark_bytes},
    {"disposable_bytes", :disposable_bytes},
    {"protected_bytes", :protected_bytes}
  ]
  @maximum_storage_bytes 1_125_899_906_842_624
  @command_result_states ~w(succeeded failed uncertain)
  @event_kinds ~w(operation session turn candidate validation workspace checkpoint capacity session_event)
  @activity_event_kinds ~w(tool.started tool.completed model.plan model.thought permission.decided activity.elided provider.backoff provider.alive)
  @reference ~r/\A[A-Za-z0-9_.:-]+\z/

  @spec version() :: 1
  def version, do: @version

  @spec decode_poll(binary()) :: {:ok, map()} | {:error, term()}
  def decode_poll(document)
      when is_binary(document) and byte_size(document) <= @maximum_document_bytes do
    case Jason.decode(document) do
      {:ok, decoded} -> poll(decoded)
      {:error, _reason} -> {:error, {:invalid_coop_worker_poll, :json}}
    end
  end

  def decode_poll(_document), do: {:error, {:invalid_coop_worker_poll, :document}}

  @spec poll(map()) :: {:ok, map()} | {:error, term()}
  def poll(%{} = document) do
    with :ok <-
           exact_fields(
             document,
             ~w(version poll_ref worker acknowledged_command_ids command_results event_batches),
             :poll
           ),
         :ok <- exact_version(document["version"]),
         :ok <- reference(document["poll_ref"], 256, :poll_ref),
         {:ok, worker} <- worker(document["worker"]),
         {:ok, acknowledgements} <-
           references(document["acknowledged_command_ids"], :acknowledged_command_ids),
         {:ok, command_results} <-
           list(document["command_results"], :command_results, :poll, &command_result/1),
         {:ok, event_batches} <-
           list(document["event_batches"], :event_batches, :poll, &event_batch/1) do
      {:ok,
       %{
         "acknowledged_command_ids" => acknowledgements,
         "command_results" => command_results,
         "event_batches" => event_batches,
         "poll_ref" => document["poll_ref"],
         "version" => @version,
         "worker" => worker
       }}
    end
  end

  def poll(_document), do: {:error, {:invalid_coop_worker_poll, :document}}

  @spec response(map()) :: {:ok, map()} | {:error, term()}
  def response(%{} = document) do
    with :ok <-
           exact_fields(
             document,
             ~w(version poll_ref server_time acknowledged_result_command_ids commands event_acknowledgements),
             :response
           ),
         :ok <- exact_version(document["version"]),
         :ok <- reference(document["poll_ref"], 256, :poll_ref),
         {:ok, server_time} <- timestamp(document["server_time"], :server_time),
         {:ok, acknowledged_result_command_ids} <-
           response_references(
             document["acknowledged_result_command_ids"],
             :acknowledged_result_command_ids
           ),
         {:ok, commands} <- list(document["commands"], :commands, :response, &command/1),
         {:ok, event_acknowledgements} <-
           list(
             document["event_acknowledgements"],
             :event_acknowledgements,
             :response,
             &event_acknowledgement/1
           ) do
      {:ok,
       %{
         "acknowledged_result_command_ids" => acknowledged_result_command_ids,
         "commands" => commands,
         "event_acknowledgements" => event_acknowledgements,
         "poll_ref" => document["poll_ref"],
         "server_time" => server_time,
         "version" => @version
       }}
    end
  end

  def response(_document), do: {:error, {:invalid_coop_worker_response, :document}}

  @spec encode_response(map()) :: {:ok, binary()} | {:error, term()}
  def encode_response(document) do
    with {:ok, prepared} <- response(document) do
      {:ok, Jason.encode!(prepared)}
    end
  end

  defp worker(%{} = document) do
    document =
      document
      |> Map.put_new("policy_authority_digests", %{})
      |> Map.put_new("storage", nil)

    fields =
      ~w(id workspace_ref protocol_version build_version clock_at sandbox_digest policy_digests policy_authority_digests repositories capabilities capacity storage state)

    with :ok <- exact_fields(document, fields, :worker),
         :ok <- reference(document["id"], 256, :worker_id),
         :ok <- reference(document["workspace_ref"], 256, :workspace_ref),
         :ok <- reference(document["protocol_version"], 64, :protocol_version),
         :ok <- reference(document["build_version"], 128, :build_version),
         {:ok, clock_at} <- timestamp(document["clock_at"], :clock_at),
         :ok <- digest(document["sandbox_digest"], :sandbox_digest),
         {:ok, policies} <- policy_digests(document["policy_digests"]),
         {:ok, policy_authorities} <-
           policy_authority_digests(document["policy_authority_digests"]),
         :ok <- policy_authority_contract(policies, policy_authorities),
         {:ok, repositories} <-
           unique_list(document["repositories"], :repositories, &repository/1, & &1["ref"]),
         {:ok, capabilities} <-
           unique_list(document["capabilities"], :capabilities, &capability/1, & &1["name"]),
         {:ok, capacity} <- capacity(document["capacity"]),
         {:ok, storage} <- storage(document["storage"]),
         :ok <- enum(document["state"], @worker_states, :worker_state) do
      {:ok,
       document
       |> Map.put("clock_at", clock_at)
       |> Map.put("policy_digests", policies)
       |> Map.put("policy_authority_digests", policy_authorities)
       |> Map.put("repositories", repositories)
       |> Map.put("capabilities", capabilities)
       |> Map.put("capacity", capacity)
       |> Map.put("storage", storage)}
    end
  end

  defp worker(_document), do: {:error, {:invalid_coop_worker_poll, :worker}}

  # Workspace bytes are measured by the worker that owns the filesystem. The
  # object is optional so an older worker still polls; absent means unknown, and
  # unknown must never be read as zero by anything downstream.
  defp storage(nil), do: {:ok, nil}

  defp storage(%{} = document) do
    fields =
      ~w(version measured_at capacity_bytes free_bytes reserve_bytes high_watermark_bytes low_watermark_bytes disposable_bytes protected_bytes unattributed_bytes allocation refusal_reason)

    with :ok <- exact_fields(document, fields, :storage),
         :ok <- storage_version(document["version"]),
         {:ok, measured_at} <- timestamp(document["measured_at"], :measured_at),
         :ok <- storage_bytes(document, @storage_byte_fields),
         :ok <- optional_bytes(document["unattributed_bytes"], :unattributed_bytes),
         :ok <- enum(document["allocation"], @storage_allocations, :storage_allocation),
         :ok <- refusal_reason(document["allocation"], document["refusal_reason"]),
         :ok <- storage_bounds(document) do
      {:ok, Map.put(document, "measured_at", measured_at)}
    end
  end

  defp storage(_document), do: {:error, {:invalid_coop_worker_poll, :storage}}

  defp storage_version(@version), do: :ok
  defp storage_version(_version), do: {:error, {:invalid_coop_worker_protocol, :storage_version}}

  defp storage_bytes(document, fields) do
    Enum.reduce_while(fields, :ok, fn {name, field}, :ok ->
      case bytes(document[name], field) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp bytes(value, _field)
       when is_integer(value) and value >= 0 and value <= @maximum_storage_bytes,
       do: :ok

  defp bytes(_value, field), do: {:error, {:invalid_coop_worker_protocol, field}}

  defp optional_bytes(nil, _field), do: :ok
  defp optional_bytes(value, field), do: bytes(value, field)

  defp refusal_reason("refused", reason) do
    if reason in @storage_refusal_reasons,
      do: :ok,
      else: {:error, {:invalid_coop_worker_protocol, :refusal_reason}}
  end

  defp refusal_reason(_allocation, nil), do: :ok

  defp refusal_reason(_allocation, _reason),
    do: {:error, {:invalid_coop_worker_protocol, :refusal_reason}}

  defp storage_bounds(document) do
    cond do
      document["low_watermark_bytes"] > document["high_watermark_bytes"] or
          document["high_watermark_bytes"] > document["capacity_bytes"] ->
        {:error, {:invalid_coop_worker_protocol, :storage_watermarks}}

      Enum.any?(
        ~w(free_bytes reserve_bytes disposable_bytes protected_bytes),
        &(document[&1] > document["capacity_bytes"])
      ) ->
        {:error, {:invalid_coop_worker_protocol, :storage_capacity}}

      true ->
        :ok
    end
  end

  defp capacity(%{} = document) do
    fields =
      ~w(session_slots_free session_slots_total turn_slots_free turn_slots_total workspace_slots_free workspace_slots_total state cooldown_until)

    with :ok <- exact_fields(document, fields, :capacity),
         :ok <-
           slots(document["session_slots_free"], document["session_slots_total"], :session_slots),
         :ok <- slots(document["turn_slots_free"], document["turn_slots_total"], :turn_slots),
         :ok <-
           slots(
             document["workspace_slots_free"],
             document["workspace_slots_total"],
             :workspace_slots
           ),
         :ok <- enum(document["state"], @capacity_states, :capacity_state),
         {:ok, cooldown} <- optional_timestamp(document["cooldown_until"], :cooldown_until),
         :ok <- cooldown_contract(document["state"], cooldown) do
      {:ok, Map.put(document, "cooldown_until", cooldown)}
    end
  end

  defp capacity(_document), do: {:error, {:invalid_coop_worker_poll, :capacity}}

  defp policy_digests(%{} = policies) when map_size(policies) <= @maximum_batch do
    Enum.reduce_while(policies, {:ok, %{}}, fn {name, value}, {:ok, prepared} ->
      with :ok <- reference(name, 256, :policy_name),
           :ok <- digest(value, :policy_digest) do
        {:cont, {:ok, Map.put(prepared, name, value)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp policy_digests(_policies), do: {:error, {:invalid_coop_worker_poll, :policy_digests}}

  defp policy_authority_digests(policies) do
    case policy_digests(policies) do
      {:ok, prepared} -> {:ok, prepared}
      {:error, _reason} -> {:error, {:invalid_coop_worker_poll, :policy_authority_digests}}
    end
  end

  defp policy_authority_contract(_policies, authorities) when map_size(authorities) == 0, do: :ok

  defp policy_authority_contract(policies, authorities) do
    if Map.keys(policies) |> Enum.sort() == Map.keys(authorities) |> Enum.sort(),
      do: :ok,
      else: {:error, {:invalid_coop_worker_poll, :policy_authority_digests}}
  end

  defp repository(%{} = document) do
    with :ok <- exact_fields(document, ~w(ref revision), :repository),
         :ok <- reference(document["ref"], 256, :repository_ref),
         :ok <- reference(document["revision"], 256, :repository_revision) do
      {:ok, document}
    end
  end

  defp repository(_document), do: {:error, {:invalid_coop_worker_poll, :repository}}

  defp capability(%{} = document) do
    with :ok <- exact_fields(document, ~w(name version), :capability),
         :ok <- reference(document["name"], 256, :capability_name),
         :ok <- reference(document["version"], 128, :capability_version) do
      {:ok, document}
    end
  end

  defp capability(_document), do: {:error, {:invalid_coop_worker_poll, :capability}}

  defp command_result(%{} = document) do
    with :ok <-
           exact_fields(
             document,
             ~w(command_id state operation_key resource error),
             :command_result
           ),
         :ok <- reference(document["command_id"], 256, :command_id),
         :ok <- reference(document["operation_key"], 512, :operation_key),
         :ok <- enum(document["state"], @command_result_states, :command_result_state),
         :ok <- optional_payload(document["resource"], :command_resource),
         :ok <- optional_payload(document["error"], :command_error),
         :ok <- result_shape(document) do
      {:ok, document}
    end
  end

  defp command_result(_document), do: {:error, {:invalid_coop_worker_poll, :command_result}}

  defp event_batch(%{} = document) do
    with :ok <-
           exact_fields(
             document,
             ~w(session_ref placement_generation after_sequence events),
             :event_batch
           ),
         :ok <- reference(document["session_ref"], 256, :session_ref),
         :ok <- positive(document["placement_generation"], :placement_generation),
         :ok <- nonnegative(document["after_sequence"], :after_sequence),
         {:ok, events} <- list(document["events"], :events, :poll, &event/1),
         :ok <- ordered_events(events, document["after_sequence"]),
         :ok <- one_event_mode(events) do
      {:ok, Map.put(document, "events", events)}
    end
  end

  defp event_batch(_document), do: {:error, {:invalid_coop_worker_poll, :event_batch}}

  defp event(%{} = document) do
    with :ok <- exact_fields(document, ~w(sequence kind payload), :event),
         :ok <- positive(document["sequence"], :event_sequence),
         :ok <- enum(document["kind"], @event_kinds, :event_kind),
         :ok <- payload(document["payload"], :event_payload),
         :ok <- session_event(document["kind"], document["sequence"], document["payload"]) do
      {:ok, document}
    end
  end

  defp event(_document), do: {:error, {:invalid_coop_worker_poll, :event}}

  defp session_event("session_event", sequence, %{} = document) do
    allowed = ~w(id session_id sequence turn_id type version occurred_at payload)
    required = ~w(id session_id sequence type version occurred_at)

    with true <- Map.keys(document) -- allowed == [],
         true <- Enum.all?(required, &Map.has_key?(document, &1)),
         :ok <- reference(document["id"], 1_024, :session_event_id),
         :ok <- reference(document["session_id"], 1_024, :session_event_session_id),
         :ok <- optional_reference(document["turn_id"], 1_024, :session_event_turn_id),
         :ok <- reference(document["type"], 128, :session_event_type),
         :ok <- positive(document["version"], :session_event_version),
         true <- document["version"] <= 65_535,
         {:ok, _occurred_at} <- timestamp(document["occurred_at"], :session_event_occurred_at),
         :ok <-
           session_event_payload(document["type"], Map.get(document, "payload")),
         true <- document["sequence"] == sequence do
      :ok
    else
      false -> {:error, {:invalid_coop_worker_protocol, :session_event_sequence}}
      {:error, _reason} = error -> error
    end
  end

  defp session_event("session_event", _sequence, _document),
    do: {:error, {:invalid_coop_worker_protocol, :session_event}}

  defp session_event(_kind, _sequence, _document), do: :ok

  defp session_event_payload(kind, value) when kind in @activity_event_kinds,
    do: optional_payload(value, :session_event_payload)

  defp session_event_payload(_kind, nil), do: :ok
  defp session_event_payload(_kind, value) when value == %{}, do: :ok

  defp session_event_payload(_kind, _value),
    do: {:error, {:invalid_coop_worker_protocol, :session_event_payload}}

  defp command(%{} = document) do
    fields =
      ~w(command_id worker_id session_ref placement_generation lease_ref lease_expires_at kind command_version payload idempotency_key)

    with :ok <- exact_fields(document, fields, :command),
         :ok <- reference(document["command_id"], 256, :command_id),
         :ok <- reference(document["worker_id"], 256, :worker_id),
         :ok <- reference(document["session_ref"], 256, :session_ref),
         :ok <- positive(document["placement_generation"], :placement_generation),
         :ok <- reference(document["lease_ref"], 256, :lease_ref),
         {:ok, lease_expires_at} <- timestamp(document["lease_expires_at"], :lease_expires_at),
         :ok <- enum(document["kind"], @command_kinds, :command_kind),
         :ok <- exact_version(document["command_version"]),
         :ok <- payload(document["payload"], :command_payload),
         :ok <- reference(document["idempotency_key"], 512, :idempotency_key) do
      {:ok, Map.put(document, "lease_expires_at", lease_expires_at)}
    end
  end

  defp command(_document), do: {:error, {:invalid_coop_worker_response, :command}}

  defp event_acknowledgement(%{} = document) do
    with :ok <-
           exact_fields(
             document,
             ~w(session_ref placement_generation sequence),
             :event_acknowledgement
           ),
         :ok <- reference(document["session_ref"], 256, :session_ref),
         :ok <- positive(document["placement_generation"], :placement_generation),
         :ok <- nonnegative(document["sequence"], :event_sequence) do
      {:ok, document}
    end
  end

  defp event_acknowledgement(_document),
    do: {:error, {:invalid_coop_worker_response, :event_acknowledgement}}

  defp exact_fields(document, fields, scope) do
    if Enum.sort(Map.keys(document)) == Enum.sort(fields),
      do: :ok,
      else: {:error, {error_namespace(scope), scope}}
  end

  defp exact_version(@version), do: :ok
  defp exact_version(_version), do: {:error, {:unsupported_coop_worker_protocol, :version}}

  defp list(values, _field, _scope, prepare)
       when is_list(values) and length(values) <= @maximum_batch do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, prepared} ->
      case prepare.(value) do
        {:ok, item} -> {:cont, {:ok, [item | prepared]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      {:error, _reason} = error -> error
    end
  end

  defp list(_values, field, scope, _prepare),
    do: {:error, {error_namespace(scope), field}}

  defp unique_list(values, field, prepare, identity) do
    with {:ok, prepared} <- list(values, field, :poll, prepare),
         true <- Enum.uniq_by(prepared, identity) == prepared do
      {:ok, prepared}
    else
      false -> {:error, {:invalid_coop_worker_poll, field}}
      {:error, _reason} = error -> error
    end
  end

  defp references(values, field) do
    with {:ok, prepared} <- list(values, field, :poll, &prepare_reference/1),
         true <- Enum.uniq(prepared) == prepared do
      {:ok, prepared}
    else
      false -> {:error, {:invalid_coop_worker_poll, field}}
      {:error, _reason} = error -> error
    end
  end

  defp response_references(values, field) do
    with {:ok, prepared} <- list(values, field, :response, &prepare_reference/1),
         true <- Enum.uniq(prepared) == prepared do
      {:ok, prepared}
    else
      false -> {:error, {:invalid_coop_worker_response, field}}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_reference(value) do
    with :ok <- reference(value, 256, :reference), do: {:ok, value}
  end

  defp reference(value, maximum, field)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= maximum do
    if String.valid?(value) and Regex.match?(@reference, value),
      do: :ok,
      else: {:error, {:invalid_coop_worker_protocol, field}}
  end

  defp reference(_value, _maximum, field),
    do: {:error, {:invalid_coop_worker_protocol, field}}

  defp optional_reference(nil, _maximum, _field), do: :ok
  defp optional_reference(value, maximum, field), do: reference(value, maximum, field)

  defp digest(value, field) when is_binary(value) and byte_size(value) == 64 do
    if value == String.downcase(value) and String.match?(value, ~r/\A[0-9a-f]{64}\z/),
      do: :ok,
      else: {:error, {:invalid_coop_worker_protocol, field}}
  end

  defp digest(_value, field), do: {:error, {:invalid_coop_worker_protocol, field}}

  defp timestamp(value, field) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, %DateTime{} = datetime, 0} -> {:ok, DateTime.to_iso8601(datetime)}
      _invalid -> {:error, {:invalid_coop_worker_protocol, field}}
    end
  end

  defp timestamp(_value, field), do: {:error, {:invalid_coop_worker_protocol, field}}

  defp optional_timestamp(nil, _field), do: {:ok, nil}
  defp optional_timestamp(value, field), do: timestamp(value, field)

  defp enum(value, allowed, field) do
    if value in allowed, do: :ok, else: {:error, {:invalid_coop_worker_protocol, field}}
  end

  defp slots(free, total, _field)
       when is_integer(free) and is_integer(total) and total >= 0 and total <= 10_000 and
              free >= 0 and free <= total,
       do: :ok

  defp slots(_free, _total, field), do: {:error, {:invalid_coop_worker_protocol, field}}

  defp positive(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive(_value, field), do: {:error, {:invalid_coop_worker_protocol, field}}

  defp nonnegative(value, _field) when is_integer(value) and value >= 0, do: :ok
  defp nonnegative(_value, field), do: {:error, {:invalid_coop_worker_protocol, field}}

  defp payload(value, field) when is_map(value) do
    if byte_size(Jason.encode!(value)) <= @maximum_payload_bytes,
      do: :ok,
      else: {:error, {:invalid_coop_worker_protocol, field}}
  rescue
    _error -> {:error, {:invalid_coop_worker_protocol, field}}
  end

  defp payload(_value, field), do: {:error, {:invalid_coop_worker_protocol, field}}

  defp optional_payload(nil, _field), do: :ok
  defp optional_payload(value, field), do: payload(value, field)

  defp cooldown_contract("cooldown", value) when is_binary(value), do: :ok

  defp cooldown_contract("cooldown", _value),
    do: {:error, {:invalid_coop_worker_protocol, :cooldown_until}}

  defp cooldown_contract(_state, nil), do: :ok

  defp cooldown_contract(_state, _value),
    do: {:error, {:invalid_coop_worker_protocol, :cooldown_until}}

  defp result_shape(%{"state" => "succeeded", "resource" => resource, "error" => nil})
       when is_map(resource),
       do: :ok

  defp result_shape(%{"state" => state, "resource" => nil, "error" => error})
       when state in ~w(failed uncertain) and is_map(error),
       do: :ok

  defp result_shape(_document), do: {:error, {:invalid_coop_worker_poll, :command_result_shape}}

  defp ordered_events([], _after_sequence), do: :ok

  defp ordered_events(events, after_sequence) do
    sequences = Enum.map(events, & &1["sequence"])
    expected = Enum.to_list((after_sequence + 1)..(after_sequence + length(events)))

    if sequences == expected,
      do: :ok,
      else: {:error, {:invalid_coop_worker_poll, :event_sequence}}
  end

  defp one_event_mode(events) do
    session_events = Enum.count(events, &(&1["kind"] == "session_event"))

    if session_events in [0, length(events)],
      do: :ok,
      else: {:error, {:invalid_coop_worker_poll, :event_batch}}
  end

  defp error_namespace(scope)
       when scope in [:response, :command, :event_acknowledgement],
       do: :invalid_coop_worker_response

  defp error_namespace(_scope), do: :invalid_coop_worker_poll
end
