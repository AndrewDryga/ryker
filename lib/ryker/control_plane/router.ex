defmodule Ryker.ControlPlane.Router do
  @moduledoc """
  The control plane's HTTP contracts: health, readiness and metrics; the
  conversation's message, reaction and record actions with its artifact
  downloads and record views; the two-step confirmed operator actions; and
  the learning actions. Pages live in `WorkbenchLive` and `Pages`; a GET here
  that is not one of these contracts is the not-found page.

  Every mutation is a same-origin form post carrying a process-local CSRF
  token bound to the exact action and resource it confirms.
  """

  import Plug.Conn

  alias Plug.Conn.Query
  alias Ryker.CanonicalJSON

  alias Ryker.ControlPlane.{
    BehaviorLibrary,
    BehaviorPage,
    BrowserGuard,
    CSRF,
    HTML,
    LabControls,
    LearningActivity,
    PathRef,
    RelearnPanel
  }

  alias Ryker.Learning.Operator, as: LearningOperator
  alias Ryker.Observability

  @behaviour Plug
  @maximum_form_bytes 4_096
  @maximum_memory_form_bytes 16 * 1_024
  @maximum_lab_form_bytes 65_536
  @maximum_lab_multipart_bytes 8 * 1_024 * 1_024 + @maximum_lab_form_bytes
  @lab_multipart_parser Plug.Parsers.init(
                          parsers: [{:multipart, length: @maximum_lab_multipart_bytes}],
                          query_string_length: 4_096
                        )

  @impl Plug
  def init(options) do
    if is_map(options) and is_map(options[:actions]) and is_map(options[:observability]) and
         is_map(options[:projection]) and
         is_binary(options[:csrf_secret]) and byte_size(options.csrf_secret) == 32 do
      options
    else
      raise ArgumentError, "control-plane router options are invalid"
    end
  end

  # The endpoint has already run the guard; running it here as well means a
  # direct call to the router is refused and headed exactly the same way.
  @impl Plug
  def call(conn, options) do
    case BrowserGuard.call(conn, access: Map.get(options, :access, :loopback)) do
      %Plug.Conn{halted: true} = refused -> refused
      conn -> route(conn, options)
    end
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["healthz"]} = conn, options) do
    case options.observability.health.() do
      {:ok, _health} -> text(conn, 200, "ok\n")
      {:error, _reason} -> text(conn, 503, "unavailable\n")
    end
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["readyz"]} = conn, options) do
    case options.observability.ready.() do
      {:ok, _readiness} ->
        text(conn, 200, "ready\n")

      {:error, reason} ->
        text(conn, 503, "not ready: " <> Enum.join(Observability.problems(reason), "; ") <> "\n")
    end
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["metrics"]} = conn, options) do
    case options.observability.metrics.() do
      {:ok, metrics} when is_binary(metrics) ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, metrics)
        |> halt()

      {:error, _reason} ->
        text(conn, 503, "metrics unavailable\n")
    end
  end

  defp route(
         %Plug.Conn{
           method: "GET",
           path_info: [
             "conversations",
             conversation_id,
             "turns",
             turn_id,
             "artifacts",
             artifact_ref
           ]
         } = conn,
         options
       ) do
    with {:ok, conversation_id} <- PathRef.uuid(conversation_id),
         {:ok, turn_id} <- PathRef.uuid(turn_id),
         {:ok, artifact_ref} <- PathRef.decode(artifact_ref),
         {:ok, artifact} <-
           options.projection.lab_artifact.(conversation_id, turn_id, artifact_ref) do
      artifact(conn, artifact)
    else
      _not_found -> text(conn, 404, "Artifact not found")
    end
  end

  defp route(
         %Plug.Conn{method: "POST", path_info: ["conversations", conversation_id, "messages"]} =
           conn,
         options
       ) do
    with {:ok, conversation_id} <- PathRef.uuid(conversation_id),
         {:ok, token, message, attachments, conn} <- lab_form(conn),
         true <- LabControls.valid_send_token?(options.csrf_secret, conversation_id, token),
         {:ok, _receipt} <-
           options.actions.send_lab_message.(conversation_id, message, attachments) do
      lab_accepted(conn, conversation_id)
    else
      false ->
        text(conn, 403, "Invalid confirmation token")

      {:error, :path_ref} ->
        text(conn, 404, "Conversation not found")

      {:error, :form} ->
        text(conn, 400, "Invalid form")

      {:error, :conversation_lab_not_configured} ->
        text(conn, 503, "Chat is not ready. The bundled worker is still starting.")

      {:error, {:invalid_conversation_lab, _field}} ->
        text(conn, 422, "Invalid message")

      {:error, _reason} ->
        text(conn, 409, "Message could not be accepted")
    end
  end

  defp route(
         %Plug.Conn{
           method: "GET",
           path_info: ["conversations", conversation_id, "records", record_ref, view_name]
         } = conn,
         options
       ) do
    conn = fetch_query_params(conn)

    with {:ok, conversation_id} <- PathRef.uuid(conversation_id),
         {:ok, record_ref} <- PathRef.decode(record_ref),
         {:ok, view} <- lab_record_view(view_name),
         {:ok, params} <- lab_record_view_params(view, conn.query_params),
         {:ok, snapshot} <-
           options.actions.view_lab_task_record.(conversation_id, record_ref, view, params) do
      snapshot = lab_task_record_navigation(snapshot, conversation_id, record_ref, view)

      html(
        conn,
        200,
        snapshot.title,
        HTML.lab_task_record(
          snapshot,
          "/conversations/#{conversation_id}"
        )
      )
    else
      {:error, :path_ref} -> text(conn, 404, "Conversation or record not found")
      {:error, :lab_record_view} -> text(conn, 404, "Task view not found")
      {:error, :lab_record_view_params} -> text(conn, 400, "Invalid task view")
      {:error, :conversation_lab_record_not_found} -> text(conn, 404, "Task not found")
      {:error, :conversation_lab_record_mismatch} -> text(conn, 404, "Task not found")
      {:error, :conversation_lab_task_mismatch} -> text(conn, 404, "Task not found")
      {:error, _reason} -> text(conn, 409, "Task view is no longer available")
    end
  end

  defp route(
         %Plug.Conn{
           method: "POST",
           path_info: ["conversations", conversation_id, "records", record_ref, action_name]
         } = conn,
         options
       ) do
    with {:ok, conversation_id} <- PathRef.uuid(conversation_id),
         {:ok, record_ref} <- PathRef.decode(record_ref),
         {:ok, action} <- LabControls.record_action(action_name),
         {:ok, token, action_context, conn} <- lab_record_form(conn, action),
         true <-
           LabControls.valid_record_token?(
             options.csrf_secret,
             conversation_id,
             record_ref,
             action,
             action_context,
             token
           ),
         {:ok, _result} <-
           options.actions.act_on_lab_record.(
             conversation_id,
             record_ref,
             action,
             action_context
           ) do
      conn
      |> put_resp_header("location", "/conversations/#{conversation_id}")
      |> send_resp(303, "")
      |> halt()
    else
      false -> text(conn, 403, "Invalid confirmation token")
      {:error, :path_ref} -> text(conn, 404, "Conversation or record not found")
      {:error, :lab_record_action} -> text(conn, 404, "Record action not found")
      {:error, :form} -> text(conn, 400, "Invalid form")
      {:error, _reason} -> text(conn, 409, "Record action is no longer available")
    end
  end

  defp route(
         %Plug.Conn{method: "POST", path_info: ["actions", "learning", id, "retry"]} = conn,
         options
       ) do
    with {:ok, ^id} <- Ecto.UUID.cast(id),
         {:ok, form, conn} <- learning_retry_form(conn),
         true <-
           CSRF.valid?(
             options.csrf_secret,
             "learning:retry",
             LearningActivity.retry_resource(id, form.version),
             form.token
           ),
         {:ok, _receipt} <-
           LearningOperator.retry(
             id,
             form.version,
             "control-plane:local",
             "control-plane:learning-retry:#{id}:#{form.version}"
           ) do
      conn
      |> put_resp_header("location", LearningActivity.path(id))
      |> send_resp(303, "")
      |> halt()
    else
      false -> text(conn, 403, "Invalid confirmation token")
      :error -> text(conn, 400, "Invalid learning batch")
      {:error, :form} -> text(conn, 400, "Invalid retry form")
      {:error, reason} -> text(conn, 409, LearningActivity.error(reason))
    end
  end

  defp route(
         %Plug.Conn{method: "POST", path_info: ["actions", "knowledge", id, "relearn"]} = conn,
         options
       ) do
    with {:ok, ^id} <- Ecto.UUID.cast(id),
         {:ok, form, conn} <- learning_source_form(conn, [:version, :generation]),
         true <-
           CSRF.valid?(
             options.csrf_secret,
             "knowledge:relearn",
             RelearnPanel.resource(id, form.version, form.generation),
             form.token
           ),
         {:ok, %{outcome: %{"batch_id" => batch_id}}} <-
           LearningOperator.rebuild(
             id,
             form.version,
             form.generation,
             form.sources,
             "control-plane:local",
             "control-plane:knowledge-relearn:#{id}:#{form.version}:#{form.generation}"
           ) do
      learning_redirect(conn, batch_id)
    else
      false -> text(conn, 403, "Invalid confirmation token")
      :error -> text(conn, 400, "Invalid knowledge topic")
      {:error, :form} -> text(conn, 400, RelearnPanel.reason(:form))
      {:error, reason} -> text(conn, 409, RelearnPanel.reason(reason))
    end
  end

  defp route(
         %Plug.Conn{method: "POST", path_info: ["actions", "learning", id, "reselect"]} = conn,
         options
       ) do
    with {:ok, ^id} <- Ecto.UUID.cast(id),
         {:ok, form, conn} <- learning_source_form(conn, [:budget_version, :version, :generation]),
         true <-
           CSRF.valid?(
             options.csrf_secret,
             "learning:reselect",
             RelearnPanel.reselect_resource(
               id,
               form.budget_version,
               form.version,
               form.generation
             ),
             form.token
           ),
         {:ok, %{outcome: %{"batch_id" => batch_id}}} <-
           LearningOperator.reselect(
             id,
             form.budget_version,
             %{version: form.version, generation: form.generation},
             form.sources,
             "control-plane:local",
             "control-plane:learning-reselect:#{id}:#{form.budget_version}"
           ) do
      learning_redirect(conn, batch_id)
    else
      false -> text(conn, 403, "Invalid confirmation token")
      :error -> text(conn, 400, "Invalid learning request")
      {:error, :form} -> text(conn, 400, RelearnPanel.reason(:form))
      {:error, reason} -> text(conn, 409, RelearnPanel.reason(reason))
    end
  end

  defp route(
         %Plug.Conn{
           method: "GET",
           path_info: ["actions", "memory-review", resource_ref, "edit"]
         } = conn,
         options
       ) do
    with {:ok, resource_ref} <- PathRef.decode(resource_ref),
         {:ok, review} <- editable_memory_review(resource_ref, options) do
      token = CSRF.token(options.csrf_secret, "memory-review:edit", resource_ref)

      html(
        conn,
        200,
        "Edit reviewed memory",
        HTML.memory_edit(
          review,
          action_path("memory-review", resource_ref, "edit"),
          token
        )
      )
    else
      {:error, _reason} -> html(conn, 404, "Not found", HTML.not_found("Action"))
    end
  end

  defp route(
         %Plug.Conn{
           method: "POST",
           path_info: ["actions", "memory-review", resource_ref, "edit"]
         } = conn,
         options
       ) do
    with {:ok, resource_ref} <- PathRef.decode(resource_ref),
         {:ok, _review} <- editable_memory_review(resource_ref, options),
         {:ok, token, subject, value, conn} <- memory_review_form(conn),
         true <-
           CSRF.valid?(options.csrf_secret, "memory-review:edit", resource_ref, token),
         {:ok, _resource} <-
           options.actions.resolve_memory_review.(
             resource_ref,
             :edit,
             %{"subject" => subject, "value" => value}
           ) do
      conn
      |> put_resp_header("location", "/memory")
      |> send_resp(303, "")
      |> halt()
    else
      false -> text(conn, 403, "Invalid confirmation token")
      {:error, :form} -> text(conn, 400, "Invalid form")
      {:error, _reason} -> text(conn, 409, "Action is no longer available")
    end
  end

  defp route(
         %Plug.Conn{method: "GET", path_info: ["actions", kind, resource_ref, action]} = conn,
         options
       ) do
    with {:ok, resource_ref} <- PathRef.decode(resource_ref),
         {:ok, title, explanation, canonical_action} <-
           confirmation(kind, resource_ref, action, options) do
      path = action_path(kind, resource_ref, action)
      token = CSRF.token(options.csrf_secret, canonical_action, resource_ref)

      html(
        conn,
        200,
        title,
        HTML.confirmation(
          title,
          explanation,
          path,
          token,
          action_return_path(kind, resource_ref, options)
        )
      )
    else
      {:error, _reason} -> html(conn, 404, "Not found", HTML.not_found("Action"))
    end
  end

  defp route(
         %Plug.Conn{method: "POST", path_info: ["actions", kind, resource_ref, action]} = conn,
         options
       ) do
    with {:ok, resource_ref} <- PathRef.decode(resource_ref),
         {:ok, _title, _explanation, canonical_action} <-
           confirmation(kind, resource_ref, action, options),
         {:ok, token, conn} <- form_token(conn),
         true <- CSRF.valid?(options.csrf_secret, canonical_action, resource_ref, token),
         return_path <- action_return_path(kind, resource_ref, options),
         {:ok, _resource} <-
           perform(kind, resource_ref, action, options.actions, canonical_action) do
      conn
      |> put_resp_header("location", return_path)
      |> send_resp(303, "")
      |> halt()
    else
      false -> text(conn, 403, "Invalid confirmation token")
      {:error, :form} -> text(conn, 400, "Invalid form")
      {:error, _reason} -> text(conn, 409, "Action is no longer available")
    end
  end

  defp route(%Plug.Conn{method: "GET"} = conn, _options),
    do: html(conn, 404, "Not found", HTML.not_found("Page"))

  defp route(conn, _options), do: text(conn, 405, "Method not allowed")

  defp lab_record_view("diff"), do: {:ok, :diff}
  defp lab_record_view("timeline"), do: {:ok, :timeline}
  defp lab_record_view("evidence"), do: {:ok, :evidence}
  defp lab_record_view("handoff"), do: {:ok, :handoff}
  defp lab_record_view("postmortem"), do: {:ok, :postmortem}
  defp lab_record_view(_view), do: {:error, :lab_record_view}

  defp lab_record_view_params(:diff, params) when is_map(params) do
    if Map.keys(params) -- ["offset", "snapshot"] == [] do
      with {:ok, offset} <- diff_offset(Map.get(params, "offset", "0")),
           {:ok, digest} <- diff_digest(Map.get(params, "snapshot"), offset) do
        {:ok, %{offset: offset, snapshot_digest: digest}}
      else
        _invalid -> {:error, :lab_record_view_params}
      end
    else
      {:error, :lab_record_view_params}
    end
  end

  defp lab_record_view_params(view, params)
       when view in [:timeline, :evidence, :handoff, :postmortem] and params == %{},
       do: {:ok, %{}}

  defp lab_record_view_params(_view, _params), do: {:error, :lab_record_view_params}

  defp diff_offset(value) when is_binary(value) do
    case Integer.parse(value) do
      {offset, ""} when offset in 0..1_073_741_824 -> {:ok, offset}
      _invalid -> {:error, :offset}
    end
  end

  defp diff_offset(_value), do: {:error, :offset}

  defp diff_digest(nil, 0), do: {:ok, nil}

  defp diff_digest(value, _offset)
       when is_binary(value) and byte_size(value) == 64 do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, value), do: {:ok, value}, else: {:error, :digest}
  end

  defp diff_digest(_value, _offset), do: {:error, :digest}

  defp lab_record_view_path(conversation_id, record_ref, view, page) do
    base = LabControls.record_path(conversation_id, record_ref, view_action(view))

    case page do
      %{offset: offset, snapshot_digest: digest} ->
        base <> "?" <> URI.encode_query(%{"offset" => offset, "snapshot" => digest})

      _first_page ->
        base
    end
  end

  defp lab_task_record_navigation(snapshot, conversation_id, record_ref, view) do
    Map.update(snapshot, :navigation, [], fn navigation ->
      Enum.map(navigation, fn page ->
        Map.put(
          page,
          :path,
          lab_record_view_path(conversation_id, record_ref, view, page)
        )
      end)
    end)
  end

  defp view_action(:diff), do: :view_diff
  defp view_action(:timeline), do: :view_timeline
  defp view_action(:evidence), do: :view_evidence
  defp view_action(:handoff), do: :view_handoff
  defp view_action(:postmortem), do: :view_postmortem

  defp confirmation("memory", resource_ref, "forget", options) do
    snapshot = options.projection.memory.(%{})

    case Enum.find(snapshot.memories, &(&1.ref == resource_ref and &1.status == :active)) do
      nil ->
        {:error, :not_found}

      memory ->
        {:ok, "Forget #{memory.subject} memory?", "The stored value will be redacted.",
         "memory:forget"}
    end
  end

  defp confirmation("memory-review", resource_ref, action, options)
       when action in ["keep", "merge", "forget", "dismiss"] do
    snapshot = options.projection.memory.(%{})

    case Enum.find(snapshot.reviews, &(&1["review_ref"] == resource_ref)) do
      %{"kind" => kind, "status" => "pending"} = review
      when action != "merge" or kind == "duplicate" ->
        subjects = Enum.map_join(review["entries"], ", ", & &1["subject"])

        {:ok, "#{String.capitalize(action)} reviewed memory?",
         "This applies to #{subjects} through the audited memory-review lifecycle.",
         "memory-review:#{action}"}

      _missing_or_incompatible ->
        {:error, :not_found}
    end
  end

  defp confirmation("behavior", resource_ref, action, options)
       when action in ["active", "disabled", "deleted"] do
    case options.projection.behavior.(resource_ref) do
      {:ok, %{status: status} = behavior} when status in ["active", "disabled"] ->
        {verb, explanation} =
          case action do
            "active" ->
              {"Resume",
               "This saved instruction will apply again within its existing scope until it expires."}

            "disabled" ->
              {"Pause",
               "Future requests will not use this instruction. Work already started is unchanged. You can resume it later."}

            "deleted" ->
              {"Delete",
               "This instruction will no longer apply. Its history is retained. To use it again, ask Ryker to propose a new one."}
          end

        subject = BehaviorPage.subject(behavior)
        {:ok, "#{verb} #{subject}?", explanation, "behavior:#{action}"}

      _unavailable ->
        {:error, :not_found}
    end
  end

  defp confirmation("schedule", resource_ref, "run-now", options) do
    case options.projection.schedule.(resource_ref) do
      {:ok, %{schedule: %{status: status} = schedule}}
      when status in [:active, :paused, :completed] ->
        {:ok, "Run #{schedule.title} now?",
         "Ryker will create one fresh execution without changing the saved recurrence cadence.",
         "schedule:run-now:#{schedule.revision}"}

      _unavailable ->
        {:error, :not_found}
    end
  end

  defp confirmation("schedule", resource_ref, action, options)
       when action in ["active", "paused", "deleted"] do
    case options.projection.schedule.(resource_ref) do
      {:ok, %{schedule: %{status: status} = schedule}} when status in [:active, :paused] ->
        {:ok, "Change #{schedule.title}?", "The schedule lifecycle will change to #{action}.",
         "schedule:#{action}"}

      _unavailable ->
        {:error, :not_found}
    end
  end

  defp confirmation("delivery", resource_ref, "rearm", options) do
    case options.projection.delivery.(resource_ref) do
      {:ok, %{status: :blocked}} ->
        {:ok, "Retry this delivery?",
         "Ryker will retry the exact accepted message, reaction, or platform action at its original destination.",
         "delivery:rearm"}

      _not_blocked ->
        {:error, :not_found}
    end
  end

  defp confirmation("admission", resource_ref, "rearm", options) do
    case options.projection.admission.(resource_ref) do
      {:ok, %{action: :rearm, status: :blocked}} ->
        {:ok, "Retry routing this message?",
         "Ryker will reconcile the same frozen input, context, and Coop operation identities.",
         "admission:rearm"}

      _unavailable ->
        {:error, :not_found}
    end
  end

  defp confirmation("work", resource_ref, "retry", options) do
    case options.projection.work.(resource_ref) do
      {:ok,
       %{
         action: :retry,
         status: :blocked,
         work_recovery: %{fingerprint: fingerprint} = recovery
       }} ->
        title =
          cond do
            recovery.kind == :completion -> "Resume saving this completed result?"
            Map.get(recovery, :resume) -> "Resume this work in another workspace?"
            true -> "Retry this blocked work?"
          end

        {:ok, title, recovery.retry_effect, "work:retry:" <> fingerprint}

      _unavailable ->
        {:error, :not_found}
    end
  end

  defp confirmation("episode", resource_ref, "resolve", options) do
    case options.projection.episode.(resource_ref, %{}) do
      {:ok, %{trace: %{actions: actions}}} ->
        if Enum.any?(actions, &String.ends_with?(&1.href, "/resolve")) do
          {:ok, "Close this episode as no longer needed?",
           "Ryker will cancel the exact blocked or waiting owner. Nothing is deleted and no new external action is authorized.",
           "episode:resolve"}
        else
          {:error, :not_found}
        end

      _unavailable ->
        {:error, :not_found}
    end
  end

  defp confirmation("episode", resource_ref, "review", options) do
    case options.projection.episode.(resource_ref, %{}) do
      {:ok, %{trace: %{review: %{awaiting: true}}}} ->
        {:ok, "Mark this ending reviewed?",
         "This records that the local operator read this exact terminal semantic version. A later ending becomes reviewable again.",
         "episode:review"}

      _unavailable ->
        {:error, :not_found}
    end
  end

  defp confirmation("emisar", resource_ref, "rearm", options) do
    case options.projection.emisar.(resource_ref) do
      {:ok, %{action: :rearm, status: :blocked}} ->
        {:ok, "Resume approval checks?",
         "Ryker will resume read-only observation of the same governed Emisar request. It will not approve, deny, or repeat the action.",
         "emisar:rearm"}

      _unavailable ->
        {:error, :not_found}
    end
  end

  defp confirmation("slack_interaction", resource_ref, "rearm", options) do
    case options.projection.slack_interaction.(resource_ref) do
      {:ok, %{action: :rearm, status: :blocked}} ->
        {:ok, "Refresh this Slack message?",
         "Ryker will repaint the exact host-owned message recorded by the original interaction audit.",
         "slack_interaction:rearm"}

      _unavailable ->
        {:error, :not_found}
    end
  end

  defp confirmation("slack_incident", resource_ref, "rearm", options) do
    case options.projection.slack_incident.(resource_ref) do
      {:ok, %{action: :rearm, status: :blocked}} ->
        {:ok, "Resume incident room setup?",
         "Ryker will continue the exact durable Slack room reconciliation without duplicating resources already recorded.",
         "slack_incident:rearm"}

      _unavailable ->
        {:error, :not_found}
    end
  end

  defp confirmation("retention", resource_ref, "rearm", options) do
    case options.projection.workspace.(resource_ref) do
      {:ok, %{action: :rearm, status: :blocked}} ->
        {:ok, "Resume workspace cleanup?",
         "Ryker will resume the exact blocked cleanup phase without changing its frozen Coop identity.",
         "retention:rearm"}

      _unavailable ->
        {:error, :not_found}
    end
  end

  defp confirmation("retention", resource_ref, "discard", options) do
    case options.projection.workspace.(resource_ref) do
      {:ok, %{action: :discard_unmerged, status: :retained}} ->
        {:ok, "Discard this unmerged workspace?",
         "Ryker will request a fresh exact Coop discard plan that accepts unmerged commits. Dirty work will still be retained.",
         "retention:discard_unmerged"}

      _unavailable ->
        {:error, :not_found}
    end
  end

  defp confirmation(_kind, _resource_ref, _action, _snapshot), do: {:error, :not_found}

  defp perform("work", resource_ref, "retry", actions, "work:retry:" <> fingerprint),
    do: actions.retry_work.(resource_ref, fingerprint)

  defp perform(kind, resource_ref, action, actions, _canonical_action),
    do: perform(kind, resource_ref, action, actions)

  defp perform("memory", resource_ref, "forget", actions),
    do: actions.forget_memory.(resource_ref)

  defp perform("memory-review", resource_ref, action, actions)
       when action in ["keep", "merge", "forget", "dismiss"],
       do: actions.resolve_memory_review.(resource_ref, memory_review_action(action), nil)

  defp perform("admission", resource_ref, "rearm", actions),
    do: actions.rearm_admission.(resource_ref)

  defp perform("delivery", resource_ref, "rearm", actions),
    do: actions.rearm_delivery.(resource_ref)

  defp perform("emisar", resource_ref, "rearm", actions),
    do: actions.rearm_emisar.(resource_ref)

  defp perform("retention", resource_ref, "rearm", actions),
    do: actions.rearm_retention.(resource_ref)

  defp perform("retention", resource_ref, "discard", actions),
    do: actions.discard_retention.(resource_ref)

  defp perform("slack_interaction", resource_ref, "rearm", actions),
    do: actions.rearm_slack_interaction.(resource_ref)

  defp perform("slack_incident", resource_ref, "rearm", actions),
    do: actions.rearm_slack_incident.(resource_ref)

  defp perform("episode", resource_ref, "resolve", actions),
    do: actions.resolve_episode.(resource_ref)

  defp perform("episode", resource_ref, "review", actions),
    do: actions.review_episode.(resource_ref)

  defp perform("behavior", resource_ref, action, actions)
       when action in ["active", "disabled", "deleted"],
       do: actions.set_behavior_status.(resource_ref, String.to_existing_atom(action))

  defp perform("schedule", resource_ref, action, actions)
       when action in ["active", "paused", "deleted"],
       do: actions.set_schedule_status.(resource_ref, String.to_existing_atom(action))

  defp perform("schedule", resource_ref, "run-now", actions),
    do: actions.run_schedule.(resource_ref)

  defp perform(_kind, _resource_ref, _action, _actions), do: {:error, :invalid_action}

  defp memory_review_action("keep"), do: :keep
  defp memory_review_action("merge"), do: :merge
  defp memory_review_action("forget"), do: :forget
  defp memory_review_action("dismiss"), do: :dismiss

  defp action_return_path("episode", resource_ref),
    do: "/timeline/#{URI.encode(resource_ref, &URI.char_unreserved?/1)}"

  defp action_return_path("delivery", _resource_ref), do: "/failures"
  defp action_return_path("retention", _resource_ref), do: "/workspaces"
  defp action_return_path("schedule", _resource_ref), do: "/schedules"

  defp action_return_path(kind, _resource_ref)
       when kind in ["admission", "emisar", "slack_incident", "slack_interaction", "work"],
       do: "/failures"

  defp action_return_path(_kind, _resource_ref), do: "/memory"

  defp action_return_path("behavior", resource_ref, options) do
    case options.projection.behavior.(resource_ref) do
      {:ok, %{kind: kind}} -> BehaviorLibrary.path(kind)
      _unavailable -> "/memory"
    end
  end

  defp action_return_path(kind, resource_ref, _options),
    do: action_return_path(kind, resource_ref)

  defp form_token(conn) do
    with [content_type] <- get_req_header(conn, "content-type"),
         true <-
           String.starts_with?(String.downcase(content_type), "application/x-www-form-urlencoded"),
         {:ok, body, conn} <- read_form(conn),
         %{"_token" => token} = form <- Query.decode(body),
         true <- Map.keys(form) == ["_token"] and is_binary(token) do
      {:ok, token, conn}
    else
      _invalid -> {:error, :form}
    end
  end

  defp learning_retry_form(conn) do
    with [content_type] <- get_req_header(conn, "content-type"),
         true <-
           String.starts_with?(String.downcase(content_type), "application/x-www-form-urlencoded"),
         {:ok, body, conn} <- read_form(conn),
         %{"_token" => token, "budget_version" => version} = form <- Query.decode(body),
         true <- Enum.sort(Map.keys(form)) == ["_token", "budget_version"],
         true <- is_binary(token) and is_binary(version),
         {number, ""} when number in 0..2_147_483_647 <- Integer.parse(version) do
      {:ok, %{token: token, version: number}, conn}
    else
      _ -> {:error, :form}
    end
  end

  defp learning_redirect(conn, batch_id) do
    conn
    |> put_resp_header("location", LearningActivity.path(batch_id))
    |> send_resp(303, "")
    |> halt()
  end

  defp learning_source_form(conn, fields) do
    keys = Enum.map(fields, &Atom.to_string/1)

    with [content_type] <- get_req_header(conn, "content-type"),
         true <-
           String.starts_with?(String.downcase(content_type), "application/x-www-form-urlencoded"),
         {:ok, body, conn} <- read_memory_form(conn),
         %{"_token" => token, "sources" => sources} = form <- Query.decode(body),
         true <- Enum.sort(Map.keys(form)) == Enum.sort(["_token", "sources" | keys]),
         true <- is_binary(token),
         {:ok, versions} <- learning_source_versions(form, fields),
         {:ok, sources} <- learning_source_selection(sources) do
      {:ok, Map.merge(versions, %{token: token, sources: sources}), conn}
    else
      _ -> {:error, :form}
    end
  rescue
    Plug.Conn.InvalidQueryError -> {:error, :form}
  end

  defp learning_source_versions(form, fields) do
    Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, parsed} ->
      minimum = if field == :budget_version, do: 0, else: 1

      case learning_source_version(form[Atom.to_string(field)], minimum) do
        number when is_integer(number) -> {:cont, {:ok, Map.put(parsed, field, number)}}
        nil -> {:halt, {:error, :form}}
      end
    end)
  end

  defp learning_source_version(value, minimum) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= minimum and number <= 2_147_483_647 -> number
      _ -> nil
    end
  end

  defp learning_source_version(_, _), do: nil

  defp learning_source_selection(values) when is_list(values) and length(values) in 1..16 do
    sources = Enum.map(values, &decode_learning_source/1)

    if Enum.all?(sources, &is_map/1) and
         length(Enum.uniq_by(sources, & &1["source_input_id"])) == length(sources),
       do: {:ok, sources},
       else: {:error, :form}
  end

  defp learning_source_selection(_), do: {:error, :form}

  defp decode_learning_source(value) when is_binary(value) and byte_size(value) <= 512 do
    with {:ok, raw} <- Base.url_decode64(value, padding: false),
         {:ok,
          %{"source_input_id" => id, "revision" => revision, "fingerprint" => fingerprint} =
            source} <- Jason.decode(raw),
         true <- Enum.sort(Map.keys(source)) == ["fingerprint", "revision", "source_input_id"],
         {:ok, ^id} <- Ecto.UUID.cast(id),
         true <- is_integer(revision) and revision >= 1 and revision <= 9_223_372_036_854_775_807,
         true <- is_binary(fingerprint) and Regex.match?(~r/\A[0-9a-f]{64}\z/, fingerprint),
         true <- raw == CanonicalJSON.encode!(source) do
      source
    else
      _ -> nil
    end
  end

  defp decode_learning_source(_), do: nil

  defp memory_review_form(conn) do
    with [content_type] <- get_req_header(conn, "content-type"),
         true <-
           String.starts_with?(String.downcase(content_type), "application/x-www-form-urlencoded"),
         {:ok, body, conn} <- read_memory_form(conn),
         %{"_token" => token, "subject" => subject, "value" => value} = form <-
           Query.decode(body),
         true <- Enum.sort(Map.keys(form)) == ["_token", "subject", "value"],
         true <- is_binary(token) and is_binary(subject) and is_binary(value) do
      {:ok, token, subject, value, conn}
    else
      _invalid -> {:error, :form}
    end
  end

  defp lab_form(conn) do
    case get_req_header(conn, "content-type") do
      [content_type] -> lab_form(conn, String.downcase(content_type))
      _invalid -> {:error, :form}
    end
  end

  defp lab_form(conn, "application/x-www-form-urlencoded" <> _parameters) do
    with {:ok, body, conn} <- read_lab_form(conn),
         %{"_token" => token, "message" => message} = form <- Query.decode(body),
         true <- Enum.sort(Map.keys(form)) == ["_token", "message"],
         true <- is_binary(token) and is_binary(message) do
      {:ok, token, message, [], conn}
    else
      _invalid -> {:error, :form}
    end
  end

  defp lab_form(conn, "multipart/form-data" <> _parameters) do
    with {:ok, conn} <- parse_lab_multipart(conn),
         %{"_token" => token, "message" => message} = form <- conn.body_params,
         true <- Map.keys(form) -- ["_token", "attachments", "message"] == [],
         true <- is_binary(token) and is_binary(message),
         {:ok, attachments} <- lab_uploads(Map.get(form, "attachments", [])) do
      {:ok, token, message, attachments, conn}
    else
      _invalid -> {:error, :form}
    end
  end

  defp lab_form(_conn, _content_type), do: {:error, :form}

  defp parse_lab_multipart(conn) do
    {:ok, Plug.Parsers.call(conn, @lab_multipart_parser)}
  rescue
    _error in [
      Plug.Parsers.BadEncodingError,
      Plug.Parsers.ParseError,
      Plug.Parsers.RequestTooLargeError,
      Plug.UploadError
    ] ->
      {:error, :form}
  end

  defp lab_uploads([]), do: {:ok, []}
  defp lab_uploads(%Plug.Upload{} = upload), do: lab_uploads([upload])

  defp lab_uploads(uploads) when is_list(uploads) and length(uploads) <= 2 do
    Enum.reduce_while(uploads, {:ok, []}, fn
      %Plug.Upload{content_type: media_type, filename: name, path: path}, {:ok, attachments}
      when is_binary(media_type) and is_binary(name) and is_binary(path) ->
        case File.read(path) do
          {:ok, data} ->
            attachment = %{data: data, media_type: media_type, name: name}
            {:cont, {:ok, [attachment | attachments]}}

          {:error, _reason} ->
            {:halt, {:error, :form}}
        end

      _invalid, _attachments ->
        {:halt, {:error, :form}}
    end)
    |> case do
      {:ok, attachments} -> {:ok, Enum.reverse(attachments)}
      {:error, :form} = error -> error
    end
  end

  defp lab_uploads(_uploads), do: {:error, :form}

  defp lab_record_form(conn, :answer_input) do
    with [content_type] <- get_req_header(conn, "content-type"),
         true <-
           String.starts_with?(String.downcase(content_type), "application/x-www-form-urlencoded"),
         {:ok, body, conn} <- read_form(conn),
         %{"_token" => token, "choice_index" => choice_index} = form <- Query.decode(body),
         true <- Enum.sort(Map.keys(form)) == ["_token", "choice_index"],
         {choice_index, ""} when choice_index in 0..9 <- Integer.parse(choice_index) do
      {:ok, token, choice_index, conn}
    else
      _invalid -> {:error, :form}
    end
  end

  defp lab_record_form(conn, action)
       when action in [
              :retry_task_publication,
              :update_task_publication,
              :discard_task_publication
            ] do
    with [content_type] <- get_req_header(conn, "content-type"),
         true <-
           String.starts_with?(String.downcase(content_type), "application/x-www-form-urlencoded"),
         {:ok, body, conn} <- read_form(conn),
         %{
           "_token" => token,
           "choice_index" => generation,
           "publication_ref" => publication_ref
         } = form <- Query.decode(body),
         true <- Enum.sort(Map.keys(form)) == ["_token", "choice_index", "publication_ref"],
         {generation, ""} when generation > 0 <- Integer.parse(generation),
         {:ok, publication_ref} <- PathRef.decode(publication_ref) do
      {:ok, token, %{generation: generation, publication_ref: publication_ref}, conn}
    else
      _invalid -> {:error, :form}
    end
  end

  defp lab_record_form(conn, action)
       when action in [:approve_task_publication, :check_task_publication] do
    with [content_type] <- get_req_header(conn, "content-type"),
         true <-
           String.starts_with?(String.downcase(content_type), "application/x-www-form-urlencoded"),
         {:ok, body, conn} <- read_form(conn),
         %{"_token" => token, "publication_ref" => publication_ref} = form <- Query.decode(body),
         true <- Enum.sort(Map.keys(form)) == ["_token", "publication_ref"],
         {:ok, publication_ref} <- PathRef.decode(publication_ref) do
      {:ok, token, %{publication_ref: publication_ref}, conn}
    else
      _invalid -> {:error, :form}
    end
  end

  defp lab_record_form(conn, _action) do
    with {:ok, token, conn} <- form_token(conn) do
      {:ok, token, nil, conn}
    end
  end

  defp read_form(conn) do
    case read_body(conn, length: @maximum_form_bytes + 1, read_length: @maximum_form_bytes + 1) do
      {:ok, body, conn} when byte_size(body) <= @maximum_form_bytes -> {:ok, body, conn}
      _invalid -> {:error, :form}
    end
  end

  defp read_memory_form(conn) do
    case read_body(conn,
           length: @maximum_memory_form_bytes + 1,
           read_length: @maximum_memory_form_bytes + 1
         ) do
      {:ok, body, conn} when byte_size(body) <= @maximum_memory_form_bytes -> {:ok, body, conn}
      _invalid -> {:error, :form}
    end
  end

  defp read_lab_form(conn) do
    case read_body(conn,
           length: @maximum_lab_form_bytes + 1,
           read_length: @maximum_lab_form_bytes + 1
         ) do
      {:ok, body, conn} when byte_size(body) <= @maximum_lab_form_bytes -> {:ok, body, conn}
      _invalid -> {:error, :form}
    end
  end

  # A durable acceptance answers the page's own JavaScript with a 202 receipt
  # so the view reconciles through the live stream, and a plain browser
  # submission with the redirect it expects. Both mean the same thing: the
  # action is recorded, exactly once.
  defp lab_accepted(conn, conversation_id) do
    if get_req_header(conn, "accept") == ["application/json"] do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(202, Jason.encode!(%{accepted: true}))
      |> halt()
    else
      conn
      |> put_resp_header("location", "/conversations/#{conversation_id}")
      |> send_resp(303, "")
      |> halt()
    end
  end

  defp action_path(kind, resource_ref, action),
    do: "/actions/#{kind}/#{URI.encode(resource_ref, &URI.char_unreserved?/1)}/#{action}"

  defp editable_memory_review(resource_ref, options) do
    case Enum.find(options.projection.memory.(%{}).reviews, &(&1["review_ref"] == resource_ref)) do
      %{"entries" => [_entry], "kind" => "stale", "status" => "pending"} = review ->
        {:ok, review}

      _missing_or_incompatible ->
        {:error, :not_found}
    end
  end

  # A confirmed action or record view is a title and a body in the static
  # shell; the title is the page's only heading and the body owns the rest.
  defp html(conn, status, title, body) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, HTML.page(title, nil, body))
    |> halt()
  end

  defp text(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
    |> halt()
  end

  defp artifact(conn, artifact) do
    filename = URI.encode(artifact.name, &URI.char_unreserved?/1)

    conn
    |> put_resp_header("content-type", artifact.media_type)
    |> put_resp_header("content-disposition", "inline; filename*=UTF-8''#{filename}")
    |> put_resp_header("etag", ~s("#{artifact.sha256}"))
    |> send_resp(200, artifact.data)
    |> halt()
  end
end
