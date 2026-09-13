defmodule Ryker.ControlPlane.Router do
  alias Ryker.ControlPlane.SlackNames
  @moduledoc false

  import Plug.Conn

  alias Phoenix.HTML.Safe
  alias Plug.Conn.Query
  alias Ryker.CanonicalJSON

  alias Ryker.ControlPlane.{
    BehaviorLibrary,
    BehaviorPage,
    ChannelDetail,
    ChannelPage,
    CSRF,
    HTML,
    LearningActivity,
    Projection,
    RelearnPanel,
    SettingsPage
  }

  alias Ryker.Learning.Operator, as: LearningOperator

  @behaviour Plug
  @maximum_form_bytes 4_096
  @maximum_memory_form_bytes 16 * 1_024
  @maximum_lab_form_bytes 65_536
  @maximum_lab_multipart_bytes 8 * 1_024 * 1_024 + @maximum_lab_form_bytes
  @lab_multipart_parser Plug.Parsers.init(
                          parsers: [{:multipart, length: @maximum_lab_multipart_bytes}],
                          query_string_length: 4_096
                        )
  @allowed_hosts ["127.0.0.1", "localhost", "::1"]
  @lab_action "conversation_lab:send"
  @lab_message_action "conversation_lab:message"
  @lab_reaction_action "conversation_lab:reaction"
  @lab_record_action "conversation_lab:record"

  @impl Plug
  def init(options) do
    options = if is_list(options), do: Map.new(options), else: options

    if is_map(options) and is_map(options[:actions]) and is_map(options[:observability]) and
         is_map(options[:projection]) and
         is_binary(options[:csrf_secret]) and byte_size(options.csrf_secret) == 32 do
      options
    else
      raise ArgumentError, "control-plane router options are invalid"
    end
  end

  @impl Plug
  def call(conn, options) do
    conn = conn |> security_headers() |> put_resp_header("x-ryker-version", release_version())

    cond do
      conn.host not in @allowed_hosts -> text(conn, 421, "Misdirected request")
      not loopback?(conn.remote_ip) -> text(conn, 403, "Loopback access only")
      true -> route(conn, options)
    end
  end

  @doc false
  def snapshot(path, query, options) do
    segments = String.split(path, "/", trim: true)

    if snapshot_path?(segments) do
      route(
        %Plug.Conn{
          method: "GET",
          path_info: segments,
          request_path: path,
          query_string: query,
          host: "localhost",
          remote_ip: {127, 0, 0, 1},
          private: %{control_plane_snapshot: true}
        },
        options
      )
    else
      %{
        status: 404,
        title: "Not found",
        description: nil,
        body: "<p>This view does not exist.</p>"
      }
    end
  end

  defp snapshot_path?([]), do: true

  defp snapshot_path?([page]),
    do:
      page in ~w(conversations incident-rooms schedules subscriptions channels repositories failures workspaces findings memory rules preferences guidance usage configuration)

  defp snapshot_path?([page, _ref]),
    do: page in ~w(conversations incident-rooms schedules)

  defp snapshot_path?([page, _, _]), do: page in ~w(channels failures)
  defp snapshot_path?(_path), do: false

  defp release_version do
    case Application.spec(:ryker, :vsn) do
      nil -> "unknown"
      version -> to_string(version)
    end
  end

  defp route(%Plug.Conn{method: "GET", path_info: []} = conn, options) do
    snapshot = options.projection.overview.()
    html(conn, 200, "Overview", HTML.overview(snapshot))
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["healthz"]} = conn, options) do
    case options.observability.health.() do
      {:ok, _health} -> text(conn, 200, "ok\n")
      {:error, _reason} -> text(conn, 503, "unavailable\n")
    end
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["readyz"]} = conn, options) do
    case options.observability.ready.() do
      {:ok, _readiness} -> text(conn, 200, "ready\n")
      {:error, _reason} -> text(conn, 503, "not ready\n")
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

  defp route(%Plug.Conn{method: "GET", path_info: ["conversations"]} = conn, options) do
    html(conn, 200, "Conversations", HTML.lab_index(options.projection.lab_index.()))
  end

  # A new conversation is an identity, not a record: the live index binds its
  # composer to a fresh identity and nothing is written until the first
  # message, so opening it twice cannot leave two empty chats behind. There is
  # no /conversations/new redirect; "new" is not a conversation and 404s.
  defp route(
         %Plug.Conn{method: "GET", path_info: ["conversations", conversation_id]} = conn,
         options
       ) do
    case lab_id(conversation_id) do
      {:ok, conversation_id} -> render_lab(conn, options, conversation_id)
      {:error, :path_ref} -> html(conn, 404, "Not found", HTML.generic("Conversation", []))
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
    with {:ok, conversation_id} <- lab_id(conversation_id),
         {:ok, turn_id} <- lab_id(turn_id),
         {:ok, artifact_ref} <- path_ref(artifact_ref),
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
    with {:ok, conversation_id} <- lab_id(conversation_id),
         {:ok, token, message, attachments, conn} <- lab_form(conn),
         true <- CSRF.valid?(options.csrf_secret, @lab_action, conversation_id, token),
         {:ok, _receipt} <-
           options.actions.send_lab_message.(conversation_id, message, attachments) do
      lab_accepted(conn, conversation_id)
    else
      false -> text(conn, 403, "Invalid confirmation token")
      {:error, :path_ref} -> text(conn, 404, "Conversation not found")
      {:error, :form} -> text(conn, 400, "Invalid form")
      {:error, {:invalid_conversation_lab, _field}} -> text(conn, 422, "Invalid message")
      {:error, _reason} -> text(conn, 409, "Message could not be accepted")
    end
  end

  defp route(
         %Plug.Conn{
           method: "POST",
           path_info: ["conversations", conversation_id, "messages", item_id, "edit"]
         } = conn,
         options
       ) do
    with {:ok, conversation_id} <- lab_id(conversation_id),
         {:ok, item_id} <- lab_id(item_id),
         {:ok, token, message, conn} <- lab_message_edit_form(conn),
         resource <- lab_message_resource(conversation_id, item_id, :edit),
         true <- CSRF.valid?(options.csrf_secret, @lab_message_action, resource, token),
         {:ok, _receipt} <- options.actions.edit_lab_message.(conversation_id, item_id, message) do
      lab_accepted(conn, conversation_id)
    else
      false -> text(conn, 403, "Invalid confirmation token")
      {:error, :path_ref} -> text(conn, 404, "Message not found")
      {:error, :form} -> text(conn, 400, "Invalid form")
      {:error, {:invalid_conversation_lab, :message}} -> text(conn, 422, "Invalid message")
      {:error, {:invalid_conversation_lab, _field}} -> text(conn, 409, "Message changed")
      {:error, _reason} -> text(conn, 409, "Message could not be edited")
    end
  end

  defp route(
         %Plug.Conn{
           method: "POST",
           path_info: ["conversations", conversation_id, "messages", item_id, "delete"]
         } = conn,
         options
       ) do
    with {:ok, conversation_id} <- lab_id(conversation_id),
         {:ok, item_id} <- lab_id(item_id),
         {:ok, token, conn} <- form_token(conn),
         resource <- lab_message_resource(conversation_id, item_id, :delete),
         true <- CSRF.valid?(options.csrf_secret, @lab_message_action, resource, token),
         {:ok, _receipt} <- options.actions.delete_lab_message.(conversation_id, item_id) do
      lab_accepted(conn, conversation_id)
    else
      false -> text(conn, 403, "Invalid confirmation token")
      {:error, :path_ref} -> text(conn, 404, "Message not found")
      {:error, :form} -> text(conn, 400, "Invalid form")
      {:error, {:invalid_conversation_lab, _field}} -> text(conn, 409, "Message changed")
      {:error, _reason} -> text(conn, 409, "Message could not be deleted")
    end
  end

  defp route(
         %Plug.Conn{
           method: "POST",
           path_info: ["conversations", conversation_id, "replies", message_ref, "reactions"]
         } = conn,
         options
       ) do
    with {:ok, conversation_id} <- lab_id(conversation_id),
         {:ok, message_ref} <- path_ref(message_ref),
         {:ok, token, action, emoji_name, conn} <- lab_reaction_form(conn),
         resource <- lab_reaction_resource(conversation_id, message_ref),
         true <- CSRF.valid?(options.csrf_secret, @lab_reaction_action, resource, token),
         {:ok, _transition} <-
           options.actions.react_to_lab_message.(
             conversation_id,
             message_ref,
             action,
             emoji_name
           ) do
      lab_accepted(conn, conversation_id)
    else
      false -> text(conn, 403, "Invalid confirmation token")
      {:error, :path_ref} -> text(conn, 404, "Message not found")
      {:error, :form} -> text(conn, 400, "Invalid reaction")
      {:error, :conversation_reaction_target_not_found} -> text(conn, 404, "Message not found")
      {:error, {:invalid_conversation_lab, _field}} -> text(conn, 422, "Invalid reaction")
      {:error, _reason} -> text(conn, 409, "Reaction could not be recorded")
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

    with {:ok, conversation_id} <- lab_id(conversation_id),
         {:ok, record_ref} <- path_ref(record_ref),
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
    with {:ok, conversation_id} <- lab_id(conversation_id),
         {:ok, record_ref} <- path_ref(record_ref),
         {:ok, action} <- lab_record_action(action_name),
         {:ok, token, action_context, conn} <- lab_record_form(conn, action),
         resource <- lab_record_resource(conversation_id, record_ref, action, action_context),
         true <- CSRF.valid?(options.csrf_secret, @lab_record_action, resource, token),
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

  defp route(%Plug.Conn{method: "GET", path_info: ["incident-rooms"]} = conn, options) do
    conn = fetch_query_params(conn)
    snapshot = options.projection.incidents.(Map.take(conn.query_params, ["q", "status"]))

    html(
      conn,
      200,
      "Incident rooms",
      "Track Slack incident rooms from setup through closure, with channel status and linked investigation work.",
      HTML.incidents(snapshot, conn.query_params)
    )
  end

  defp route(
         %Plug.Conn{method: "GET", path_info: ["incident-rooms", incident_ref]} = conn,
         options
       ) do
    case path_ref(incident_ref) do
      {:ok, incident_ref} -> render_incident(conn, options, incident_ref)
      {:error, :path_ref} -> html(conn, 404, "Not found", HTML.generic("Incident room", []))
    end
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["schedules"]} = conn, options) do
    conn = fetch_query_params(conn)
    snapshot = options.projection.schedules.(Map.take(conn.query_params, ["q", "status"]))

    html(
      conn,
      200,
      "Schedules",
      "Recurring and one-shot work Ryker has agreed to run, with each dispatched or missed occurrence.",
      HTML.schedules(snapshot, conn.query_params)
    )
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["schedules", schedule_ref]} = conn, options) do
    case path_ref(schedule_ref) do
      {:ok, schedule_ref} -> render_schedule(conn, options, schedule_ref)
      {:error, :path_ref} -> html(conn, 404, "Not found", HTML.generic("Schedule", []))
    end
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["subscriptions"]} = conn, options) do
    conn = fetch_query_params(conn)

    snapshot =
      options.projection.subscriptions.(Map.take(conn.query_params, ["q", "status"]))

    html(
      conn,
      200,
      "Waits",
      "What the agent is waiting for, when it will check again, and what resumed the work.",
      HTML.subscriptions(snapshot, conn.query_params)
    )
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["channels"]} = conn, options) do
    conn = fetch_query_params(conn)
    snapshot = options.projection.channels.(Map.take(conn.query_params, ["q"]))

    html(
      conn,
      200,
      "Channels",
      "Slack channels Ryker knows about: configuration, membership, repository and recorded work.",
      HTML.channels(snapshot, conn.query_params)
    )
  end

  defp route(
         %Plug.Conn{method: "GET", path_info: ["channels", workspace_ref, channel_ref]} = conn,
         options
       ) do
    with {:ok, workspace_ref} <- path_ref(workspace_ref),
         {:ok, channel_ref} <- path_ref(channel_ref) do
      conn = fetch_query_params(conn)
      params = Map.take(conn.query_params, ChannelDetail.query_keys())

      case options.projection.channel.(workspace_ref, channel_ref, params) do
        {:ok, snapshot} ->
          html(
            conn,
            200,
            SlackNames.name(workspace_ref, channel_ref),
            ChannelPage.description(snapshot),
            [
              Safe.to_iodata(ChannelPage.lead(%{__changed__: nil, view: snapshot})),
              Safe.to_iodata(ChannelPage.render(%{__changed__: nil, view: snapshot}))
            ]
          )

        :not_found ->
          html(conn, 404, "Not found", HTML.generic("Channel", []))

        {:error, _reason} ->
          html(conn, 503, "Unavailable", HTML.generic("Channel", []))
      end
    else
      {:error, :path_ref} -> html(conn, 404, "Not found", HTML.generic("Channel", []))
    end
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["repositories"]} = conn, options) do
    conn = fetch_query_params(conn)
    snapshot = options.projection.repositories.(Map.take(conn.query_params, ["q"]))

    html(
      conn,
      200,
      "Repositories",
      "Connected repositories, the work they receive, and the code revision last used.",
      HTML.repositories(snapshot, conn.query_params)
    )
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["memory"]} = conn, options) do
    html(
      conn,
      200,
      "Memory",
      "What Ryker learned from conversations, with the messages and work it came from.",
      HTML.memory(
        options.projection.memory.(fetch_query_params(conn).query_params),
        options.csrf_secret
      )
    )
  end

  defp route(%Plug.Conn{method: "GET", path_info: [page]} = conn, options)
       when page in ~w(rules preferences guidance) do
    conn = fetch_query_params(conn)
    kind = BehaviorLibrary.kind(page)
    snapshot = options.projection.behaviors.(kind, conn.query_params)

    body =
      BehaviorPage.render(%{__changed__: nil, view: snapshot})
      |> Safe.to_iodata()

    html(conn, 200, BehaviorPage.title(kind), BehaviorPage.description(kind), body)
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

  defp route(%Plug.Conn{method: "GET", path_info: ["configuration"]} = conn, options) do
    html(
      conn,
      200,
      "Settings",
      SettingsPage.description(),
      HTML.configuration(options.projection.operator_configuration.())
    )
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["usage"]} = conn, options) do
    conn = fetch_query_params(conn)
    snapshot = options.projection.usage.(Map.take(conn.query_params, ["window", "mode", "page"]))
    html(conn, 200, "Usage & cost", HTML.usage(snapshot))
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["failures"]} = conn, options) do
    conn = fetch_query_params(conn)

    case options.projection.failures.(conn.query_params) do
      {:ok, rows} -> html(conn, 200, "Failures", HTML.failures(rows))
      {:error, _reason} -> text(conn, 503, "Failures unavailable")
    end
  end

  defp route(
         %Plug.Conn{method: "GET", path_info: ["failures", kind, resource_ref]} = conn,
         options
       ) do
    with true <- kind in failure_kinds(),
         {:ok, resource_ref} <- path_ref(resource_ref),
         {:ok, failures} <- options.projection.failures.(%{}),
         %{} = row <-
           Enum.find(failures, fn row ->
             row.kind == kind and row.ref == resource_ref
           end) do
      html(conn, 200, "Recovery", HTML.failure(row))
    else
      {:error, _reason} -> text(conn, 503, "Failure context unavailable")
      _not_found -> html(conn, 404, "Not found", HTML.generic("Failure", []))
    end
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["workspaces"]} = conn, options) do
    conn = fetch_query_params(conn)

    html(
      conn,
      200,
      "Workspaces",
      "Repository checkouts used by tasks, not Slack workspaces: what each one holds, what cleanup will do next, and the storage workers report.",
      HTML.workspaces(
        options.projection.workspaces.(conn.query_params),
        options.projection.workspace_storage.()
      )
    )
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["findings"]} = conn, options) do
    conn = fetch_query_params(conn)

    html(
      conn,
      200,
      "Findings",
      "Saved investigation conclusions with the evidence behind them: what needs explaining, what explains it, or why it is expected.",
      HTML.findings(options.projection.findings.(conn.query_params))
    )
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["static", "app.css"]} = conn, _options) do
    conn
    |> put_resp_content_type("text/css")
    |> send_resp(200, HTML.css())
    |> halt()
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["static", "lab.js"]} = conn, _options) do
    conn
    |> put_resp_content_type("text/javascript")
    |> send_resp(200, HTML.lab_javascript())
    |> halt()
  end

  defp route(
         %Plug.Conn{
           method: "GET",
           path_info: ["actions", "memory-review", resource_ref, "edit"]
         } = conn,
         options
       ) do
    with {:ok, resource_ref} <- path_ref(resource_ref),
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
      {:error, _reason} -> html(conn, 404, "Not found", HTML.generic("Action", []))
    end
  end

  defp route(
         %Plug.Conn{
           method: "POST",
           path_info: ["actions", "memory-review", resource_ref, "edit"]
         } = conn,
         options
       ) do
    with {:ok, resource_ref} <- path_ref(resource_ref),
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
    with {:ok, resource_ref} <- path_ref(resource_ref),
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
      {:error, _reason} -> html(conn, 404, "Not found", HTML.generic("Action", []))
    end
  end

  defp route(
         %Plug.Conn{method: "POST", path_info: ["actions", kind, resource_ref, action]} = conn,
         options
       ) do
    with {:ok, resource_ref} <- path_ref(resource_ref),
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
    do: html(conn, 404, "Not found", HTML.generic("Page", []))

  defp route(conn, _options), do: text(conn, 405, "Method not allowed")

  defp render_incident(conn, options, incident_ref) do
    case options.projection.incident.(incident_ref) do
      {:ok, snapshot} -> html(conn, 200, snapshot.room.title, HTML.incident(snapshot))
      :not_found -> html(conn, 404, "Not found", HTML.generic("Incident room", []))
      {:error, _reason} -> html(conn, 503, "Unavailable", HTML.generic("Incident room", []))
    end
  end

  defp render_schedule(conn, options, schedule_ref) do
    case options.projection.schedule.(schedule_ref) do
      {:ok, snapshot} -> html(conn, 200, snapshot.schedule.title, HTML.schedule(snapshot))
      :not_found -> html(conn, 404, "Not found", HTML.generic("Schedule", []))
      {:error, _reason} -> html(conn, 503, "Unavailable", HTML.generic("Schedule", []))
    end
  end

  defp render_lab(conn, options, conversation_id) do
    case lab_snapshot(conversation_id, options) do
      {:ok, snapshot, token} ->
        html(conn, 200, "Conversations", HTML.lab_conversation(snapshot, token))

      _unavailable ->
        html(conn, 503, "Unavailable", HTML.generic("Conversation", []))
    end
  end

  @doc false
  def lab_snapshot(conversation_id, options) do
    with {:ok, conversation_id} <- lab_id(conversation_id) do
      prepare_lab_snapshot(conversation_id, options)
    end
  end

  # One older page of a conversation, decorated with the same edit, reaction
  # and record controls as the latest page so a row loaded by scrolling up is
  # exactly as usable as one that was on screen at open.
  @doc false
  def lab_history(conversation_id, cursor, page_size, options) do
    with {:ok, conversation_id} <- lab_id(conversation_id),
         {:ok, page} <- options.projection.lab_history.(conversation_id, cursor, page_size) do
      decorated =
        %{conversation_id: conversation_id, messages: page.messages}
        |> lab_message_controls(options.csrf_secret)
        |> lab_record_controls(options.csrf_secret)

      {:ok, %{page | messages: decorated.messages}}
    else
      :not_found -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # The rows of a conversation that changed since a moment, decorated the
  # same way, so a live window can refresh a row it holds off the latest page.
  @doc false
  def lab_changes(conversation_id, since, page_size, options) do
    with {:ok, conversation_id} <- lab_id(conversation_id),
         {:ok, messages} <- options.projection.lab_changes.(conversation_id, since, page_size) do
      decorated =
        %{conversation_id: conversation_id, messages: messages}
        |> lab_message_controls(options.csrf_secret)
        |> lab_record_controls(options.csrf_secret)

      {:ok, decorated.messages}
    else
      :not_found -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_lab_snapshot(conversation_id, options) do
    snapshot =
      case options.projection.lab_conversation.(conversation_id) do
        {:ok, snapshot} -> snapshot
        :not_found -> empty_lab(conversation_id)
        {:error, _reason} -> nil
      end

    if snapshot do
      token = CSRF.token(options.csrf_secret, @lab_action, conversation_id)

      snapshot =
        snapshot
        |> lab_message_controls(options.csrf_secret)
        |> lab_record_controls(options.csrf_secret)

      {:ok, snapshot, token}
    else
      {:error, :projection_unavailable}
    end
  end

  defp lab_message_controls(snapshot, csrf_secret) do
    messages =
      Enum.map(snapshot.messages, fn message ->
        message
        |> put_lab_message_edit_controls(snapshot.conversation_id, csrf_secret)
        |> put_lab_reaction_controls(snapshot.conversation_id, csrf_secret)
      end)

    Map.put(snapshot, :messages, messages)
  end

  defp put_lab_message_edit_controls(
         %{actor: :operator, editable: true, item_id: item_id} = message,
         conversation_id,
         csrf_secret
       )
       when is_binary(item_id) do
    edit_resource = lab_message_resource(conversation_id, item_id, :edit)
    delete_resource = lab_message_resource(conversation_id, item_id, :delete)

    Map.put(message, :message_controls, %{
      delete: %{
        path: "/conversations/#{conversation_id}/messages/#{item_id}/delete",
        token: CSRF.token(csrf_secret, @lab_message_action, delete_resource)
      },
      edit: %{
        path: "/conversations/#{conversation_id}/messages/#{item_id}/edit",
        token: CSRF.token(csrf_secret, @lab_message_action, edit_resource)
      }
    })
  end

  defp put_lab_message_edit_controls(message, _conversation_id, _csrf_secret),
    do: Map.put(message, :message_controls, nil)

  defp put_lab_reaction_controls(
         %{actor: :ryker, message_ref: message_ref} = message,
         conversation_id,
         csrf_secret
       )
       when is_binary(message_ref) do
    resource = lab_reaction_resource(conversation_id, message_ref)

    Map.put(message, :reaction_controls, %{
      path:
        "/conversations/#{conversation_id}/replies/#{URI.encode(message_ref, &URI.char_unreserved?/1)}/reactions",
      token: CSRF.token(csrf_secret, @lab_reaction_action, resource)
    })
  end

  defp put_lab_reaction_controls(message, _conversation_id, _csrf_secret),
    do: Map.put(message, :reaction_controls, nil)

  defp empty_lab(conversation_id) do
    %{
      blocked: false,
      conversation_id: conversation_id,
      conversation_ref: "control-plane:lab:#{conversation_id}",
      episodes: [],
      history: %{before: nil, exhausted: true, page_size: Projection.lab_page_size()},
      live: false,
      messages: [],
      pending: 0
    }
  end

  defp lab_record_controls(snapshot, csrf_secret) do
    messages =
      Enum.map(snapshot.messages, fn message ->
        cards =
          message
          |> Map.get(:cards, [])
          |> Enum.map(&lab_card_controls(&1, snapshot.conversation_id, csrf_secret))

        Map.put(message, :cards, cards)
      end)

    Map.put(snapshot, :messages, messages)
  end

  defp lab_card_controls(
         %{actions: actions} = card,
         conversation_id,
         secret
       )
       when is_list(actions) and actions != [] do
    controls =
      Enum.map(actions, fn action ->
        action_context = lab_action_context(card, action)

        lab_record_control(
          card.ref,
          conversation_id,
          action,
          action_context,
          lab_record_label(action),
          secret
        )
      end)

    Map.put(card, :controls, controls)
  end

  defp lab_card_controls(%{action: nil} = card, _conversation_id, _secret),
    do: Map.put(card, :controls, [])

  defp lab_card_controls(%{action: :answer_input} = card, conversation_id, secret) do
    controls =
      card.choices
      |> Enum.with_index()
      |> Enum.map(fn {choice, index} ->
        lab_record_control(card.ref, conversation_id, :answer_input, index, choice, secret)
      end)

    Map.put(card, :controls, controls)
  end

  defp lab_card_controls(%{action: action} = card, conversation_id, secret) do
    control =
      lab_record_control(
        card.ref,
        conversation_id,
        action,
        nil,
        lab_record_label(action),
        secret
      )

    Map.put(card, :controls, [control])
  end

  defp lab_record_control(record_ref, conversation_id, action, action_context, label, secret) do
    action_name = lab_record_action_name(action)

    path =
      "/conversations/#{conversation_id}/records/#{URI.encode(record_ref, &URI.char_unreserved?/1)}/#{action_name}"

    if lab_record_read_action?(action) do
      %{
        choice_index: nil,
        label: label,
        method: :get,
        path: path,
        publication_ref: nil,
        token: nil
      }
    else
      resource = lab_record_resource(conversation_id, record_ref, action, action_context)

      %{
        choice_index: lab_choice_index(action_context),
        label: label,
        method: :post,
        path: path,
        publication_ref: lab_publication_ref(action_context),
        token: CSRF.token(secret, @lab_record_action, resource)
      }
    end
  end

  defp lab_record_read_action?(action),
    do:
      action in [
        :view_diff,
        :view_timeline,
        :view_evidence,
        :view_handoff,
        :view_postmortem
      ]

  defp lab_record_action("confirm-task"), do: {:ok, :confirm_task}
  defp lab_record_action("open-incident"), do: {:ok, :open_incident}
  defp lab_record_action("confirm-memory"), do: {:ok, :confirm_memory}
  defp lab_record_action("confirm-behavior"), do: {:ok, :confirm_behavior}
  defp lab_record_action("confirm-schedule"), do: {:ok, :confirm_schedule}
  defp lab_record_action("confirm-automation"), do: {:ok, :confirm_automation}
  defp lab_record_action("confirm-post"), do: {:ok, :confirm_post}
  defp lab_record_action("review-publication"), do: {:ok, :review_publication}
  defp lab_record_action("answer"), do: {:ok, :answer_input}
  defp lab_record_action("stop-task"), do: {:ok, :stop_task}
  defp lab_record_action("close-task"), do: {:ok, :close_task}
  defp lab_record_action("publish-draft"), do: {:ok, :approve_publication}
  defp lab_record_action("check-publication"), do: {:ok, :check_publication}
  defp lab_record_action("task-publish"), do: {:ok, :approve_task_publication}
  defp lab_record_action("task-check"), do: {:ok, :check_task_publication}
  defp lab_record_action("task-retry"), do: {:ok, :retry_task_publication}
  defp lab_record_action("task-update"), do: {:ok, :update_task_publication}
  defp lab_record_action("task-discard"), do: {:ok, :discard_task_publication}
  defp lab_record_action(_action), do: {:error, :lab_record_action}

  defp lab_record_action_name(:confirm_task), do: "confirm-task"
  defp lab_record_action_name(:open_incident), do: "open-incident"
  defp lab_record_action_name(:confirm_memory), do: "confirm-memory"
  defp lab_record_action_name(:confirm_behavior), do: "confirm-behavior"
  defp lab_record_action_name(:confirm_schedule), do: "confirm-schedule"
  defp lab_record_action_name(:confirm_automation), do: "confirm-automation"
  defp lab_record_action_name(:confirm_post), do: "confirm-post"
  defp lab_record_action_name(:review_publication), do: "review-publication"
  defp lab_record_action_name(:answer_input), do: "answer"
  defp lab_record_action_name(:stop_task), do: "stop-task"
  defp lab_record_action_name(:close_task), do: "close-task"
  defp lab_record_action_name(:approve_publication), do: "publish-draft"
  defp lab_record_action_name(:check_publication), do: "check-publication"
  defp lab_record_action_name(:approve_task_publication), do: "task-publish"
  defp lab_record_action_name(:check_task_publication), do: "task-check"
  defp lab_record_action_name(:retry_task_publication), do: "task-retry"
  defp lab_record_action_name(:update_task_publication), do: "task-update"
  defp lab_record_action_name(:discard_task_publication), do: "task-discard"
  defp lab_record_action_name(:view_diff), do: "diff"
  defp lab_record_action_name(:view_timeline), do: "timeline"
  defp lab_record_action_name(:view_evidence), do: "evidence"
  defp lab_record_action_name(:view_handoff), do: "handoff"
  defp lab_record_action_name(:view_postmortem), do: "postmortem"

  defp lab_record_label(:confirm_task), do: "Start task"
  defp lab_record_label(:open_incident), do: "Open local incident"
  defp lab_record_label(:confirm_memory), do: "Remember this"
  defp lab_record_label(:confirm_behavior), do: "Confirm"
  defp lab_record_label(:confirm_schedule), do: "Schedule this"
  defp lab_record_label(:confirm_automation), do: "Apply change"
  defp lab_record_label(:confirm_post), do: "Post locally"
  defp lab_record_label(:review_publication), do: "Review changes"
  defp lab_record_label(:stop_task), do: "Stop"
  defp lab_record_label(:close_task), do: "Close"
  defp lab_record_label(:approve_publication), do: "Publish draft"
  defp lab_record_label(:check_publication), do: "Check pull request"
  defp lab_record_label(:approve_task_publication), do: "Create draft PR"
  defp lab_record_label(:check_task_publication), do: "Check delivery"
  defp lab_record_label(:retry_task_publication), do: "Retry publication"
  defp lab_record_label(:update_task_publication), do: "Review latest state"
  defp lab_record_label(:discard_task_publication), do: "Discard candidate"
  defp lab_record_label(:view_diff), do: "View diff"
  defp lab_record_label(:view_timeline), do: "Timeline"
  defp lab_record_label(:view_evidence), do: "Evidence"
  defp lab_record_label(:view_handoff), do: "Handoff"
  defp lab_record_label(:view_postmortem), do: "Postmortem"

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
    base =
      "/conversations/#{conversation_id}/records/#{URI.encode(record_ref, &URI.char_unreserved?/1)}/#{lab_record_action_name(view_action(view))}"

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

  defp lab_record_resource(conversation_id, record_ref, action, action_context) do
    Enum.join(
      [
        conversation_id,
        record_ref,
        Atom.to_string(action),
        lab_action_context_resource(action_context)
      ],
      ":"
    )
  end

  defp lab_action_context_resource(%{generation: generation, publication_ref: publication_ref}),
    do: "#{generation}:#{publication_ref}"

  defp lab_action_context_resource(%{publication_ref: publication_ref}),
    do: publication_ref

  defp lab_action_context_resource(choice_index) when is_integer(choice_index),
    do: Integer.to_string(choice_index)

  defp lab_action_context_resource(nil), do: "none"

  defp lab_choice_index(%{generation: generation}), do: generation
  defp lab_choice_index(%{}), do: nil
  defp lab_choice_index(choice_index), do: choice_index

  defp lab_publication_ref(%{publication_ref: publication_ref}), do: publication_ref
  defp lab_publication_ref(_action_context), do: nil

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

  # Every kind the failures page can list, because it links each row it lists and
  # a kind missing here answers 404 to its own link. Publications were listed and
  # unreachable in production for exactly that reason.
  defp failure_kinds,
    do: ~w(admission delivery emisar publication retention slack_incident slack_interaction work)

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
         {:ok, publication_ref} <- path_ref(publication_ref) do
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
         {:ok, publication_ref} <- path_ref(publication_ref) do
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

  defp lab_action_context(card, action)
       when action in [
              :retry_task_publication,
              :update_task_publication,
              :discard_task_publication
            ],
       do: %{
         generation: Map.get(card, :recovery_generation),
         publication_ref: Map.get(card, :publication_ref)
       }

  defp lab_action_context(card, action)
       when action in [:approve_task_publication, :check_task_publication],
       do: %{publication_ref: Map.get(card, :publication_ref)}

  defp lab_action_context(_card, _action), do: nil

  defp lab_message_edit_form(conn) do
    with [content_type] <- get_req_header(conn, "content-type"),
         true <-
           String.starts_with?(String.downcase(content_type), "application/x-www-form-urlencoded"),
         {:ok, body, conn} <- read_lab_form(conn),
         %{"_token" => token, "message" => message} = form <- Query.decode(body),
         true <- Enum.sort(Map.keys(form)) == ["_token", "message"],
         true <- is_binary(token) and is_binary(message) do
      {:ok, token, message, conn}
    else
      _invalid -> {:error, :form}
    end
  end

  defp lab_reaction_form(conn) do
    with [content_type] <- get_req_header(conn, "content-type"),
         true <-
           String.starts_with?(String.downcase(content_type), "application/x-www-form-urlencoded"),
         {:ok, body, conn} <- read_form(conn),
         %{"_token" => token, "action" => action, "emoji" => emoji_name} = form <-
           Query.decode(body),
         true <- Enum.sort(Map.keys(form)) == ["_token", "action", "emoji"],
         {:ok, action} <- lab_reaction_action(action),
         true <- is_binary(token) and is_binary(emoji_name) do
      {:ok, token, action, emoji_name, conn}
    else
      _invalid -> {:error, :form}
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

  defp lab_message_resource(conversation_id, item_id, action)
       when action in [:edit, :delete],
       do: "#{conversation_id}:#{item_id}:#{action}"

  defp lab_reaction_resource(conversation_id, message_ref),
    do: "#{conversation_id}:#{message_ref}"

  defp lab_reaction_action("add"), do: {:ok, :add}
  defp lab_reaction_action("remove"), do: {:ok, :remove}
  defp lab_reaction_action(_action), do: {:error, :form}

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

  defp path_ref(encoded) when is_binary(encoded) and byte_size(encoded) <= 3_072 do
    decoded = URI.decode(encoded)

    if String.valid?(decoded) and decoded != "" and byte_size(decoded) <= 1_024,
      do: {:ok, decoded},
      else: {:error, :path_ref}
  end

  defp path_ref(_encoded), do: {:error, :path_ref}

  defp lab_id(encoded) do
    with {:ok, decoded} <- path_ref(encoded),
         {:ok, normalized} <- Ecto.UUID.cast(decoded) do
      {:ok, normalized}
    else
      _invalid -> {:error, :path_ref}
    end
  end

  # A page is a title, an optional one-line description and a body. The shell
  # renders the first two as the page's only heading; the body owns the rest.
  defp html(conn, status, title, body), do: html(conn, status, title, nil, body)

  defp html(%{private: %{control_plane_snapshot: true}}, status, title, description, body),
    do: %{status: status, title: title, description: description, body: IO.iodata_to_binary(body)}

  defp html(conn, status, title, description, body) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, HTML.page(title, description, body))
    |> halt()
  end

  defp text(%{private: %{control_plane_snapshot: true}}, status, body),
    do: %{
      status: status,
      title: "Unavailable",
      description: nil,
      body: Plug.HTML.html_escape(body)
    }

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

  defp security_headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header(
      "content-security-policy",
      "default-src 'none'; style-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
    )
    |> put_resp_header("cross-origin-resource-policy", "same-origin")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-content-type-options", "nosniff")
  end

  defp loopback?({127, _b, _c, _d}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_ip), do: false
end
