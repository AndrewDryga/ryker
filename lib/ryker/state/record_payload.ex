defmodule Ryker.State.RecordPayload do
  @moduledoc false

  alias Ryker.CanonicalJSON
  alias Ryker.Emisar.ApprovalContract
  alias Ryker.Slack.SourceRef
  alias Ryker.State.EventWaitTiming
  alias Ryker.State.InvestigationPayload
  alias Ryker.State.ScheduleRecurrence
  alias Ryker.Work.RepositorySource

  @maximum_payload_bytes 32 * 1_024
  @maximum_automation_change_bytes 64 * 1_024
  @kinds ~w(
    task_offer publication_offer schedule_offer automation_change_offer memory_offer
    preference_offer guidance_offer standing_assignment_offer slack_post_offer input_request
    event_wait emisar_approval evidence coverage finding progress goal goal_state alert_assessment
  )

  @doc false
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @spec prepare(String.t(), term(), String.t()) ::
          {:ok, %{payload: map(), continuation: map() | nil}} | {:error, term()}
  def prepare("task_offer", payload, _ref), do: task_offer(payload)
  def prepare("publication_offer", payload, _ref), do: publication_offer(payload)
  def prepare("schedule_offer", payload, _ref), do: schedule_offer(payload)
  def prepare("automation_change_offer", payload, _ref), do: automation_change_offer(payload)
  def prepare("memory_offer", payload, _ref), do: memory_offer(payload)
  def prepare("preference_offer", payload, _ref), do: preference_offer(payload)
  def prepare("guidance_offer", payload, _ref), do: guidance_offer(payload)
  def prepare("standing_assignment_offer", payload, _ref), do: standing_assignment_offer(payload)
  def prepare("slack_post_offer", payload, _ref), do: slack_post_offer(payload)
  def prepare("input_request", payload, ref), do: input_request(payload, ref)
  def prepare("event_wait", payload, ref), do: event_wait(payload, ref)
  def prepare("emisar_approval", payload, ref), do: ApprovalContract.prepare(payload, ref)

  def prepare(kind, payload, _ref)
      when kind in ~w(evidence coverage finding progress goal goal_state alert_assessment) do
    with {:ok, payload} <- InvestigationPayload.prepare(kind, payload) do
      {:ok, %{continuation: nil, payload: payload, subject_ref: subject_ref(kind, payload)}}
    end
  end

  def prepare(_kind, _payload, _ref), do: {:error, {:invalid_state_record, :kind}}

  defp task_offer(%{} = payload) do
    with :ok <- task_offer_fields(payload),
         :ok <- enum(payload["kind"], ~w(engineering incident), :kind),
         :ok <- text(payload["title"], 120, :title),
         :ok <- text(payload["prompt"], 12_000, :prompt),
         :ok <- task_repository(payload["kind"], payload["repository"]),
         :ok <- task_repository_source(payload["repository"], payload["repository_source"]),
         :ok <- task_offer_authority(payload),
         :ok <- canonical(payload) do
      {:ok, %{continuation: nil, payload: payload, subject_ref: nil}}
    end
  end

  defp task_offer(_payload), do: {:error, {:invalid_state_record, :payload}}

  # Older offers predate structured authority and source selection; their exact
  # shapes stay readable. New offers always carry repository_source, null when
  # the worker chose nothing.
  defp task_offer_fields(payload) do
    base = ~w(kind prompt repository title)

    structured =
      ~w(authority_limits instruction_ref kind prompt repository source_refs success_checks title)

    sourced = ["repository_source" | structured]

    if Enum.sort(Map.keys(payload)) in Enum.map([base, structured, sourced], &Enum.sort/1),
      do: :ok,
      else: {:error, {:invalid_state_record, :fields}}
  end

  defp task_repository_source(_repository, nil), do: :ok

  defp task_repository_source(nil, _source),
    do: {:error, {:invalid_state_record, :repository_source}}

  defp task_repository_source(_repository, source) do
    case RepositorySource.parse(source) do
      {:ok, ^source} -> :ok
      _other -> {:error, {:invalid_state_record, :repository_source}}
    end
  end

  defp task_offer_authority(%{"success_checks" => checks} = payload) do
    with :ok <- text_list(checks, 1, 20, 1_000, :success_checks),
         :ok <- text_list(payload["authority_limits"], 1, 20, 500, :authority_limits),
         :ok <- reference(payload["instruction_ref"], :instruction_ref) do
      reference_list(payload["source_refs"], 20, :source_refs)
    end
  end

  defp task_offer_authority(_without_authority), do: :ok

  defp publication_offer(%{} = payload) do
    with :ok <- exact_fields(payload, ~w(body title)),
         :ok <- text(payload["title"], 120, :title),
         :ok <- text(payload["body"], 8_000, :body),
         :ok <- canonical(payload) do
      {:ok, %{continuation: nil, payload: payload, subject_ref: nil}}
    end
  end

  defp publication_offer(_payload), do: {:error, {:invalid_state_record, :payload}}

  defp schedule_offer(%{} = payload) do
    with :ok <-
           exact_fields(
             payload,
             ~w(authority expires_at recurrence repository task timezone title)
           ),
         :ok <-
           enum(
             payload["authority"],
             ~w(read_only repository_write governed_operation),
             :authority
           ),
         :ok <- text(payload["title"], 120, :title),
         :ok <- text(payload["task"], 12_000, :task),
         :ok <- text(payload["timezone"], 128, :timezone),
         :ok <- schedule_repository(payload["authority"], payload["repository"]),
         {:ok, recurrence} <- ScheduleRecurrence.prepare_shape(payload["recurrence"]),
         {:ok, expires_at} <- optional_utc_datetime(payload["expires_at"]),
         prepared <- %{
           payload
           | "expires_at" => expires_at && DateTime.to_iso8601(expires_at),
             "recurrence" => recurrence
         },
         :ok <- canonical(prepared) do
      {:ok, %{continuation: nil, payload: prepared, subject_ref: nil}}
    end
  end

  defp schedule_offer(_payload), do: {:error, {:invalid_state_record, :payload}}

  defp automation_change_offer(%{} = payload) do
    with :ok <-
           exact_fields(
             payload,
             ~w(action after automation_id automation_kind before patch revision)
           ),
         :ok <- enum(payload["action"], ~w(update pause resume delete), :action),
         :ok <- enum(payload["automation_kind"], ~w(time source_event), :automation_kind),
         :ok <- reference(payload["automation_id"], :automation_id),
         :ok <- positive_integer(payload["revision"], :revision),
         :ok <- json_object(payload["before"], :before),
         :ok <- json_object(payload["after"], :after),
         :ok <- json_object(payload["patch"], :patch),
         :ok <- canonical(payload, @maximum_automation_change_bytes) do
      {:ok, %{continuation: nil, payload: payload, subject_ref: nil}}
    end
  end

  defp automation_change_offer(_payload),
    do: {:error, {:invalid_state_record, :payload}}

  defp memory_offer(%{} = payload) do
    with :ok <-
           exact_fields(
             payload,
             ~w(expires_in kind repository scope subject value visibility)
           ),
         :ok <-
           enum(
             payload["kind"],
             ~w(alias repository_binding evidence_route entity_relationship),
             :kind
           ),
         :ok <- enum(payload["scope"], ~w(conversation repository workspace), :scope),
         :ok <- enum(payload["expires_in"], ~w(7d 30d 90d 365d), :expires_in),
         :ok <- enum(payload["visibility"], ~w(conversation workspace), :visibility),
         :ok <- text(payload["subject"], 120, :subject),
         :ok <- text(payload["value"], 4_000, :value),
         :ok <- scoped_repository(payload["scope"], payload["repository"]),
         :ok <- memory_visibility(payload["scope"], payload["visibility"]),
         :ok <- canonical(payload) do
      {:ok, %{continuation: nil, payload: payload, subject_ref: nil}}
    end
  end

  defp memory_offer(_payload), do: {:error, {:invalid_state_record, :payload}}

  defp preference_offer(%{} = payload) do
    with :ok <- exact_fields(payload, ~w(expires_in key repository scope value)),
         :ok <- enum(payload["scope"], ~w(operator conversation repository workspace), :scope),
         :ok <- enum(payload["expires_in"], ~w(7d 30d 90d 365d), :expires_in),
         :ok <- preference(payload["key"], payload["value"], payload["scope"]),
         :ok <- scoped_repository(payload["scope"], payload["repository"]),
         :ok <- canonical(payload) do
      {:ok, %{continuation: nil, payload: payload, subject_ref: nil}}
    end
  end

  defp preference_offer(_payload), do: {:error, {:invalid_state_record, :payload}}

  defp guidance_offer(%{} = payload) do
    with :ok <-
           exact_fields(
             payload,
             ~w(expires_in repository scope subject summary text visibility)
           ),
         :ok <- enum(payload["scope"], ~w(operator conversation repository workspace), :scope),
         :ok <- enum(payload["expires_in"], ~w(7d 30d 90d 365d), :expires_in),
         :ok <- enum(payload["visibility"], ~w(private conversation workspace), :visibility),
         :ok <- text(payload["subject"], 120, :subject),
         :ok <- text(payload["summary"], 500, :summary),
         :ok <- text(payload["text"], 4_000, :text),
         :ok <- scoped_repository(payload["scope"], payload["repository"]),
         :ok <- guidance_visibility(payload["scope"], payload["visibility"]),
         :ok <- canonical(payload) do
      {:ok, %{continuation: nil, payload: payload, subject_ref: nil}}
    end
  end

  defp guidance_offer(_payload), do: {:error, {:invalid_state_record, :payload}}

  defp standing_assignment_offer(%{"source_kind" => _source_kind} = payload) do
    with :ok <-
           exact_fields(
             payload,
             ~w(context_channel delivery_channel expires_at filter hold repository source_kind task title)
           ),
         :ok <- reference(payload["context_channel"], :context_channel),
         :ok <- reference(payload["delivery_channel"], :delivery_channel),
         {:ok, expires_at} <- optional_utc_datetime(payload["expires_at"]),
         :ok <- json_object(payload["filter"], :filter),
         :ok <- enum(payload["hold"], [nil], :hold),
         :ok <- optional_reference(payload["repository"], :repository),
         :ok <- reference(payload["source_kind"], :source_kind),
         :ok <- text(payload["task"], 12_000, :task),
         :ok <- text(payload["title"], 120, :title),
         prepared <- %{payload | "expires_at" => expires_at && DateTime.to_iso8601(expires_at)},
         :ok <- canonical(prepared) do
      {:ok, %{continuation: nil, payload: prepared, subject_ref: nil}}
    end
  end

  defp standing_assignment_offer(%{} = payload) do
    with :ok <-
           exact_fields(
             payload,
             ~w(action expires_in repository source_filter task trigger)
           ),
         :ok <- enum(payload["expires_in"], ~w(7d 30d 90d 365d), :expires_in),
         :ok <- enum(payload["source_filter"], ~w(human app any), :source_filter),
         :ok <- standing_pair(payload["trigger"], payload["action"]),
         :ok <- optional_reference(payload["repository"], :repository),
         :ok <- text(payload["task"], 4_000, :task),
         :ok <- canonical(payload) do
      {:ok, %{continuation: nil, payload: payload, subject_ref: nil}}
    end
  end

  defp standing_assignment_offer(_payload),
    do: {:error, {:invalid_state_record, :payload}}

  defp slack_post_offer(%{"transport" => "slack"} = payload) do
    with :ok <-
           exact_fields(
             payload,
             ~w(conversation_ref destination_ref instruction_ref message requested_by_actor_ref thread_ref transport)
           ),
         :ok <- enum(payload["transport"], ["slack"], :transport),
         {:ok, workspace_ref, channel_ref} <- slack_conversation(payload["conversation_ref"]),
         {:ok, destination} <- SourceRef.parse(payload["destination_ref"], workspace_ref),
         true <- destination.kind in [:channel, :thread],
         true <- destination.channel_ref == channel_ref,
         true <-
           payload["thread_ref"] ==
             if(destination.kind == :thread, do: destination.message_ref, else: nil),
         {:ok, %{kind: :message}} <- SourceRef.parse(payload["instruction_ref"], workspace_ref),
         :ok <- reference(payload["requested_by_actor_ref"], :requested_by_actor_ref),
         true <- String.starts_with?(payload["requested_by_actor_ref"], "slack:user:"),
         :ok <- text(payload["message"], 20_000, :message),
         :ok <- canonical(payload) do
      {:ok, %{continuation: nil, payload: payload, subject_ref: nil}}
    else
      {:error, :invalid_slack_source_ref} ->
        {:error, {:invalid_state_record, :destination_ref}}

      {:error, _reason} = error ->
        error

      false ->
        {:error, {:invalid_state_record, :destination_ref}}
    end
  end

  defp slack_post_offer(%{"transport" => "control_plane"} = payload) do
    with :ok <-
           exact_fields(
             payload,
             ~w(conversation_ref destination_ref instruction_ref message requested_by_actor_ref thread_ref transport)
           ),
         :ok <- control_plane_conversation(payload["conversation_ref"]),
         true <- payload["destination_ref"] == payload["conversation_ref"],
         true <- payload["thread_ref"] == payload["conversation_ref"],
         :ok <- reference(payload["instruction_ref"], :instruction_ref),
         true <- payload["requested_by_actor_ref"] == "control-plane:local",
         :ok <- text(payload["message"], 20_000, :message),
         :ok <- canonical(payload) do
      {:ok, %{continuation: nil, payload: payload, subject_ref: nil}}
    else
      {:error, _reason} = error -> error
      false -> {:error, {:invalid_state_record, :destination_ref}}
    end
  end

  defp slack_post_offer(_payload), do: {:error, {:invalid_state_record, :payload}}

  defp slack_conversation(value) when is_binary(value) do
    case String.split(value, ":", parts: 3) do
      ["slack", workspace_ref, channel_ref]
      when workspace_ref != "" and channel_ref != "" ->
        {:ok, workspace_ref, channel_ref}

      _invalid ->
        {:error, {:invalid_state_record, :conversation_ref}}
    end
  end

  defp slack_conversation(_value),
    do: {:error, {:invalid_state_record, :conversation_ref}}

  defp control_plane_conversation("control-plane:lab:" <> conversation_id) do
    case Ecto.UUID.cast(conversation_id) do
      {:ok, _normalized} -> :ok
      :error -> {:error, {:invalid_state_record, :conversation_ref}}
    end
  end

  defp control_plane_conversation(_value),
    do: {:error, {:invalid_state_record, :conversation_ref}}

  defp input_request(%{} = payload, ref) do
    with :ok <- exact_fields(Map.delete(payload, "remember"), ~w(choices question)),
         :ok <- text(payload["question"], 2_000, :question),
         :ok <- choices(payload["choices"]),
         :ok <- remembered_fact(payload["remember"]),
         :ok <- canonical(payload) do
      {:ok,
       %{
         continuation: %{
           "deadline_at" => nil,
           "kind" => "wait",
           "wait_kind" => "input",
           "wait_ref" => ref
         },
         payload: payload,
         subject_ref: nil
       }}
    end
  end

  defp input_request(_payload, _ref), do: {:error, {:invalid_state_record, :payload}}

  defp remembered_fact(nil), do: :ok

  defp remembered_fact(%{} = intent) do
    with :ok <- exact_fields(intent, ~w(applicability subject)),
         :ok <- text(intent["subject"], 120, :remember),
         :ok <- text(intent["applicability"], 1_000, :remember) do
      :ok
    else
      _ -> {:error, {:invalid_state_record, :remember}}
    end
  end

  defp remembered_fact(_intent), do: {:error, {:invalid_state_record, :remember}}

  defp event_wait(%{} = payload, ref) do
    with :ok <- exact_fields(payload, ~w(deadline_at event_matcher kind verification)),
         :ok <- text(payload["kind"], 120, :kind),
         :ok <- text(payload["verification"], 2_000, :verification),
         :ok <- json_object(payload["event_matcher"], :event_matcher),
         {:ok, deadline} <- event_deadline(payload),
         :ok <- event_wait_matcher(payload["event_matcher"], deadline),
         :ok <- canonical(payload) do
      {:ok,
       %{
         continuation: %{
           "deadline_at" => deadline_text(deadline),
           "kind" => "wait",
           "wait_kind" => "event",
           "wait_ref" => ref
         },
         payload: %{payload | "deadline_at" => deadline_text(deadline)},
         subject_ref: nil
       }}
    end
  end

  defp event_wait(_payload, _ref), do: {:error, {:invalid_state_record, :payload}}

  defp event_deadline(%{"deadline_at" => nil, "event_matcher" => %{"type" => "source_event"}}),
    do: {:ok, nil}

  defp event_deadline(payload), do: utc_datetime(payload["deadline_at"])
  defp deadline_text(nil), do: nil
  defp deadline_text(deadline), do: DateTime.to_iso8601(deadline)

  defp event_wait_matcher(%{"type" => "source_event"} = trigger, deadline) do
    required = ~w(match on_timeout poll_after type)
    allowed = required ++ ~w(cursor source_kind)

    with true <- required -- Map.keys(trigger) == [] and Map.keys(trigger) -- allowed == [],
         :ok <- json_object(trigger["match"], :event_matcher),
         :ok <- source_wait_bounds(trigger),
         :ok <- source_wait_schedule(trigger, deadline) do
      :ok
    else
      false -> {:error, {:invalid_state_record, :event_matcher}}
      {:error, _reason} -> {:error, {:invalid_state_record, :event_matcher}}
    end
  end

  defp event_wait_matcher(%{"type" => "after"} = trigger, _deadline) do
    with :ok <- exact_fields(trigger, ~w(delay on_timeout type)),
         :ok <- text(trigger["on_timeout"], 2_000, :event_matcher),
         {:ok, _delay} <- EventWaitTiming.delay_microseconds(trigger["delay"]) do
      :ok
    else
      _invalid -> {:error, {:invalid_state_record, :event_matcher}}
    end
  end

  defp event_wait_matcher(%{"type" => "at"} = trigger, deadline) do
    with :ok <- exact_fields(trigger, ~w(at on_timeout type)),
         :ok <- text(trigger["on_timeout"], 2_000, :event_matcher),
         {:ok, at} <- utc_datetime(trigger["at"]),
         :lt <- DateTime.compare(at, deadline) do
      :ok
    else
      _invalid -> {:error, {:invalid_state_record, :event_matcher}}
    end
  end

  defp event_wait_matcher(_untyped_matcher, _deadline), do: :ok

  defp source_wait_schedule(trigger, nil) do
    if is_nil(trigger["poll_after"]) and is_nil(trigger["on_timeout"]) and
         is_binary(trigger["source_kind"]) and map_size(trigger["match"]) > 0,
       do: :ok,
       else: {:error, :event_only_requires_source_identity}
  end

  defp source_wait_schedule(trigger, deadline) do
    with :ok <- text(trigger["on_timeout"], 2_000, :event_matcher),
         {:ok, poll_after} <- source_poll_after(trigger["poll_after"], deadline),
         true <- DateTime.compare(poll_after, deadline) in [:lt, :eq] do
      :ok
    else
      _invalid -> {:error, :invalid_source_wait_schedule}
    end
  end

  defp source_poll_after(nil, deadline), do: {:ok, deadline}
  defp source_poll_after(value, _deadline), do: utc_datetime(value)

  @doc false
  def source_wait_bounds(%{"type" => "source_event"} = trigger) do
    with :ok <- source_kind_bound(trigger["source_kind"]) do
      cursor_bound(trigger["cursor"])
    end
  end

  def source_wait_bounds(_trigger), do: :ok

  defp source_kind_bound(value) do
    if optional_reference(value, :source_kind) == :ok and
         (is_nil(value) or byte_size(value) <= 120),
       do: :ok,
       else: {:error, :source_kind}
  end

  defp cursor_bound(nil), do: :ok

  defp cursor_bound(value) do
    if is_map(value) and CanonicalJSON.validate(value, max_bytes: 16_384) == :ok,
      do: :ok,
      else: {:error, :cursor}
  end

  defp task_repository("engineering", value), do: reference(value, :repository)
  defp task_repository("incident", nil), do: :ok
  defp task_repository("incident", value), do: reference(value, :repository)
  defp task_repository(_kind, _value), do: {:error, {:invalid_state_record, :repository}}

  defp schedule_repository("repository_write", value), do: reference(value, :repository)

  defp schedule_repository(authority, nil) when authority in ~w(read_only governed_operation),
    do: :ok

  defp schedule_repository(_authority, _value),
    do: {:error, {:invalid_state_record, :repository}}

  defp preference("health_check_depth", value, _scope)
       when value in ~w(quick standard deep),
       do: :ok

  defp preference("response_detail", value, _scope)
       when value in ~w(concise standard detailed),
       do: :ok

  defp preference("response_location", value, scope)
       when value in ~w(follow_context prefer_thread prefer_channel) and scope != "repository",
       do: :ok

  defp preference(_key, _value, _scope),
    do: {:error, {:invalid_state_record, :preference}}

  defp scoped_repository("repository", value), do: reference(value, :repository)
  defp scoped_repository(scope, nil) when scope in ~w(operator conversation workspace), do: :ok

  defp scoped_repository(_scope, _value),
    do: {:error, {:invalid_state_record, :repository}}

  defp guidance_visibility("operator", "private"), do: :ok

  defp guidance_visibility("conversation", visibility)
       when visibility in ~w(private conversation), do: :ok

  defp guidance_visibility("repository", visibility)
       when visibility in ~w(conversation workspace), do: :ok

  defp guidance_visibility("workspace", "workspace"), do: :ok

  defp guidance_visibility(_scope, _visibility),
    do: {:error, {:invalid_state_record, :visibility}}

  defp memory_visibility("conversation", "conversation"), do: :ok

  defp memory_visibility(scope, "workspace") when scope in ~w(repository workspace),
    do: :ok

  defp memory_visibility("repository", "conversation"), do: :ok

  defp memory_visibility(_scope, _visibility),
    do: {:error, {:invalid_state_record, :visibility}}

  defp standing_pair("terraform_plan", "review_terraform_plan"), do: :ok
  defp standing_pair("deployment", "verify_deployment"), do: :ok
  defp standing_pair("operational_alert", "triage_alert"), do: :ok

  defp standing_pair(_trigger, _action),
    do: {:error, {:invalid_state_record, :standing_assignment}}

  defp choices(values) when is_list(values) and length(values) <= 10 do
    if Enum.uniq(values) == values and Enum.all?(values, &(text(&1, 240, :choices) == :ok)),
      do: :ok,
      else: {:error, {:invalid_state_record, :choices}}
  end

  defp choices(_values), do: {:error, {:invalid_state_record, :choices}}

  defp text_list(values, minimum, maximum, item_maximum, field)
       when is_list(values) and length(values) >= minimum and length(values) <= maximum do
    if Enum.uniq(values) == values and
         Enum.all?(values, &(text(&1, item_maximum, field) == :ok)),
       do: :ok,
       else: {:error, {:invalid_state_record, field}}
  end

  defp text_list(_values, _minimum, _maximum, _item_maximum, field),
    do: {:error, {:invalid_state_record, field}}

  defp reference_list(values, maximum, field)
       when is_list(values) and length(values) <= maximum do
    if Enum.uniq(values) == values and Enum.all?(values, &(reference(&1, field) == :ok)),
      do: :ok,
      else: {:error, {:invalid_state_record, field}}
  end

  defp reference_list(_values, _maximum, field),
    do: {:error, {:invalid_state_record, field}}

  defp exact_fields(payload, fields) do
    if Enum.sort(Map.keys(payload)) == Enum.sort(fields),
      do: :ok,
      else: {:error, {:invalid_state_record, :fields}}
  end

  defp enum(value, values, field) do
    if value in values,
      do: :ok,
      else: {:error, {:invalid_state_record, field}}
  end

  defp text(value, maximum, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: :ok,
       else: {:error, {:invalid_state_record, field}}
  end

  defp reference(value, field) do
    with :ok <- text(value, 256, field),
         true <- Regex.match?(~r/\A[A-Za-z0-9_.:-]+\z/, value) do
      :ok
    else
      {:error, _reason} = error -> error
      false -> {:error, {:invalid_state_record, field}}
    end
  end

  defp optional_reference(nil, _field), do: :ok
  defp optional_reference(value, field), do: reference(value, field)

  defp json_object(value, _field) when is_map(value), do: :ok
  defp json_object(_value, field), do: {:error, {:invalid_state_record, field}}

  defp positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(_value, field), do: {:error, {:invalid_state_record, field}}

  defp utc_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _invalid -> {:error, {:invalid_state_record, :deadline_at}}
    end
  end

  defp utc_datetime(_value), do: {:error, {:invalid_state_record, :deadline_at}}

  defp optional_utc_datetime(nil), do: {:ok, nil}

  defp optional_utc_datetime(value) do
    case utc_datetime(value) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_state_record, :expires_at}}
    end
  end

  defp canonical(payload), do: canonical(payload, @maximum_payload_bytes)

  defp canonical(payload, maximum_bytes) do
    case CanonicalJSON.validate(payload, max_bytes: maximum_bytes) do
      :ok -> :ok
      {:error, _reason} -> {:error, {:invalid_state_record, :payload}}
    end
  end

  defp subject_ref("goal", payload), do: payload["id"]
  defp subject_ref("goal_state", payload), do: payload["goal_id"]
  defp subject_ref(_kind, _payload), do: nil
end
