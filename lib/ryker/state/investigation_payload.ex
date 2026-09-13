defmodule Ryker.State.InvestigationPayload do
  @moduledoc false

  alias Ryker.CanonicalJSON

  @maximum_payload_bytes 32 * 1_024
  @reference ~r/\A[A-Za-z0-9_.:-]{1,256}\z/
  # The model owns planning, implementation and self-review membership. The
  # host owns Workspace setup, Draft PR, CI and Review and merge from its own
  # receipts, so those can never be claimed by a goal.
  @goal_stages ~w(planning implementation self_review)
  @goal_states ~w(ready working waiting completed blocked excluded cancelled)

  @doc "Lifecycle stages a model-authored goal may belong to."
  @spec goal_stages() :: [String.t()]
  def goal_stages, do: @goal_stages

  @doc "States a goal may stand in."
  @spec goal_states() :: [String.t()]
  def goal_states, do: @goal_states

  @spec prepare(String.t(), term()) :: {:ok, map()} | {:error, term()}
  def prepare("evidence", payload), do: evidence(payload)
  def prepare("coverage", payload), do: coverage(payload)
  def prepare("finding", payload), do: finding(payload)
  def prepare("progress", payload), do: progress(payload)
  def prepare("goal", payload), do: goal(payload)
  def prepare("goal_state", payload), do: goal_state(payload)
  def prepare("alert_assessment", payload), do: alert_assessment(payload)
  def prepare(_kind, _payload), do: {:error, {:invalid_state_record, :kind}}

  defp evidence(%{} = payload) do
    required = ~w(claim_id observation source_name source_type)

    optional =
      ~w(claim confidence dimensions freshness health_effect observed_at relation scope_note source_id supersedes target)

    with :ok <- fields(payload, required, optional),
         :ok <- reference(payload["claim_id"], 120, :claim_id),
         :ok <- text(payload["observation"], 4_000, :observation),
         :ok <- text(payload["source_name"], 500, :source_name),
         :ok <-
           enum(
             payload["source_type"],
             ~w(repository emisar monitoring slack other),
             :source_type
           ),
         :ok <- optional_text(payload, "claim", 2_000, :claim),
         :ok <- optional_enum(payload, "relation", ~w(supports contradicts), :relation),
         :ok <-
           optional_enum(
             payload,
             "health_effect",
             ~w(none risk degraded unhealthy unknown),
             :health_effect
           ),
         :ok <- optional_text(payload, "source_id", 1_000, :source_id),
         :ok <- optional_text(payload, "freshness", 500, :freshness),
         :ok <- optional_enum(payload, "confidence", ~w(high medium low), :confidence),
         :ok <- optional_scalar_map(payload, "dimensions", :dimensions),
         :ok <- optional_text(payload, "target", 200, :target),
         :ok <- optional_references(payload, "supersedes", 10, :supersedes),
         :ok <- optional_text(payload, "scope_note", 2_000, :scope_note),
         {:ok, prepared} <- optional_datetime(payload, "observed_at", :observed_at),
         :ok <- canonical(prepared) do
      {:ok, prepared}
    end
  end

  defp evidence(_payload), do: invalid(:payload)

  defp coverage(%{} = payload) do
    required = ~w(claim_ids detail layer observed_at source status)

    with :ok <- fields(payload, required, []),
         :ok <-
           enum(
             payload["layer"],
             ~w(task hardware host runtime scheduler workload dependency application slo change),
             :layer
           ),
         :ok <- references(payload["claim_ids"], 1, 20, 120, :claim_ids),
         :ok <-
           enum(payload["status"], ~w(healthy degraded unhealthy unknown not_applicable), :status),
         :ok <- text(payload["source"], 500, :source),
         :ok <- text(payload["detail"], 2_000, :detail),
         {:ok, prepared} <- required_datetime(payload, "observed_at", :observed_at),
         :ok <- canonical(prepared) do
      {:ok, prepared}
    end
  end

  defp coverage(_payload), do: invalid(:payload)

  defp finding(%{} = payload) do
    with :ok <- fields(payload, ~w(status what), ~w(alternatives cause_evidence reason scope)),
         :ok <- finding_text(payload["what"], 4_000, :what),
         :ok <- optional_finding_text(payload, "scope", 2_000, :scope),
         :ok <- enum(payload["status"], ~w(unexplained explained expected out_of_scope), :status),
         :ok <- optional_references(payload, "cause_evidence", 10, :cause_evidence),
         :ok <- alternatives(Map.get(payload, "alternatives", [])),
         :ok <- optional_finding_text(payload, "reason", 2_000, :reason),
         :ok <- finding_claim(payload),
         :ok <- canonical(payload, 64 * 1_024) do
      {:ok, payload}
    end
  end

  defp finding(_payload), do: invalid(:payload)

  defp progress(%{} = payload) do
    with :ok <- fields(payload, ~w(phase summary), ~w(next_due_at)),
         :ok <- text(payload["phase"], 120, :phase),
         :ok <- text(payload["summary"], 2_000, :summary),
         {:ok, prepared} <- optional_datetime(payload, "next_due_at", :next_due_at),
         :ok <- canonical(prepared) do
      {:ok, prepared}
    end
  end

  defp progress(_payload), do: invalid(:payload)

  defp goal(%{} = payload) do
    required = ~w(authority completion_contract id kind requested_outcome required stage)

    optional =
      ~w(parent_goal_id prerequisite_goal_ids read_only_repositories successor_of writable_repository)

    with :ok <- fields(payload, required, optional),
         :ok <- reference(payload["id"], 120, :id),
         :ok <- enum(payload["kind"], ~w(check engineering operation schedule), :kind),
         :ok <- enum(payload["stage"], @goal_stages, :stage),
         :ok <- text(payload["requested_outcome"], 500, :requested_outcome),
         :ok <- text(payload["completion_contract"], 2_000, :completion_contract),
         :ok <- boolean(payload["required"], :required),
         :ok <- optional_reference(payload, "parent_goal_id", 120, :parent_goal_id),
         :ok <- optional_references(payload, "prerequisite_goal_ids", 20, :prerequisite_goal_ids),
         :ok <- optional_reference(payload, "successor_of", 120, :successor_of),
         :ok <- optional_text(payload, "writable_repository", 256, :writable_repository),
         :ok <-
           optional_text_list(payload, "read_only_repositories", 20, 256, :read_only_repositories),
         :ok <-
           enum(
             payload["authority"],
             ~w(read_only repository_write governed_operation),
             :authority
           ),
         :ok <- goal_authority(payload),
         :ok <- goal_repositories(payload),
         :ok <- goal_parent(payload),
         :ok <- goal_successor(payload),
         :ok <- canonical(payload) do
      {:ok, payload}
    end
  end

  defp goal(_payload), do: invalid(:payload)

  defp goal_state(%{} = payload) do
    with :ok <- fields(payload, ~w(goal_id state), ~w(detail evidence_refs)),
         :ok <- reference(payload["goal_id"], 120, :goal_id),
         :ok <-
           enum(payload["state"], @goal_states, :state),
         :ok <- optional_text(payload, "detail", 2_000, :detail),
         :ok <- optional_references(payload, "evidence_refs", 12, :evidence_refs),
         :ok <- canonical(payload) do
      {:ok, payload}
    end
  end

  defp goal_state(_payload), do: invalid(:payload)

  defp alert_assessment(%{} = payload) do
    required = ~w(impact verdict)

    optional =
      ~w(cause cause_claim_ids cause_status evidence_refs immediate_action immediate_action_kind long_term_solution scope verification)

    with :ok <- fields(payload, required, optional),
         :ok <-
           enum(
             payload["verdict"],
             ~w(confirmed_issue likely_issue not_issue unverified),
             :verdict
           ),
         :ok <- text(payload["impact"], 2_000, :impact),
         :ok <- optional_enum(payload, "cause_status", ~w(identified bounded), :cause_status),
         :ok <- optional_text(payload, "cause", 2_000, :cause),
         :ok <- optional_references(payload, "cause_claim_ids", 8, :cause_claim_ids),
         :ok <- optional_references(payload, "evidence_refs", 12, :evidence_refs),
         :ok <-
           optional_enum(
             payload,
             "immediate_action_kind",
             ~w(mitigation monitor investigation none),
             :immediate_action_kind
           ),
         :ok <- optional_text(payload, "immediate_action", 2_000, :immediate_action),
         :ok <- optional_text(payload, "verification", 2_000, :verification),
         :ok <- optional_text(payload, "long_term_solution", 2_000, :long_term_solution),
         :ok <- optional_scope(payload["scope"]),
         :ok <- assessment_claim(payload),
         :ok <- canonical(payload) do
      {:ok, payload}
    end
  end

  defp alert_assessment(_payload), do: invalid(:payload)

  defp finding_claim(%{"status" => "explained", "cause_evidence" => refs})
       when is_list(refs) and refs != [],
       do: :ok

  defp finding_claim(%{"status" => "explained"}), do: invalid(:cause_evidence)

  defp finding_claim(%{"status" => status} = payload) when status in ~w(expected out_of_scope),
    do: finding_text(payload["reason"], 2_000, :reason)

  defp finding_claim(_payload), do: :ok

  # JSON Schema maxLength counts Unicode codepoints, not UTF-8 bytes. Keep a
  # byte bound before counting so these human conclusions remain bounded.
  defp finding_text(value, maximum, field) do
    with :ok <- text(value, maximum * 4, field),
         true <- length(String.codepoints(value)) <= maximum do
      :ok
    else
      _ -> invalid(field)
    end
  end

  defp optional_finding_text(payload, key, maximum, field) do
    case Map.get(payload, key) do
      nil -> :ok
      value -> finding_text(value, maximum, field)
    end
  end

  defp alternatives(values) when is_list(values) and length(values) <= 5 do
    if Enum.all?(values, &(alternative(&1) == :ok)), do: :ok, else: invalid(:alternatives)
  end

  defp alternatives(_values), do: invalid(:alternatives)

  defp alternative(%{} = value) do
    with :ok <- fields(value, ~w(hypothesis), ~w(claim_id discriminated_by not_checkable)),
         :ok <- text(value["hypothesis"], 2_000, :hypothesis),
         :ok <- optional_reference(value, "claim_id", 120, :claim_id) do
      alternative_proof(value)
    end
  end

  defp alternative(_value), do: invalid(:alternatives)

  defp alternative_proof(value) do
    case {Map.get(value, "discriminated_by"), Map.get(value, "not_checkable")} do
      {ref, nil} -> reference(ref, 256, :discriminated_by)
      {nil, reason} -> text(reason, 2_000, :not_checkable)
      _invalid -> invalid(:alternatives)
    end
  end

  defp goal_authority(%{"authority" => "repository_write"} = payload),
    do: text(payload["writable_repository"], 256, :writable_repository)

  defp goal_authority(%{"authority" => authority, "writable_repository" => repository})
       when authority != "repository_write" and not is_nil(repository),
       do: invalid(:writable_repository)

  defp goal_authority(_payload), do: :ok

  defp goal_repositories(payload) do
    writable = payload["writable_repository"]
    read_only = Map.get(payload, "read_only_repositories", [])

    if is_nil(writable) or writable not in read_only,
      do: :ok,
      else: invalid(:read_only_repositories)
  end

  # A parent completes after its children, so a child that also waits on its
  # parent could never start.
  defp goal_parent(%{"parent_goal_id" => parent} = payload) when is_binary(parent) do
    if parent in Map.get(payload, "prerequisite_goal_ids", []),
      do: invalid(:parent_goal_id),
      else: :ok
  end

  defp goal_parent(_payload), do: :ok

  defp goal_successor(%{"successor_of" => predecessor} = payload) when is_binary(predecessor) do
    if predecessor in [payload["id"], payload["parent_goal_id"]],
      do: invalid(:successor_of),
      else: :ok
  end

  defp goal_successor(_payload), do: :ok

  defp assessment_claim(%{"verdict" => verdict} = payload)
       when verdict in ~w(confirmed_issue likely_issue) do
    with :ok <- enum(payload["cause_status"], ~w(identified bounded), :cause_status),
         :ok <- text(payload["cause"], 2_000, :cause),
         :ok <- references(payload["cause_claim_ids"], 1, 8, 120, :cause_claim_ids),
         :ok <- references(payload["evidence_refs"], 1, 12, 256, :evidence_refs),
         :ok <- text(payload["immediate_action"], 2_000, :immediate_action),
         :ok <- text(payload["verification"], 2_000, :verification) do
      text(payload["long_term_solution"], 2_000, :long_term_solution)
    end
  end

  defp assessment_claim(%{"verdict" => "unverified"} = payload),
    do: text(payload["immediate_action"], 2_000, :immediate_action)

  defp assessment_claim(_payload), do: :ok

  defp optional_scope(nil), do: :ok

  defp optional_scope(%{} = scope) do
    fields = ~w(checked_targets evidence_refs status universe_evidence_ref unverified_targets)

    with :ok <-
           fields(
             scope,
             ~w(checked_targets evidence_refs status),
             fields -- ~w(checked_targets evidence_refs status)
           ),
         :ok <- text_list(scope["checked_targets"], 1, 50, 200, :checked_targets),
         :ok <- references(scope["evidence_refs"], 1, 50, 256, :evidence_refs),
         :ok <- optional_text_list(scope, "unverified_targets", 50, 200, :unverified_targets),
         :ok <- optional_reference(scope, "universe_evidence_ref", 256, :universe_evidence_ref) do
      scope_shape(scope)
    end
  end

  defp optional_scope(_scope), do: invalid(:scope)

  defp scope_shape(%{"status" => "bounded"} = scope) do
    with :ok <- text_list(scope["unverified_targets"], 1, 50, 200, :unverified_targets),
         true <- is_nil(scope["universe_evidence_ref"]) do
      :ok
    else
      false -> invalid(:scope)
      {:error, _reason} = error -> error
    end
  end

  defp scope_shape(%{"status" => "exhaustive"} = scope) do
    unverified = Map.get(scope, "unverified_targets", [])
    universe = scope["universe_evidence_ref"]

    if unverified == [] and is_binary(universe) and universe in scope["evidence_refs"],
      do: :ok,
      else: invalid(:scope)
  end

  defp scope_shape(_scope), do: invalid(:scope)

  defp fields(payload, required, optional) do
    keys = Map.keys(payload)
    allowed = required ++ optional

    if Enum.all?(keys, &is_binary/1) and Enum.all?(required, &(&1 in keys)) and
         Enum.all?(keys, &(&1 in allowed)),
       do: :ok,
       else: invalid(:fields)
  end

  defp enum(value, allowed, field),
    do: if(value in allowed, do: :ok, else: invalid(field))

  defp boolean(value, field), do: if(is_boolean(value), do: :ok, else: invalid(field))

  defp text(value, maximum, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: :ok,
       else: invalid(field)
  end

  defp reference(value, maximum, field) do
    with :ok <- text(value, maximum, field),
         true <- Regex.match?(@reference, value) and byte_size(value) <= maximum do
      :ok
    else
      false -> invalid(field)
      {:error, _reason} = error -> error
    end
  end

  defp optional_text(payload, key, maximum, field) do
    case Map.get(payload, key) do
      nil -> :ok
      value -> text(value, maximum, field)
    end
  end

  defp optional_reference(payload, key, maximum, field) do
    case Map.get(payload, key) do
      nil -> :ok
      value -> reference(value, maximum, field)
    end
  end

  defp optional_enum(payload, key, allowed, field) do
    case Map.get(payload, key) do
      nil -> :ok
      value -> enum(value, allowed, field)
    end
  end

  defp references(values, minimum, maximum, item_maximum, field) do
    if is_list(values) and length(values) in minimum..maximum and Enum.uniq(values) == values and
         Enum.all?(values, &(reference(&1, item_maximum, field) == :ok)),
       do: :ok,
       else: invalid(field)
  end

  defp optional_references(payload, key, maximum, field) do
    case Map.get(payload, key) do
      nil -> :ok
      values -> references(values, 0, maximum, 256, field)
    end
  end

  defp text_list(values, minimum, maximum, item_maximum, field) do
    if is_list(values) and length(values) in minimum..maximum and Enum.uniq(values) == values and
         Enum.all?(values, &(text(&1, item_maximum, field) == :ok)),
       do: :ok,
       else: invalid(field)
  end

  defp optional_text_list(payload, key, maximum, item_maximum, field) do
    case Map.get(payload, key) do
      nil -> :ok
      values -> text_list(values, 0, maximum, item_maximum, field)
    end
  end

  defp optional_scalar_map(payload, key, field) do
    case Map.get(payload, key) do
      nil -> :ok
      value -> scalar_map(value, field)
    end
  end

  defp scalar_map(value, field) when is_map(value) and map_size(value) <= 32 do
    if Enum.all?(value, fn {key, item} ->
         text(key, 120, field) == :ok and
           (is_binary(item) or is_boolean(item) or is_number(item))
       end),
       do: :ok,
       else: invalid(field)
  end

  defp scalar_map(_value, field), do: invalid(field)

  defp required_datetime(payload, key, field) do
    case normalize_datetime(payload[key], field) do
      {:ok, value} -> {:ok, Map.put(payload, key, value)}
      {:error, _reason} = error -> error
    end
  end

  defp optional_datetime(payload, key, field) do
    case Map.get(payload, key) do
      nil ->
        {:ok, payload}

      value ->
        case normalize_datetime(value, field) do
          {:ok, normalized} -> {:ok, Map.put(payload, key, normalized)}
          {:error, _reason} = error -> error
        end
    end
  end

  defp normalize_datetime(value, field) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, DateTime.to_iso8601(datetime)}
      _invalid -> invalid(field)
    end
  end

  defp normalize_datetime(_value, field), do: invalid(field)

  defp canonical(payload, maximum_bytes \\ @maximum_payload_bytes) do
    case CanonicalJSON.validate(payload, max_bytes: maximum_bytes) do
      :ok -> :ok
      {:error, _reason} -> invalid(:payload)
    end
  end

  defp invalid(field), do: {:error, {:invalid_state_record, field}}
end
