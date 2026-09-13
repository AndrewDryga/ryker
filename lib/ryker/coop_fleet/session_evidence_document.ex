defmodule Ryker.CoopFleet.SessionEvidenceDocument do
  @moduledoc """
  Strict consumer contract for one Coop session evidence export.

  Coop's `workerproto.SessionEvidence` is the producer; this is the consumer,
  and the pair is held together by the versioned golden fixtures in
  `testdata/protocol/`. Validation happens before any durable write, so an
  export that drifted cannot become a row Ryker then has to interpret.

  The rules the shape encodes are the ones an operator reads off the page:

    * every section states its own availability, and an absence is never zero --
      `unavailable` is not `no_run`, and neither is "observed nothing"
    * a counter is an unsigned decimal string so a value above 2^53 survives a
      browser, and a null counter is a metric nobody measured
    * a destination crosses only under `destinations-included`; a withheld one
      says so, which is a different fact from a refusal that saw no name
    * a bound task carries its immutable identity even when its folder is gone
  """

  alias Ryker.CoopFleet.Protocol

  @version 1
  @maximum_document_bytes 512 * 1_024
  @network_modes ~w(open none filtered)
  @projections ~w(destinations-withheld destinations-included)
  @access_statuses ~w(captured not_filtered unavailable)
  @observation_statuses ~w(observed no_run not_filtered unavailable)
  @receipt_statuses ~w(available not_filtered unavailable)
  @task_statuses ~w(bound unbound unavailable)
  @note_statuses ~w(captured absent withheld)
  @session_states ~w(open exhausted closed discarded)
  @freshness ~w(fresh stale not-observed terminal)
  @finalities ~w(provisional final)
  @completeness ~w(complete partial unknown)
  @coverage_statuses ~w(exact lower-bound unavailable)
  @denial_bases ~w(dns tls socket admission unknown)
  @task_states ~w(todo in_progress blocked done)

  @maximum_rules 256
  @maximum_denials 64
  @maximum_connections 64
  @maximum_alerts 32
  @maximum_sources 16
  @maximum_run_refs 64
  @maximum_checklist 64
  @maximum_task_files 128
  @maximum_note_bytes 8 * 1_024
  @maximum_text_bytes 512
  @maximum_title_bytes 256
  @maximum_label_bytes 1_024
  @maximum_path_bytes 1_024
  @maximum_counter 18_446_744_073_709_551_615

  @counter ~r/\A(?:0|[1-9][0-9]{0,19})\z/
  @identity ~r/\A[0-9a-f]{32}\z/

  @coverage_metrics ~w(proxy_bytes connections upstream_failures kernel_packets guard_denials
    maintenance_queries maintenance_bytes socket_inventory boundary_attribution)
  @counter_fields ~w(sent_bytes received_bytes connections upstream_failures denied_packets
    protected_packets denied_dns_queries denied_tls_connections maintenance_queries
    maintenance_failures ingress_denied_packets maintenance_sent_bytes maintenance_received_bytes)

  @spec version() :: 1
  def version, do: @version

  @doc "Decodes and validates one exported evidence document."
  @spec decode(binary()) :: {:ok, map()} | {:error, term()}
  def decode(document)
      when is_binary(document) and byte_size(document) in 1..@maximum_document_bytes do
    case Jason.decode(document) do
      {:ok, decoded} -> validate(decoded)
      {:error, _reason} -> error(:json)
    end
  end

  def decode(_document), do: error(:document)

  @doc "Validates one already-decoded evidence document."
  @spec validate(term()) :: {:ok, map()} | {:error, term()}
  def validate(%{} = evidence) do
    with :ok <-
           exact_fields(evidence, ~w(version captured_at session_id revision state network task)),
         :ok <- exact_version(evidence["version"]),
         {:ok, captured_at} <- timestamp(evidence["captured_at"], :captured_at),
         :ok <- reference(evidence["session_id"], 1_024, :session_id),
         :ok <- positive(evidence["revision"], :revision),
         :ok <- enum(evidence["state"], @session_states, :state),
         {:ok, network} <- network(evidence["network"]),
         {:ok, task} <- task(evidence["task"]) do
      {:ok,
       evidence
       |> Map.put("captured_at", captured_at)
       |> Map.put("network", network)
       |> Map.put("task", task)}
    end
  end

  def validate(_evidence), do: error(:document)

  @doc """
  The content identity of one capture, excluding its capture time.

  Two reads that found the same state are the same evidence; only the times
  differ. Recording keys on this so a poll loop cannot manufacture a history of
  identical rows, while a genuinely changed session still records a new state.
  """
  @spec content_fingerprint(map()) :: String.t()
  def content_fingerprint(%{} = evidence),
    do: Ryker.CanonicalJSON.digest(Map.delete(evidence, "captured_at"))

  defp network(%{} = network) do
    with :ok <- exact_fields(network, ~w(mode fingerprint access observation receipt)),
         :ok <- enum(network["mode"], @network_modes, :network_mode),
         :ok <- network_fingerprint(network["mode"], network["fingerprint"]),
         filtered = network["mode"] == "filtered",
         {:ok, access} <- access(network["access"], filtered),
         {:ok, observation} <- observation(network["observation"], filtered),
         {:ok, receipt} <- receipt(network["receipt"], filtered) do
      {:ok,
       network
       |> Map.put("access", access)
       |> Map.put("observation", observation)
       |> Map.put("receipt", receipt)}
    end
  end

  defp network(_network), do: error(:network)

  defp network_fingerprint("filtered", value), do: digest(value, :network_fingerprint)
  defp network_fingerprint(_mode, nil), do: :ok
  defp network_fingerprint(_mode, _value), do: error(:network_fingerprint)

  defp access(%{} = access, filtered) do
    fields = ~w(status reason qualification projection requested effective)

    with :ok <- exact_fields(access, fields),
         :ok <- enum(access["status"], @access_statuses, :access_status),
         :ok <- posture(access["status"], filtered, :access_status),
         :ok <- reason(access["reason"], access["status"] == "unavailable", :access_reason),
         :ok <- optional_reference(access["qualification"], 256, :access_qualification),
         :ok <- rule_texts(access["requested"], :access_requested),
         :ok <- rule_texts(access["effective"], :access_effective),
         :ok <- access_projection(access) do
      {:ok, access}
    end
  end

  defp access(_access, _filtered), do: error(:access)

  defp access_projection(%{"status" => "captured"} = access) do
    with :ok <- enum(access["projection"], @projections, :access_projection) do
      if access["projection"] == "destinations-withheld" and
           (access["requested"] != [] or access["effective"] != []) do
        error(:access_projection)
      else
        :ok
      end
    end
  end

  defp access_projection(access) do
    if is_nil(access["projection"]) and access["requested"] == [] and
         access["effective"] == [] and is_nil(access["qualification"]),
       do: :ok,
       else: error(:access_detail)
  end

  defp observation(%{} = observation, filtered) do
    fields =
      ~w(status reason freshness run_id attempt_id gateway_epoch sequence as_of availability scope
         sealed cleanup_outcome projection health coverage counters loss sources denials
         omitted_denials connections omitted_connections alerts omitted_alerts)

    with :ok <- exact_fields(observation, fields),
         :ok <- enum(observation["status"], @observation_statuses, :observation_status),
         :ok <- posture(observation["status"], filtered, :observation_status),
         :ok <-
           reason(
             observation["reason"],
             observation["status"] == "unavailable",
             :observation_reason
           ),
         :ok <- boolean(observation["sealed"], :observation_sealed),
         :ok <- nonnegative(observation["omitted_denials"], :omitted_denials),
         :ok <- nonnegative(observation["omitted_connections"], :omitted_connections),
         :ok <- nonnegative(observation["omitted_alerts"], :omitted_alerts) do
      observation_detail(observation)
    end
  end

  defp observation(_observation, _filtered), do: error(:observation)

  defp observation_detail(%{"status" => "observed"} = observation) do
    with :ok <- enum(observation["freshness"], @freshness, :observation_freshness),
         :ok <- reference(observation["run_id"], 256, :observation_run_id),
         :ok <- optional_reference(observation["attempt_id"], 256, :observation_attempt_id),
         :ok <- optional_reference(observation["gateway_epoch"], 256, :observation_epoch),
         :ok <- counter(observation["sequence"], :observation_sequence),
         {:ok, as_of} <- timestamp(observation["as_of"], :observation_as_of),
         :ok <-
           optional_text(
             observation["availability"],
             @maximum_text_bytes,
             :observation_availability
           ),
         :ok <- optional_text(observation["scope"], @maximum_text_bytes, :observation_scope),
         :ok <-
           optional_text(
             observation["cleanup_outcome"],
             @maximum_text_bytes,
             :observation_cleanup
           ),
         :ok <- enum(observation["projection"], @projections, :observation_projection),
         included = observation["projection"] == "destinations-included",
         :ok <- health(observation["health"]),
         :ok <- coverage(observation["coverage"]),
         :ok <- counters(observation["counters"]),
         :ok <- loss(observation["loss"]),
         :ok <- sources(observation["sources"]),
         :ok <- denials(observation["denials"], included),
         :ok <- connections(observation["connections"], included),
         :ok <- alerts(observation["alerts"]) do
      {:ok, Map.put(observation, "as_of", as_of)}
    end
  end

  # An unobserved run carries no observation. Listing the fields explicitly is
  # the point: a field added to the contract without a line here would be
  # publishable on a run nobody observed.
  @observation_detail_fields ~w(freshness run_id attempt_id gateway_epoch sequence as_of
    availability scope cleanup_outcome projection health coverage counters loss)
  @observation_detail_lists ~w(sources denials connections alerts)
  @observation_detail_counts ~w(omitted_denials omitted_connections omitted_alerts)

  defp observation_detail(observation) do
    if Enum.all?(@observation_detail_fields, &is_nil(observation[&1])) and
         Enum.all?(@observation_detail_lists, &(observation[&1] == [])) and
         Enum.all?(@observation_detail_counts, &(observation[&1] == 0)) and
         observation["sealed"] == false do
      {:ok, observation}
    else
      error(:observation_detail)
    end
  end

  defp health(%{} = health) do
    layers = ~w(enforcer gateway resolver collector)

    with :ok <- exact_fields(health, layers) do
      each_ok(layers, &health_layer(health[&1]))
    end
  end

  defp health(_health), do: error(:health)

  defp health_layer(%{} = layer) do
    with :ok <- exact_fields(layer, ~w(status reason)),
         :ok <- text(layer["status"], @maximum_text_bytes, :health_status) do
      reason(layer["reason"], false, :health_reason)
    end
  end

  defp health_layer(_layer), do: error(:health)

  defp coverage(%{} = coverage) do
    with :ok <- exact_fields(coverage, @coverage_metrics) do
      each_ok(@coverage_metrics, &coverage_metric(coverage[&1]))
    end
  end

  defp coverage(_coverage), do: error(:coverage)

  defp coverage_metric(%{} = metric) do
    with :ok <- exact_fields(metric, ~w(status reason)),
         :ok <- enum(metric["status"], @coverage_statuses, :coverage_status) do
      reason(metric["reason"], false, :coverage_reason)
    end
  end

  defp coverage_metric(_metric), do: error(:coverage)

  defp counters(nil), do: :ok

  defp counters(%{} = counters) do
    with :ok <- exact_fields(counters, @counter_fields) do
      each_ok(@counter_fields, &optional_counter(counters[&1], :counter))
    end
  end

  defp counters(_counters), do: error(:counters)

  defp loss(nil), do: :ok

  defp loss(%{} = loss) do
    with :ok <-
           exact_fields(
             loss,
             ~w(records unknown reasons detail_truncated omitted_details suppressed_alerts)
           ),
         :ok <- counter(loss["records"], :loss_records),
         :ok <- counter(loss["suppressed_alerts"], :loss_suppressed_alerts),
         :ok <- optional_counter(loss["omitted_details"], :loss_omitted_details),
         :ok <- boolean(loss["unknown"], :loss_unknown),
         :ok <- boolean(loss["detail_truncated"], :loss_detail_truncated) do
      bounded_texts(loss["reasons"], 32, @maximum_text_bytes, :loss_reasons)
    end
  end

  defp loss(_loss), do: error(:loss)

  defp sources(sources) when is_list(sources) and length(sources) <= @maximum_sources,
    do: each_ok(sources, &source/1)

  defp sources(_sources), do: error(:sources)

  defp source(%{} = source) do
    with :ok <-
           exact_fields(
             source,
             ~w(id status sequence observed_at last_event_at lost_records unknown_loss reason)
           ),
         :ok <- reference(source["id"], 256, :source_id),
         :ok <- text(source["status"], @maximum_text_bytes, :source_status),
         :ok <- counter(source["sequence"], :source_sequence),
         :ok <- counter(source["lost_records"], :source_lost_records),
         :ok <- boolean(source["unknown_loss"], :source_unknown_loss),
         {:ok, _observed} <- optional_timestamp(source["observed_at"], :source_observed_at),
         {:ok, _last} <- optional_timestamp(source["last_event_at"], :source_last_event_at) do
      reason(source["reason"], false, :source_reason)
    end
  end

  defp source(_source), do: error(:source)

  defp denials(denials, included) when is_list(denials) and length(denials) <= @maximum_denials,
    do: each_ok(denials, &denial(&1, included))

  defp denials(_denials, _included), do: error(:denials)

  defp denial(%{} = denial, included) do
    fields =
      ~w(id at kind basis reason source source_sequence destination destination_withheld port)

    with :ok <- exact_fields(denial, fields),
         :ok <- reference(denial["id"], 256, :denial_id),
         {:ok, _at} <- timestamp(denial["at"], :denial_at),
         :ok <- text(denial["kind"], @maximum_text_bytes, :denial_kind),
         :ok <- enum(denial["basis"], @denial_bases, :denial_basis),
         :ok <- text(denial["reason"], @maximum_text_bytes, :denial_reason),
         :ok <- text(denial["source"], @maximum_text_bytes, :denial_source),
         :ok <- counter(denial["source_sequence"], :denial_sequence),
         :ok <- port(denial["port"]) do
      destination(denial["destination"], denial["destination_withheld"], included, :denial)
    end
  end

  defp denial(_denial, _included), do: error(:denial)

  defp connections(connections, included)
       when is_list(connections) and length(connections) <= @maximum_connections,
       do: each_ok(connections, &connection(&1, included))

  defp connections(_connections, _included), do: error(:connections)

  defp connection(%{} = connection, included) do
    fields =
      ~w(id state reason transport destination destination_withheld rule_id started_at observed_at
         sent_bytes received_bytes partial)

    with :ok <- exact_fields(connection, fields),
         :ok <- reference(connection["id"], 256, :connection_id),
         :ok <- text(connection["state"], @maximum_text_bytes, :connection_state),
         :ok <- text(connection["transport"], @maximum_text_bytes, :connection_transport),
         :ok <- reason(connection["reason"], false, :connection_reason),
         {:ok, _started} <- optional_timestamp(connection["started_at"], :connection_started_at),
         {:ok, _observed} <- timestamp(connection["observed_at"], :connection_observed_at),
         :ok <- optional_counter(connection["sent_bytes"], :connection_sent_bytes),
         :ok <- optional_counter(connection["received_bytes"], :connection_received_bytes),
         :ok <- boolean(connection["partial"], :connection_partial),
         :ok <- connection_rule(connection["rule_id"], included) do
      destination(
        connection["destination"],
        connection["destination_withheld"],
        included,
        :connection
      )
    end
  end

  defp connection(_connection, _included), do: error(:connection)

  defp connection_rule(nil, _included), do: :ok
  defp connection_rule(value, true), do: reference(value, 256, :connection_rule_id)
  defp connection_rule(_value, false), do: error(:connection_rule_id)

  defp alerts(alerts) when is_list(alerts) and length(alerts) <= @maximum_alerts,
    do: each_ok(alerts, &alert/1)

  defp alerts(_alerts), do: error(:alerts)

  defp alert(%{} = alert) do
    fields = ~w(id category severity state terminal first_seen last_seen reason health_status)

    with :ok <- exact_fields(alert, fields),
         :ok <- reference(alert["id"], 256, :alert_id),
         :ok <- text(alert["category"], @maximum_text_bytes, :alert_category),
         :ok <- text(alert["severity"], @maximum_text_bytes, :alert_severity),
         :ok <- text(alert["state"], @maximum_text_bytes, :alert_state),
         :ok <- boolean(alert["terminal"], :alert_terminal),
         {:ok, first_seen} <- timestamp(alert["first_seen"], :alert_first_seen),
         {:ok, last_seen} <- timestamp(alert["last_seen"], :alert_last_seen),
         :ok <- ordered_times(first_seen, last_seen),
         :ok <- reason(alert["reason"], false, :alert_reason) do
      reason(alert["health_status"], false, :alert_health_status)
    end
  end

  defp alert(_alert), do: error(:alert)

  defp receipt(%{} = receipt, filtered) do
    fields =
      ~w(status reason policy_fingerprint authority_digest started_at closed_at finality completeness
         scope counters coverage loss runs run_count omitted_run_references projection receipt_digest
         digest_scope)

    with :ok <- exact_fields(receipt, fields),
         :ok <- enum(receipt["status"], @receipt_statuses, :receipt_status),
         :ok <- posture(receipt["status"], filtered, :receipt_status),
         :ok <- reason(receipt["reason"], receipt["status"] == "unavailable", :receipt_reason) do
      receipt_detail(receipt)
    end
  end

  defp receipt(_receipt, _filtered), do: error(:receipt)

  defp receipt_detail(%{"status" => "available"} = receipt) do
    with :ok <- digest(receipt["policy_fingerprint"], :receipt_policy_fingerprint),
         :ok <- digest(receipt["authority_digest"], :receipt_authority_digest),
         :ok <- digest(receipt["receipt_digest"], :receipt_digest),
         {:ok, started_at} <- timestamp(receipt["started_at"], :receipt_started_at),
         {:ok, closed_at} <- optional_timestamp(receipt["closed_at"], :receipt_closed_at),
         :ok <- enum(receipt["finality"], @finalities, :receipt_finality),
         :ok <- final_receipt(receipt["finality"], closed_at),
         :ok <- enum(receipt["completeness"], @completeness, :receipt_completeness),
         :ok <- text(receipt["scope"], @maximum_text_bytes, :receipt_scope),
         :ok <- counters(receipt["counters"]),
         :ok <- required(receipt["coverage"], :receipt_coverage),
         :ok <- coverage(receipt["coverage"]),
         :ok <- required(receipt["loss"], :receipt_loss),
         :ok <- loss(receipt["loss"]),
         :ok <- run_references(receipt["runs"]),
         :ok <- counter(receipt["run_count"], :receipt_run_count),
         :ok <- counter(receipt["omitted_run_references"], :receipt_omitted_run_references),
         :ok <- enum(receipt["projection"], @projections, :receipt_projection),
         :ok <- matching_scope(receipt["digest_scope"], receipt["projection"]) do
      {:ok, receipt |> Map.put("started_at", started_at) |> Map.put("closed_at", closed_at)}
    end
  end

  defp receipt_detail(receipt) do
    empty =
      Enum.all?(
        ~w(policy_fingerprint authority_digest started_at closed_at finality completeness scope
           counters coverage loss run_count omitted_run_references projection receipt_digest digest_scope),
        &is_nil(receipt[&1])
      ) and receipt["runs"] == []

    if empty, do: {:ok, receipt}, else: error(:receipt_detail)
  end

  defp final_receipt("final", nil), do: error(:receipt_finality)
  defp final_receipt(_finality, _closed_at), do: :ok

  defp matching_scope(scope, scope), do: :ok
  defp matching_scope(_scope, _projection), do: error(:receipt_digest_scope)

  defp run_references(runs) when is_list(runs) and length(runs) <= @maximum_run_refs,
    do: each_ok(runs, &run_reference/1)

  defp run_references(_runs), do: error(:receipt_runs)

  defp run_reference(%{} = run) do
    with :ok <-
           exact_fields(
             run,
             ~w(run_id gateway_epoch sequence as_of finality completeness receipt_digest)
           ),
         :ok <- reference(run["run_id"], 256, :run_id),
         :ok <- reference(run["gateway_epoch"], 256, :run_epoch),
         :ok <- counter(run["sequence"], :run_sequence),
         {:ok, _as_of} <- timestamp(run["as_of"], :run_as_of),
         :ok <- enum(run["finality"], @finalities, :run_finality),
         :ok <- enum(run["completeness"], @completeness, :run_completeness) do
      digest(run["receipt_digest"], :run_receipt_digest)
    end
  end

  defp run_reference(_run), do: error(:receipt_run)

  defp task(%{} = task) do
    fields = ~w(status reason queue_id task_id id offer_ref draft_sha256 snapshot)

    with :ok <- exact_fields(task, fields),
         :ok <- enum(task["status"], @task_statuses, :task_status),
         :ok <- reason(task["reason"], task["status"] == "unavailable", :task_reason) do
      task_detail(task)
    end
  end

  defp task(_task), do: error(:task)

  defp task_detail(%{"status" => "unbound"} = task) do
    empty =
      Enum.all?(~w(queue_id task_id id offer_ref draft_sha256 snapshot), &is_nil(task[&1]))

    if empty, do: {:ok, task}, else: error(:task_detail)
  end

  defp task_detail(task) do
    with :ok <- identity(task["queue_id"], :task_queue_id),
         :ok <- identity(task["task_id"], :task_task_id),
         :ok <- reference(task["id"], 256, :task_id),
         :ok <- reference(task["offer_ref"], 256, :task_offer_ref),
         :ok <- digest(task["draft_sha256"], :task_draft_sha256),
         :ok <- snapshot_presence(task["status"], task["snapshot"]),
         :ok <- task_snapshot(task["snapshot"]) do
      {:ok, task}
    end
  end

  defp snapshot_presence("bound", %{}), do: :ok
  defp snapshot_presence("bound", _snapshot), do: error(:task_snapshot)
  defp snapshot_presence(_status, nil), do: :ok
  defp snapshot_presence(_status, _snapshot), do: error(:task_snapshot)

  defp task_snapshot(nil), do: :ok

  defp task_snapshot(%{} = snapshot) do
    fields = ~w(state state_sha256 title checklist files state_note has_decision)

    with :ok <- exact_fields(snapshot, fields),
         :ok <- enum(snapshot["state"], @task_states, :task_state),
         :ok <- digest(snapshot["state_sha256"], :task_state_sha256),
         :ok <- text(snapshot["title"], @maximum_title_bytes, :task_title),
         :ok <- boolean(snapshot["has_decision"], :task_has_decision),
         :ok <- checklist(snapshot["checklist"]),
         :ok <- task_files(snapshot["files"]) do
      state_note(snapshot["state_note"])
    end
  end

  defp task_snapshot(_snapshot), do: error(:task_snapshot)

  defp checklist(items) when is_list(items) and length(items) <= @maximum_checklist,
    do: each_ok(items, &checklist_item/1)

  defp checklist(_items), do: error(:task_checklist)

  defp checklist_item(%{} = item) do
    with :ok <- exact_fields(item, ~w(label checked)),
         :ok <- text(item["label"], @maximum_label_bytes, :task_checklist_label) do
      boolean(item["checked"], :task_checklist_checked)
    end
  end

  defp checklist_item(_item), do: error(:task_checklist)

  defp task_files(files) when is_list(files) and length(files) in 1..@maximum_task_files//1,
    do: each_ok(files, &task_file/1)

  defp task_files(_files), do: error(:task_files)

  defp task_file(%{} = file) do
    with :ok <- exact_fields(file, ~w(path byte_size sha256)),
         :ok <- text(file["path"], @maximum_path_bytes, :task_file_path),
         :ok <- nonnegative(file["byte_size"], :task_file_byte_size) do
      digest(file["sha256"], :task_file_sha256)
    end
  end

  defp task_file(_file), do: error(:task_file)

  defp state_note(%{} = note) do
    with :ok <- exact_fields(note, ~w(status text truncated reason)),
         :ok <- enum(note["status"], @note_statuses, :task_note_status),
         :ok <- reason(note["reason"], note["status"] == "withheld", :task_note_reason),
         :ok <- boolean(note["truncated"], :task_note_truncated),
         :ok <- note_text(note["status"], note["text"]) do
      if note["truncated"] and is_nil(note["text"]), do: error(:task_note_truncated), else: :ok
    end
  end

  defp state_note(_note), do: error(:task_note)

  defp note_text("captured", value), do: text(value, @maximum_note_bytes, :task_note_text)
  defp note_text(_status, nil), do: :ok
  defp note_text(_status, _value), do: error(:task_note_text)

  defp destination(nil, withheld, included, scope) when is_boolean(withheld) do
    if withheld and included, do: error(:"#{scope}_destination"), else: :ok
  end

  defp destination(value, false, true, scope) when is_binary(value),
    do: text(value, @maximum_text_bytes, :"#{scope}_destination")

  defp destination(_value, _withheld, _included, scope), do: error(:"#{scope}_destination")

  defp posture(status, filtered, field) do
    if status == "not_filtered" == filtered, do: error(field), else: :ok
  end

  defp rule_texts(values, field),
    do: bounded_texts(values, @maximum_rules, @maximum_text_bytes, field)

  defp bounded_texts(values, maximum_items, maximum_bytes, field)
       when is_list(values) and length(values) <= maximum_items,
       do: each_ok(values, &text(&1, maximum_bytes, field))

  defp bounded_texts(_values, _maximum_items, _maximum_bytes, field), do: error(field)

  # One shape for "every item must validate": the validators below stay flat and
  # a new section cannot invent its own halting rule.
  defp each_ok(values, validate) when is_list(values) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case validate.(value) do
        :ok -> {:cont, :ok}
        {:error, _reason} = failure -> {:halt, failure}
      end
    end)
  end

  defp exact_fields(document, fields) when is_map(document) do
    if Enum.sort(Map.keys(document)) == Enum.sort(fields), do: :ok, else: error(:fields)
  end

  defp exact_version(@version), do: :ok
  defp exact_version(_version), do: {:error, {:unsupported_coop_session_evidence, :version}}

  defp required(nil, field), do: error(field)
  defp required(_value, _field), do: :ok

  defp reference(value, maximum, field) do
    if Protocol.reference?(value, maximum), do: :ok, else: error(field)
  end

  defp optional_reference(nil, _maximum, _field), do: :ok
  defp optional_reference(value, maximum, field), do: reference(value, maximum, field)

  defp text(value, maximum, field) when is_binary(value) and byte_size(value) in 1..maximum//1 do
    if String.valid?(value) and not String.contains?(value, <<0>>) and String.trim(value) != "",
      do: :ok,
      else: error(field)
  end

  defp text(_value, _maximum, field), do: error(field)

  defp optional_text(nil, _maximum, _field), do: :ok
  defp optional_text(value, maximum, field), do: text(value, maximum, field)

  defp reason(nil, true, field), do: error(field)
  defp reason(nil, false, _field), do: :ok
  defp reason(value, _required, field), do: text(value, @maximum_text_bytes, field)

  defp counter(value, field) when is_binary(value) do
    with true <- Regex.match?(@counter, value),
         {parsed, ""} <- Integer.parse(value),
         true <- parsed <= @maximum_counter do
      :ok
    else
      _invalid -> error(field)
    end
  end

  defp counter(_value, field), do: error(field)

  defp optional_counter(nil, _field), do: :ok
  defp optional_counter(value, field), do: counter(value, field)

  defp digest(value, field) do
    if Protocol.digest?(value), do: :ok, else: error(field)
  end

  defp identity(value, field) when is_binary(value) do
    if Regex.match?(@identity, value), do: :ok, else: error(field)
  end

  defp identity(_value, field), do: error(field)

  defp timestamp(value, field) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, %DateTime{} = datetime, 0} -> {:ok, DateTime.to_iso8601(datetime)}
      _invalid -> error(field)
    end
  end

  defp timestamp(_value, field), do: error(field)

  defp optional_timestamp(nil, _field), do: {:ok, nil}
  defp optional_timestamp(value, field), do: timestamp(value, field)

  defp ordered_times(first, last) do
    with {:ok, first, 0} <- DateTime.from_iso8601(first),
         {:ok, last, 0} <- DateTime.from_iso8601(last),
         :lt_or_eq <- if(DateTime.compare(last, first) == :lt, do: :lt, else: :lt_or_eq) do
      :ok
    else
      _invalid -> error(:alert_seen_order)
    end
  end

  defp enum(value, allowed, field) do
    if value in allowed, do: :ok, else: error(field)
  end

  defp boolean(value, _field) when is_boolean(value), do: :ok
  defp boolean(_value, field), do: error(field)

  defp positive(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive(_value, field), do: error(field)

  defp nonnegative(value, _field) when is_integer(value) and value >= 0, do: :ok
  defp nonnegative(_value, field), do: error(field)

  defp port(nil), do: :ok
  defp port(value) when is_integer(value) and value in 0..65_535, do: :ok
  defp port(_value), do: error(:denial_port)

  defp error(field), do: {:error, {:invalid_coop_session_evidence, field}}
end
