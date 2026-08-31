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
  @command_result_states ~w(succeeded failed uncertain)
  @event_kinds ~w(operation session turn candidate validation workspace checkpoint capacity)
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
    fields =
      ~w(id workspace_ref protocol_version build_version clock_at sandbox_digest policy_digests repositories capabilities capacity state)

    with :ok <- exact_fields(document, fields, :worker),
         :ok <- reference(document["id"], 256, :worker_id),
         :ok <- reference(document["workspace_ref"], 256, :workspace_ref),
         :ok <- reference(document["protocol_version"], 64, :protocol_version),
         :ok <- reference(document["build_version"], 128, :build_version),
         {:ok, clock_at} <- timestamp(document["clock_at"], :clock_at),
         :ok <- digest(document["sandbox_digest"], :sandbox_digest),
         {:ok, policies} <- policy_digests(document["policy_digests"]),
         {:ok, repositories} <-
           unique_list(document["repositories"], :repositories, &repository/1, & &1["ref"]),
         {:ok, capabilities} <-
           unique_list(document["capabilities"], :capabilities, &capability/1, & &1["name"]),
         {:ok, capacity} <- capacity(document["capacity"]),
         :ok <- enum(document["state"], @worker_states, :worker_state) do
      {:ok,
       document
       |> Map.put("clock_at", clock_at)
       |> Map.put("policy_digests", policies)
       |> Map.put("repositories", repositories)
       |> Map.put("capabilities", capabilities)
       |> Map.put("capacity", capacity)}
    end
  end

  defp worker(_document), do: {:error, {:invalid_coop_worker_poll, :worker}}

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
         :ok <- ordered_events(events, document["after_sequence"]) do
      {:ok, Map.put(document, "events", events)}
    end
  end

  defp event_batch(_document), do: {:error, {:invalid_coop_worker_poll, :event_batch}}

  defp event(%{} = document) do
    with :ok <- exact_fields(document, ~w(sequence kind payload), :event),
         :ok <- positive(document["sequence"], :event_sequence),
         :ok <- enum(document["kind"], @event_kinds, :event_kind),
         :ok <- payload(document["payload"], :event_payload) do
      {:ok, document}
    end
  end

  defp event(_document), do: {:error, {:invalid_coop_worker_poll, :event}}

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

  defp error_namespace(scope)
       when scope in [:response, :command, :event_acknowledgement],
       do: :invalid_coop_worker_response

  defp error_namespace(_scope), do: :invalid_coop_worker_poll
end
