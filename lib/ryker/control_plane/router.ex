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
  @behaviour Plug
  import Plug.Conn
  alias Plug.Conn.Query
  alias Ryker.Artifacts
  alias Ryker.ControlPlane.{ActionRefusal, BehaviorLibrary, BehaviorPage, BrowserGuard, CSRF}
  alias Ryker.ControlPlane.{CasesPage, ConversationMemory, MemoryFormat}
  alias Ryker.ControlPlane.{FactsPage, FailureExplanation, FailureProjection, FindingsPage, HTML}
  alias Ryker.ControlPlane.{ImprovementPage, IncidentRoomsPage, LabControls, LearningActivity}
  alias Ryker.ControlPlane.{PathRef, Paths, PeoplePage, RelearnForm, RelearnPanel, Viewer}
  alias Ryker.Crypto
  alias Ryker.HTTPConnection
  alias Ryker.Maps
  alias Ryker.Observability
  alias Ryker.Operator
  alias Ryker.Slack
  alias Ryker.Wording
  require Logger

  @maximum_form_bytes 4_096
  @maximum_memory_form_bytes 16 * 1_024
  @maximum_lab_form_bytes 65_536
  # Every file of a message together (`Ryker.Artifacts.maximum_bytes/0`) and
  # the form beside them, whose allowance also covers the multipart framing.
  @maximum_lab_multipart_bytes Ryker.Artifacts.maximum_bytes() + @maximum_lab_form_bytes
  @readable_files "It reads text files, PDFs and PNG, JPEG, WebP or GIF images, and transcribes voice messages and videos."
  # Every failure kind with a confirmed recovery; publications have none.
  @recoverable_failures ~w(admission delivery emisar retention slack_incident slack_interaction slack_task_card slack_thread_status work)
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

  @doc """
  The question a confirmed action asks before it runs, for the live page to
  show in `Kit.confirm_modal/1` over the list it was asked from: the same
  title and sentence as the action's confirmation page, its tone, and the
  address and token its button posts, with the `back` the action named.
  `path` is the action's own address, as `Components.action_button/1` names it.
  """
  @spec question(String.t(), map()) ::
          {:ok,
           %{
             title: String.t(),
             text: String.t(),
             tone: atom(),
             action: String.t(),
             token: String.t()
           }}
          | {:error, :not_found}
  def question(path, options) when is_binary(path) do
    uri = URI.parse(path)

    with ["actions", kind, encoded, action] <- String.split(uri.path || "", "/", trim: true),
         {:ok, resource_ref} <- PathRef.reference(kind, encoded, options.projection.request_key),
         {:ok, title, explanation, canonical_action, tone} <-
           confirmation(kind, resource_ref, action, options) do
      {:ok,
       %{
         title: title,
         text: explanation,
         tone: tone,
         action:
           action_target(kind, encoded, resource_ref, action) <>
             back_query(back_param(uri.query)),
         token: CSRF.token(options.csrf_secret, canonical_action, resource_ref)
       }}
    else
      _unknown -> {:error, :not_found}
    end
  end

  def question(_path, _options), do: {:error, :not_found}

  # The endpoint has already run the guard; running it here as well means a
  # direct call to the router is refused and headed exactly the same way.
  @impl Plug
  def call(conn, options) do
    case BrowserGuard.call(conn,
           access: Map.get(options, :access, :loopback),
           public_host: Map.get(options, :public_host),
           cloudflare_access: Map.get(options, :cloudflare_access)
         ) do
      %Plug.Conn{halted: true} = refused -> refused
      conn -> conn |> HTTPConnection.close_after_refusal() |> as_viewer(options)
    end
  end

  # What a request does is recorded as the person Tailscale Serve or Cloudflare Access named on
  # it, and the request hands that person to every action it takes (`conn.assigns.viewer`): the
  # next request on the same connection may be someone else's. Chat's composer sends here, so a
  # message sent through Serve was recorded as the local console's until 2026-10-04.
  defp as_viewer(conn, options),
    do: conn |> assign(:viewer, Viewer.from_conn(conn, options)) |> route(options)

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

  # The routing and work examples kept for training, each as a JSON Lines
  # file, from the Data retention page. Each line is sent as it is read, so
  # the download never holds the whole set; a reader who stops reading ends
  # the export. The headers go out with the first line, once the first batch
  # is read, so an export that cannot start answers 503 rather than an empty
  # file.
  @training_files %{
    "routing-examples.jsonl" => {:routing_examples, "Routing examples", "ryker-routing-examples"},
    "work-examples.jsonl" => {:work_examples, "Work examples", "ryker-work-examples"}
  }

  defp route(
         %Plug.Conn{method: "GET", path_info: ["settings", "retention", file]} = conn,
         options
       )
       when is_map_key(@training_files, file) do
    {kind, label, name} = Map.fetch!(@training_files, file)

    case export_examples(conn, options, kind, name) do
      {:ok, %Plug.Conn{state: :chunked} = conn} ->
        halt(conn)

      :not_kept ->
        text(conn, 404, "#{label} are not kept\n")

      # Nothing is kept: the file is empty.
      {:ok, conn} ->
        conn |> examples_file(name) |> send_resp(200, "") |> halt()

      {:error, error, _stack, :unsent} ->
        Logger.warning("#{label} download unavailable category=#{inspect(error.__struct__)}")

        text(conn, 503, "#{label} unavailable\n")

      # Raised, the file is left unfinished: the server closes the connection
      # before it ends, so the browser reports a failed download instead of
      # keeping the lines sent so far as the whole file. What is raised says
      # only that: raising the original error again handed the server's log
      # whatever data it carried (2026-10-04 review).
      {:error, error, _stack, :sent} ->
        Logger.warning("#{label} download stopped part-way category=#{inspect(error.__struct__)}")

        raise "#{label} download stopped part-way"
    end
  end

  # The requests accepted as eval cases on Feedback › What to fix, as
  # one zip of world scenario directories (`Ryker.Improvement.Export`).
  defp route(
         %Plug.Conn{
           method: "GET",
           path_info: ["feedback", "fix", "eval-cases.zip"]
         } = conn,
         options
       ) do
    case options.projection.eval_cases.() do
      {:ok, archive} ->
        conn
        |> put_resp_content_type("application/zip")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="ryker-eval-cases-#{Date.utc_today()}.zip")
        )
        |> send_resp(200, archive)
        |> halt()

      {:error, _reason} ->
        text(conn, 503, "Eval cases unavailable\n")
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
         {:ok, attachments} <- readable_attachments(attachments),
         {:ok, _receipt} <-
           options.actions.send_lab_message.(
             conversation_id,
             message,
             attachments,
             conn.assigns.viewer
           ) do
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

      {:error, {:unreadable_attachment, %{name: name, data: ""}}} ->
        text(conn, 422, "#{name} is empty.")

      {:error, {:unreadable_attachment, %{name: name}}} ->
        text(conn, 422, "Ryker can't read #{name}. #{@readable_files}")

      {:error, {:invalid_conversation_lab, :attachments}} ->
        text(conn, 422, "Ryker can't read one of the attached files. #{@readable_files}")

      {:error, {:recording_refused, name, reason}} ->
        text(conn, 422, "#{name} is #{reason}.")

      {:error, {:invalid_conversation_lab, :message}} ->
        text(conn, 422, "Write a message of at most 20,000 bytes, or attach a file.")

      {:error, {:invalid_conversation_lab, _field}} ->
        text(conn, 422, "Invalid message.")

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
        HTML.lab_task_record(snapshot),
        {"Conversation", Paths.conversation(conversation_id)}
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
           act_on_lab_record(conn, options, conversation_id, record_ref, action, action_context) do
      conn
      |> put_resp_header("location", Paths.conversation(conversation_id))
      |> send_resp(303, "")
      |> halt()
    else
      false ->
        text(conn, 403, "Invalid confirmation token")

      {:error, :path_ref} ->
        text(conn, 404, "Conversation or record not found")

      {:error, :lab_record_action} ->
        text(conn, 404, "Record action not found")

      {:error, :form} ->
        text(conn, 400, "Invalid form")

      {:error, {:lab_record_failed, conversation_id, action, reason}} ->
        {title, explanation} = LabControls.record_failure(action, reason)
        back = Paths.conversation(conversation_id)
        html(conn, 409, title, HTML.lab_record_failure(explanation, back))
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
           Operator.Learning.retry(
             id,
             form.version,
             Viewer.actor_ref(conn, options),
             "control-plane:learning-retry:#{id}:#{form.version}"
           ) do
      conn
      |> put_resp_header("location", LearningActivity.path(id))
      |> send_resp(303, "")
      |> halt()
    else
      false -> retry_refused(conn, 403, LearningActivity.error(:learning_retry_conflict), id)
      :error -> html(conn, 404, "Not found", HTML.not_found("Learning batch"))
      {:error, :form} -> retry_refused(conn, 400, "That form could not be read.", id)
      {:error, reason} -> retry_refused(conn, 409, LearningActivity.error(reason), id)
    end
  end

  # Relearning and choosing new sources for a request already made arrive
  # here only from a page without JavaScript: the console's LiveView submits
  # the same form itself and shows a refusal inside the panel
  # (`Ryker.ControlPlane.RelearnForm`).
  defp route(
         %Plug.Conn{method: "POST", path_info: ["actions", "knowledge", id, "relearn"]} = conn,
         options
       ),
       do: relearn_route(conn, "relearn", id, ConversationMemory.topic_path(id), options)

  defp route(
         %Plug.Conn{method: "POST", path_info: ["actions", "learning", id, "reselect"]} = conn,
         options
       ),
       do: relearn_route(conn, "reselect", id, LearningActivity.path(id), options)

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
        "Edit this fact",
        FactsPage.edit_form(review, Paths.action("memory-review", resource_ref, "edit"), token)
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
         {:ok, review} <- editable_memory_review(resource_ref, options),
         {:ok, token, subject, value, conn} <- memory_review_form(conn),
         true <-
           CSRF.valid?(options.csrf_secret, "memory-review:edit", resource_ref, token) do
      case options.actions.resolve_memory_review.(
             resource_ref,
             :edit,
             %{"subject" => subject, "value" => value},
             conn.assigns.viewer
           ) do
        {:ok, _resource} ->
          conn
          |> put_resp_header("location", action_return_path("memory-review", resource_ref))
          |> send_resp(303, "")
          |> halt()

        # The words stay as they were typed, with why they were refused beside
        # them; a refusal replaced the form with a page that kept nothing
        # (Emisar's inline form errors, 2026-10-08).
        {:error, reason} ->
          html(
            conn,
            409,
            "Edit this fact",
            FactsPage.edit_form(
              review,
              Paths.action("memory-review", resource_ref, "edit"),
              token,
              %{subject: subject, value: value, error: ActionRefusal.explain(reason)}
            )
          )
      end
    else
      false ->
        text(conn, 403, "Invalid confirmation token")

      {:error, :form} ->
        text(conn, 400, "Invalid form")

      {:error, reason} ->
        back = action_return_path("memory-review", resource_ref)
        html(conn, 409, "Not done", HTML.action_refused(ActionRefusal.explain(reason), back))
    end
  end

  defp route(
         %Plug.Conn{method: "GET", path_info: ["actions", kind, segment, action]} = conn,
         options
       ) do
    with {:ok, resource_ref} <- PathRef.reference(kind, segment, options.projection.request_key),
         {:ok, title, explanation, canonical_action, _tone} <-
           confirmation(kind, resource_ref, action, options) do
      back = back(conn)
      path = action_target(kind, segment, resource_ref, action) <> back_query(back)
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
          back || action_return_path(kind, resource_ref, action, options)
        )
      )
    else
      _not_found -> html(conn, 404, "Not found", HTML.not_found("Action"))
    end
  end

  defp route(
         %Plug.Conn{method: "POST", path_info: ["actions", kind, segment, action]} = conn,
         options
       ) do
    with {:ok, resource_ref} <- PathRef.reference(kind, segment, options.projection.request_key),
         {:ok, _title, _explanation, canonical_action, _tone} <-
           confirmation(kind, resource_ref, action, options),
         {:ok, token, conn} <- form_token(conn),
         :ok <- confirmed(options.csrf_secret, canonical_action, resource_ref, token),
         return_path <- back(conn) || action_return_path(kind, resource_ref, action, options),
         {:ok, _resource} <-
           perform(kind, resource_ref, action, canonical_action, options.actions, conn) do
      conn
      |> put_resp_header("location", return_path)
      |> send_resp(303, "")
      |> halt()
    else
      false ->
        text(conn, 403, "Invalid confirmation token")

      {:error, :form} ->
        text(conn, 400, "Invalid form")

      :not_found ->
        html(conn, 404, "Not found", HTML.not_found("Action"))

      {:error, reason} ->
        back =
          case PathRef.reference(kind, segment, options.projection.request_key) do
            {:ok, ref} -> back(conn) || action_return_path(kind, ref, action, options)
            _invalid -> "/"
          end

        html(conn, 409, "Not done", HTML.action_refused(ActionRefusal.explain(reason), back))
    end
  end

  defp route(%Plug.Conn{method: "GET"} = conn, _options),
    do: html(conn, 404, "Not found", HTML.not_found("Page"))

  defp route(conn, _options), do: text(conn, 405, "Method not allowed")

  # A confirmation names the revision it was asked about: a schedule's, a
  # learning batch's budget, a stopped request's recovery. Once that changed,
  # the old token stopped matching and the person got a bare 403, never the
  # page saying what happened (2026-10-04 review).
  @revisioned_actions ~w(schedule:run-now: learning:drop: work:retry:)

  defp confirmed(secret, canonical_action, resource_ref, token) do
    case CSRF.signed_action(secret, resource_ref, token) do
      {:ok, ^canonical_action} ->
        :ok

      {:ok, earlier} ->
        if Enum.any?(
             @revisioned_actions,
             &(String.starts_with?(earlier, &1) and
                 String.starts_with?(canonical_action, &1))
           ),
           do: {:error, :confirmation_stale},
           else: false

      :error ->
        false
    end
  end

  # A confirmation posts back to the address it was opened at: a request's
  # kinds are addressed by the request's id, not by the key it resolved to.
  defp action_target(kind, segment, resource_ref, action) do
    with {:ok, id} <- PathRef.decode(segment),
         :request <- Paths.reference(kind, id) do
      Paths.action(kind, id, action)
    else
      _record -> Paths.action(kind, resource_ref, action)
    end
  end

  # Set once an examples file has begun. An export that raises drops the conn
  # that would say so, so its failure reads this instead.
  @examples_sent {__MODULE__, :examples_sent}

  # The export, or why it failed and whether the file had begun by then. Only
  # a category is ever logged: an export's error can carry what it read.
  defp export_examples(conn, options, kind, name) do
    Process.delete(@examples_sent)

    case Map.fetch!(options.projection, kind).(conn, &send_example(&1, &2, name)) do
      {:ok, conn} -> {:ok, conn}
      {:error, :examples_not_kept} -> :not_kept
      {:error, _reason} -> raise "the #{kind} export failed"
    end
  rescue
    error ->
      {:error, error, __STACKTRACE__,
       if(Process.delete(@examples_sent), do: :sent, else: :unsent)}
  end

  # One line of the file; the first also sends the file's headers.
  defp send_example(line, %Plug.Conn{state: :chunked} = conn, _name),
    do: send_example_line(conn, line)

  defp send_example(line, conn, name) do
    # Whether this download already sent its headers, read by its own rescue a few lines up.
    # credo:disable-for-next-line Ryker.Checks.NoProcessDictionary
    Process.put(@examples_sent, true)
    conn |> examples_file(name) |> send_chunked(200) |> send_example_line(line)
  end

  defp send_example_line(conn, line) do
    case chunk(conn, line) do
      {:ok, conn} -> {:cont, conn}
      {:error, _closed} -> {:halt, conn}
    end
  end

  defp examples_file(conn, name) do
    conn
    |> put_resp_content_type("application/jsonl")
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="#{name}-#{Date.utc_today()}.jsonl")
    )
  end

  defp lab_record_view("diff"), do: {:ok, :diff}
  defp lab_record_view("timeline"), do: {:ok, :timeline}
  defp lab_record_view("evidence"), do: {:ok, :evidence}
  defp lab_record_view("handoff"), do: {:ok, :handoff}
  defp lab_record_view("postmortem"), do: {:ok, :postmortem}
  defp lab_record_view(_view), do: {:error, :lab_record_view}

  defp lab_record_view_params(:diff, params) when is_map(params) do
    if Maps.only_keys?(params, ["offset", "snapshot"]) do
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
    if Crypto.sha256_hex?(value), do: {:ok, value}, else: {:error, :digest}
  end

  defp diff_digest(_value, _offset), do: {:error, :digest}

  defp lab_record_view_path(conversation_id, record_ref, view, page) do
    base = LabControls.record_path(conversation_id, record_ref, view_action(view))

    case page do
      %{offset: offset, snapshot_digest: digest} ->
        Paths.query(base, %{"offset" => offset, "snapshot" => digest})

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

  # Each question: its title and sentence, the intent its token is bound to,
  # and its tone, which each one says beside its words. A step that removes,
  # deletes, drops or forgets what it names is asked in the danger tone; any
  # other in the primary one.
  defp confirmation("memory", resource_ref, "forget", options) do
    case options.projection.memory_fact.(resource_ref) do
      nil ->
        {:error, :not_found}

      memory ->
        {:ok, "Forget #{memory.subject}?",
         "Ryker stops using this fact and erases what it saved. You can ask it to remember again later." <>
           forgetting_consequences(options.projection.forgetting.({:memory, resource_ref})),
         "memory:forget", :danger}
    end
  end

  # Forgetting a learned topic forgets the messages it came from, and what
  # else learning took from them; the question says all of it first.
  defp confirmation("knowledge", resource_ref, "forget", options) do
    case options.projection.forgetting.({:knowledge, resource_ref}) do
      {:ok, preview} ->
        {:ok, "Forget #{preview.title}?",
         "Ryker stops using this topic, erases what it learned, and never learns from the messages it came from again. The topic stays listed as forgotten." <>
           forgetting_consequences({:ok, preview}), "knowledge:forget", :danger}

      :error ->
        {:error, :not_found}
    end
  end

  # Forgetting or settling a finding stops Ryker using it; the question says
  # so, and that the investigation keeps it.
  defp confirmation("finding", resource_ref, "forget", options) do
    case options.projection.finding.(resource_ref) do
      {:ok, %{status: :open} = finding} ->
        {:ok, "Forget \"#{finding.what}\"?",
         "Ryker stops using this finding: later requests no longer read it, and the investigation that reached it no longer counts on it. It stays in the investigation's history and is listed here as forgotten. You can't undo this.",
         "finding:forget", :danger}

      _unavailable ->
        {:error, :not_found}
    end
  end

  # Forgetting a case erases what Ryker kept of finished work; the question
  # says that a later request no longer reads it, and what stays.
  defp confirmation("case", resource_ref, "forget", options) do
    case options.projection.case.(Paths.id("case", resource_ref)) do
      {:ok, %{forgotten?: false} = item} ->
        {:ok, "Forget \"#{MemoryFormat.excerpt(item.problem, Slack.Names.workspace(), 90)}\"?",
         "Ryker erases this case's words, and later requests about the same problem no longer read it. That a case was kept stays, marked forgotten. You can't undo this.",
         "case:forget", :danger}

      _unavailable ->
        {:error, :not_found}
    end
  end

  # Forgetting a person forgets everything Ryker learned from what they said
  # about themselves; the question says what comes back and what does not.
  defp confirmation("person", resource_ref, "forget", options) do
    case options.projection.person.(resource_ref) do
      {:ok, person} ->
        {:ok, "Forget what Ryker learned about #{object(person.name)}?",
         "Ryker stops using all of it and erases the words. Nothing they said before brings it back; what they say about themselves later is learned again. You can't undo this.",
         "person:forget", :danger}

      :error ->
        {:error, :not_found}
    end
  end

  # One thing a person said about themselves, forgotten on its own (Andrew,
  # 2026-09-30); the question quotes it and says what brings it back.
  defp confirmation("person-fact", resource_ref, "forget", options) do
    case options.projection.person_fact.(resource_ref) do
      {:ok, fact} ->
        {:ok, "Forget \"#{fact.text}\"?",
         "Ryker stops using it and erases the words. Nothing said before brings it back; if they say it again later, it is learned again. You can't undo this.",
         "person-fact:forget", :danger}

      :error ->
        {:error, :not_found}
    end
  end

  defp confirmation("finding", resource_ref, "mark-explained", options) do
    case options.projection.finding.(resource_ref) do
      {:ok, %{status: :open, classification: "unexplained"} = finding} ->
        {:ok, "Mark \"#{finding.what}\" as explained?",
         "It stops counting as not explained yet, and Ryker stops bringing it up as an open question in later requests. It stays in the investigation's history. You can't undo this.",
         "finding:mark-explained", :primary}

      _unavailable ->
        {:error, :not_found}
    end
  end

  # Dropping a stopped learning batch is bound to the budget version the
  # question was asked at: a batch granted another start since is not the
  # batch the person chose to drop.
  defp confirmation("learning", resource_ref, "drop", options) do
    case options.projection.learning.(%{"batch" => resource_ref}) do
      %{selected: %{id: ^resource_ref, drop_available: true} = batch} ->
        messages = Wording.word(batch.input_count, "this message", "these messages")

        {:ok, "Drop this learning batch?",
         "Ryker stops trying to learn from #{messages} in #{batch.conversation}. Nothing it already learned changes, and replies are unaffected. Its attempts and the model starts they used stay recorded. You can't undo this.",
         "learning:drop:#{batch.budget_version}", :danger}

      _unavailable ->
        {:error, :not_found}
    end
  end

  defp confirmation("memory-review", resource_ref, action, options)
       when action in ["keep", "merge", "forget"] do
    case options.projection.memory_review.(resource_ref) do
      %{"kind" => kind, "status" => "pending"} = review
      when action != "merge" or kind == "duplicate" ->
        subjects = Enum.map_join(review["entries"], ", ", & &1["subject"])
        {title, explanation, tone} = review_confirmation(action, kind, subjects)
        {:ok, title, explanation, "memory-review:#{action}", tone}

      _missing_or_incompatible ->
        {:error, :not_found}
    end
  end

  defp confirmation("behavior", resource_ref, action, options)
       when action in ["active", "disabled", "deleted"] do
    case options.projection.behavior.(resource_ref) do
      {:ok, %{status: status} = behavior} when status in ["active", "disabled"] ->
        {verb, explanation, tone} =
          case action do
            "active" ->
              {"Resume",
               "This saved instruction will apply again within its existing scope until it expires.",
               :primary}

            "disabled" ->
              {"Pause",
               "Future requests will not use this instruction. Work already started is unchanged. You can resume it later.",
               :primary}

            "deleted" ->
              {"Delete",
               "This instruction will no longer apply. Its history is retained. To use it again, ask Ryker to propose a new one.",
               :danger}
          end

        subject = BehaviorPage.subject(behavior)
        {:ok, "#{verb} #{subject}?", explanation, "behavior:#{action}", tone}

      _unavailable ->
        {:error, :not_found}
    end
  end

  defp confirmation("schedule", resource_ref, "run-now", options) do
    case options.projection.schedule.(resource_ref) do
      {:ok, %{schedule: %{status: status} = schedule}}
      when status in [:active, :paused, :completed] ->
        {:ok, "Run #{schedule.title} now?",
         "Ryker starts one extra run now, in the same place as its scheduled runs. The regular schedule does not change.",
         "schedule:run-now:#{schedule.revision}", :primary}

      _unavailable ->
        {:error, :not_found}
    end
  end

  defp confirmation("schedule", resource_ref, action, options)
       when action in ["active", "paused", "deleted"] do
    case options.projection.schedule.(resource_ref) do
      {:ok, %{schedule: %{status: status} = schedule}} when status in [:active, :paused] ->
        {verb, explanation, tone} =
          case action do
            "paused" ->
              {"Pause",
               "Ryker stops starting new runs until you resume it. A run that has already started keeps going.",
               :primary}

            "active" ->
              {"Resume", "Ryker runs it again on its regular schedule.", :primary}

            "deleted" ->
              {"Delete",
               "Ryker stops running it for good. Its past runs stay listed. To run it again, ask Ryker for a new schedule.",
               :danger}
          end

        {:ok, "#{verb} #{schedule.title}?", explanation, "schedule:#{action}", tone}

      _unavailable ->
        {:error, :not_found}
    end
  end

  # A failure's recovery is confirmed from the same row, in the same words, as
  # the Failures page and the failure's own page show it: what the step does,
  # then whether it should work now. The intent a token is minted for stays
  # the kind's own, and a work retry stays bound to the exact recovery it was
  # shown for.
  defp confirmation(kind, resource_ref, action, options)
       when kind in @recoverable_failures and action in ["rearm", "retry"] do
    with {:ok, %{kind: ^kind, status: :blocked} = row} <-
           options.projection.failure.(kind, resource_ref),
         {:ok, title, explanation} <- FailureExplanation.confirmation(row, action),
         {:ok, intent} <- failure_intent(row) do
      {:ok, title, explanation, intent, :primary}
    else
      _unavailable -> {:error, :not_found}
    end
  end

  # Leaving a failure as it is: Failures stops listing it until it changes
  # again. One already left has nothing to leave.
  defp confirmation(kind, resource_ref, "leave", options) do
    with true <- kind in FailureProjection.kinds(),
         {:ok, row} <- options.projection.failure.(kind, resource_ref),
         true <- is_nil(row[:left_at]),
         {:ok, title, explanation} <- FailureExplanation.leave_confirmation(row) do
      {:ok, title, explanation, "failure:leave", :primary}
    else
      _unavailable -> {:error, :not_found}
    end
  end

  # Closing a room stops Ryker's work in it and says so in Slack. The channel
  # and the room's history stay, so the question is not in the danger tone.
  defp confirmation("slack_incident", resource_ref, "close", options) do
    case options.projection.incident.(resource_ref) do
      {:ok, %{room: %{status: status} = room}} when status in [:requested, :ready, :blocked] ->
        if room[:closing],
          do: {:error, :not_found},
          else:
            {:ok, "Close #{room.title}?", IncidentRoomsPage.close_explanation(room),
             "slack_incident:close", :primary}

      _unavailable ->
        {:error, :not_found}
    end
  end

  defp confirmation("episode", resource_ref, "resolve", options) do
    case options.projection.episode.(resource_ref, %{}) do
      {:ok, %{trace: %{actions: actions}}} ->
        if Enum.any?(actions, &String.ends_with?(&1.href, "/resolve")) do
          {:ok, "Close this request as no longer needed?",
           "Ryker ends this request and stops waiting for an answer, an event or a retry. Its history stays here, and nothing is posted or changed anywhere else. You can't reopen it; to continue, ask again in the conversation.",
           "episode:resolve", :primary}
        else
          {:error, :not_found}
        end

      _unavailable ->
        {:error, :not_found}
    end
  end

  defp confirmation("episode", resource_ref, action, options)
       when action in ["rate-good", "rate-needs-work"] do
    case options.projection.episode.(resource_ref, %{}) do
      {:ok, %{trace: %{rating: %{awaiting: true}}}} ->
        {title, explanation} = rating_confirmation(action)
        {:ok, title, explanation, "episode:#{action}", :primary}

      _unavailable ->
        {:error, :not_found}
    end
  end

  defp confirmation("retention", resource_ref, "discard", options) do
    case options.projection.workspace.(resource_ref) do
      {:ok, %{action: :discard_unmerged, status: :retained}} ->
        {:ok, "Delete this working copy and its unmerged commits?",
         "Ryker asks the worker to delete this working copy, including commits that were never merged anywhere. The worker checks the copy again first and keeps it if it has uncommitted changes. This can't be undone.",
         "retention:discard_unmerged", :danger}

      _unavailable ->
        {:error, :not_found}
    end
  end

  # Accepting or dismissing a request to improve changes only its decision;
  # each can be changed back later, so neither is in the danger tone.
  defp confirmation("improvement", resource_ref, action, options)
       when action in ["accept", "dismiss"] do
    with {:ok, item} <- options.projection.improvement_candidate.(resource_ref),
         true <- improvement_decidable?(action, item) do
      {title, explanation} = improvement_confirmation(action, item)
      {:ok, title, explanation, "improvement:#{action}", :primary}
    else
      _unavailable -> {:error, :not_found}
    end
  end

  defp confirmation(_kind, _resource_ref, _action, _snapshot), do: {:error, :not_found}

  defp rating_confirmation("rate-good") do
    {"Did this request go well?",
     "Ryker counts it as positive feedback on the Feedback page and stops asking about this ending. You can't change the rating afterwards."}
  end

  defp rating_confirmation("rate-needs-work") do
    {"Does this request need work?",
     "Ryker counts it as negative feedback and adds the request to Self-improvement: once it is quiet, Ryker works out what went wrong and proposes a test case you can accept or dismiss. Nothing is posted anywhere, and you can't change the rating afterwards."}
  end

  # Accept only what can become an eval case and is not one yet; dismiss
  # anything not dismissed already.
  defp improvement_decidable?("accept", item),
    do: item.status != :accepted and ImprovementPage.acceptable?(item)

  defp improvement_decidable?("dismiss", item), do: item.status != :dismissed

  defp improvement_confirmation("accept", item) do
    {"Accept this as an eval case?",
     "Ryker keeps the person's messages, the answer they were unhappy with and what it should have done, so you can download them as an eval case for testdata. It moves to Accepted." <>
       if(item.analysis == :done,
         do: "",
         else:
           " Ryker has not analyzed it yet; what it should have done joins the case once it has."
       )}
  end

  defp improvement_confirmation("dismiss", %{status: :accepted}) do
    {"Dismiss this eval case?",
     "It is no longer downloaded as an eval case, and the messages it kept are let go. It moves to Dismissed and stays on record."}
  end

  defp improvement_confirmation("dismiss", item) do
    {"Dismiss this?",
     "It moves to Dismissed and stays on record, and you can accept it later." <>
       if(item.analysis in [:pending, :running],
         do: " Ryker does not analyze it while it is dismissed.",
         else: ""
       )}
  end

  defp failure_intent(%{kind: "work", work_recovery: %{fingerprint: fingerprint}})
       when is_binary(fingerprint),
       do: {:ok, "work:retry:" <> fingerprint}

  defp failure_intent(%{kind: "work"}), do: {:error, :not_found}
  defp failure_intent(%{kind: kind, action: :rearm}), do: {:ok, kind <> ":rearm"}
  defp failure_intent(_row), do: {:error, :not_found}

  # Who confirmed the action is the request's person (`conn.assigns.viewer`), handed to every
  # action that records who took it.
  defp perform("work", resource_ref, "retry", "work:retry:" <> fingerprint, actions, conn),
    do: actions.retry_work.(resource_ref, fingerprint, conn.assigns.viewer)

  defp perform("learning", resource_ref, "drop", "learning:drop:" <> version, actions, conn),
    do: actions.drop_learning.(resource_ref, String.to_integer(version), conn.assigns.viewer)

  defp perform(kind, resource_ref, action, _canonical_action, actions, conn),
    do: perform(kind, resource_ref, action, actions, conn.assigns.viewer)

  defp perform("memory", resource_ref, "forget", actions, _viewer),
    do: actions.forget_memory.(resource_ref)

  defp perform("knowledge", resource_ref, "forget", actions, _viewer),
    do: actions.forget_knowledge.(resource_ref)

  defp perform("finding", resource_ref, "forget", actions, _viewer),
    do: actions.forget_finding.(resource_ref)

  defp perform("case", resource_ref, "forget", actions, _viewer),
    do: actions.forget_case.(resource_ref)

  defp perform("person", resource_ref, "forget", actions, _viewer),
    do: actions.forget_person.(resource_ref)

  defp perform("person-fact", resource_ref, "forget", actions, _viewer),
    do: actions.forget_person_fact.(resource_ref)

  defp perform("finding", resource_ref, "mark-explained", actions, _viewer),
    do: actions.mark_finding_explained.(resource_ref)

  defp perform("memory-review", resource_ref, action, actions, viewer)
       when action in ["keep", "merge", "forget"],
       do: actions.resolve_memory_review.(resource_ref, memory_review_action(action), nil, viewer)

  defp perform("admission", resource_ref, "rearm", actions, viewer),
    do: actions.rearm_admission.(resource_ref, viewer)

  defp perform("delivery", resource_ref, "rearm", actions, viewer),
    do: actions.rearm_delivery.(resource_ref, viewer)

  defp perform("emisar", resource_ref, "rearm", actions, viewer),
    do: actions.rearm_emisar.(resource_ref, viewer)

  defp perform("retention", resource_ref, "rearm", actions, viewer),
    do: actions.rearm_retention.(resource_ref, viewer)

  defp perform("retention", resource_ref, "discard", actions, viewer),
    do: actions.discard_retention.(resource_ref, viewer)

  defp perform("slack_interaction", resource_ref, "rearm", actions, viewer),
    do: actions.rearm_slack_interaction.(resource_ref, viewer)

  defp perform("slack_incident", resource_ref, "rearm", actions, viewer),
    do: actions.rearm_slack_incident.(resource_ref, viewer)

  defp perform("slack_incident", resource_ref, "close", actions, viewer),
    do: actions.close_incident_room.(resource_ref, viewer)

  defp perform(kind, resource_ref, "leave", actions, viewer),
    do: actions.leave_failure.(kind, resource_ref, viewer)

  defp perform("slack_task_card", resource_ref, "rearm", actions, viewer),
    do: actions.rearm_slack_task_card.(resource_ref, viewer)

  defp perform("slack_thread_status", resource_ref, "rearm", actions, viewer),
    do: actions.rearm_slack_thread_status.(resource_ref, viewer)

  defp perform("improvement", resource_ref, "accept", actions, viewer),
    do: actions.accept_improvement.(resource_ref, viewer)

  defp perform("improvement", resource_ref, "dismiss", actions, viewer),
    do: actions.dismiss_improvement.(resource_ref, viewer)

  defp perform("episode", resource_ref, "resolve", actions, viewer),
    do: actions.resolve_episode.(resource_ref, viewer)

  defp perform("episode", resource_ref, "rate-good", actions, viewer),
    do: actions.rate_episode.(resource_ref, :good, viewer)

  defp perform("episode", resource_ref, "rate-needs-work", actions, viewer),
    do: actions.rate_episode.(resource_ref, :needs_work, viewer)

  defp perform("behavior", resource_ref, action, actions, _viewer)
       when action in ["active", "disabled", "deleted"],
       do: actions.set_behavior_status.(resource_ref, String.to_existing_atom(action))

  defp perform("schedule", resource_ref, action, actions, _viewer)
       when action in ["active", "paused", "deleted"],
       do: actions.set_schedule_status.(resource_ref, String.to_existing_atom(action))

  defp perform("schedule", resource_ref, "run-now", actions, viewer),
    do: actions.run_schedule.(resource_ref, viewer)

  defp perform(_kind, _resource_ref, _action, _actions, _viewer), do: {:error, :invalid_action}

  # What a reviewed fact's action does, in the words its confirmation page shows.
  defp review_confirmation("keep", "duplicate", subjects) do
    {"Keep these facts separate?",
     "Ryker keeps #{subjects} as separate facts and stops asking about them.", :primary}
  end

  defp review_confirmation("keep", _kind, subjects) do
    {"Keep #{subjects}?",
     "Ryker keeps using this as it is and stops asking about it for now. Nothing is changed.",
     :primary}
  end

  defp review_confirmation("merge", _kind, subjects) do
    {"Merge these facts?",
     "Ryker keeps the most recently changed of #{subjects} and forgets the other copies. This can't be undone.",
     :danger}
  end

  defp review_confirmation("forget", _kind, subjects) do
    {"Forget #{subjects}?",
     "Ryker stops using this and erases what it saved. You can ask it to remember again later.",
     :danger}
  end

  defp memory_review_action("keep"), do: :keep
  defp memory_review_action("merge"), do: :merge
  defp memory_review_action("forget"), do: :forget

  defp action_return_path(kind, _resource_ref) when kind in @recoverable_failures,
    do: "/failures"

  # Facts list their reviews below them, so a review returns to the reviews,
  # where the next one waits, rather than to the top of the facts.
  defp action_return_path("memory", _resource_ref), do: "/memory"
  defp action_return_path("person", _resource_ref), do: "/memory/people"
  defp action_return_path("memory-review", _resource_ref), do: "/memory#review"
  defp action_return_path("knowledge", _resource_ref), do: "/memory/learned"
  defp action_return_path("finding", resource_ref), do: FindingsPage.path(resource_ref)

  defp action_return_path("case", resource_ref),
    do: CasesPage.path(Paths.id("case", resource_ref))

  defp action_return_path("improvement", _resource_ref), do: "/feedback/fix"
  defp action_return_path("learning", resource_ref), do: LearningActivity.path(resource_ref)

  # Only a refused action of a kind no page offers gets here; like one whose
  # reference does not decode, it leads home.
  defp action_return_path(_kind, _resource_ref), do: "/"

  # Back to the person, or to everyone once nothing about them is left.
  defp action_return_path("person-fact", resource_ref, options) do
    case options.projection.person_fact.(resource_ref) do
      {:ok, %{others: others, person_ref: person_ref}} when others > 0 ->
        PeoplePage.path(person_ref)

      _last_or_gone ->
        "/memory/people"
    end
  end

  defp action_return_path("behavior", resource_ref, options) do
    case options.projection.behavior.(resource_ref) do
      {:ok, %{kind: kind}} -> BehaviorLibrary.return_path(kind)
      _unavailable -> "/rules"
    end
  end

  # A cleanup returns to the page that lists its session: a working copy to
  # Working copies, a learning session to Learning. A session no page lists
  # but Failures (a chat or routing session holds no checkout) returns to
  # Failures; landing on Working copies hid whether its cleanup resumed.
  defp action_return_path("retention", resource_ref, options) do
    case options.projection.workspace.(resource_ref) do
      {:ok, %{execution_kind: :learning}} -> "/memory/learning"
      {:ok, %{repository: repository}} when is_binary(repository) -> "/working-copies"
      _unlisted -> "/failures"
    end
  end

  # A request's action returns to the request's page, addressed by its id.
  defp action_return_path("episode", resource_ref, options) do
    case options.projection.request_id.(resource_ref) do
      nil -> "/"
      id -> Paths.request(id)
    end
  end

  defp action_return_path(kind, resource_ref, _options),
    do: action_return_path(kind, resource_ref)

  # A schedule change returns to the schedule it changed, where its new state
  # and any run it started show next; a deleted schedule has nothing left to
  # do on its own page, so Delete returns to the list.
  defp action_return_path("schedule", _resource_ref, "deleted", _options), do: "/schedules"

  defp action_return_path("schedule", resource_ref, _action, _options),
    do: Paths.schedule(resource_ref)

  # A failure left as it is returns to the list it no longer appears on.
  defp action_return_path(_kind, _resource_ref, "leave", _options), do: "/failures"

  # Closing returns to the room, where it reads Closing until it is closed.
  defp action_return_path("slack_incident", resource_ref, "close", _options),
    do: Paths.incident_room(resource_ref)

  defp action_return_path(kind, resource_ref, _action, options),
    do: action_return_path(kind, resource_ref, options)

  # What forgetting takes with it beyond the thing itself, in two sentences at
  # most, naming the topics.
  defp forgetting_consequences({:ok, %{forgotten: forgotten, relearn: relearn}}) do
    [
      forgotten != [] &&
        " Learned only from the same messages, and forgotten with it: #{Enum.join(forgotten, ", ")}.",
      relearn != [] &&
        " Also learned from them, and not used until you relearn it from its other messages: #{Enum.join(relearn, ", ")}."
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join()
  end

  defp forgetting_consequences(_preview), do: ""

  # A confirmation opened from a request's timeline, its conversation or a
  # learning batch's page names that page as `back` and returns there, on
  # Cancel and after confirming. Only those pages of this control plane are
  # accepted, so the parameter can never send anyone elsewhere.
  @back ~r"\A(?:/(?:timeline|conversations)/(?!\.+\z)[A-Za-z0-9%._~-]+|/memory/learning\?batch=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\z"

  defp back(conn), do: allowed_back(fetch_query_params(conn).query_params)

  defp back_param(nil), do: nil

  defp back_param(query) do
    query |> URI.decode_query() |> allowed_back()
  rescue
    ArgumentError -> nil
  end

  defp allowed_back(%{"back" => path}) when is_binary(path),
    do: if(Regex.match?(@back, path), do: path)

  defp allowed_back(_params), do: nil

  defp back_query(nil), do: ""
  defp back_query(back), do: "?" <> Paths.encode_query(%{"back" => back})

  defp form_token(conn) do
    with [content_type] <- get_req_header(conn, "content-type"),
         true <-
           String.starts_with?(String.downcase(content_type), "application/x-www-form-urlencoded"),
         {:ok, body, conn} <- read_form(conn),
         %{"_token" => token} = form <- decode_form(body),
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
         %{"_token" => token, "budget_version" => version} = form <- decode_form(body),
         true <- Maps.exact_keys?(form, ["_token", "budget_version"]),
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

  defp relearn_route(conn, kind, id, back, options) do
    with {:ok, form, conn} <- learning_source_form(conn),
         {:ok, batch_id} <-
           RelearnForm.submit(
             kind,
             id,
             form,
             Viewer.actor_ref(conn, options),
             options.csrf_secret
           ) do
      learning_redirect(conn, batch_id)
    else
      {:error, reason} ->
        html(
          conn,
          relearn_status(reason),
          "Not done",
          HTML.action_refused(RelearnPanel.reason(reason), back)
        )
    end
  end

  defp relearn_status(:form), do: 400
  defp relearn_status(:token), do: 403
  defp relearn_status(_reason), do: 409

  # A retry has nothing typed to keep, so a refusal is the page that says why,
  # with the way back to the batch; it was a line of plain text before.
  defp retry_refused(conn, status, explanation, id) do
    html(conn, status, "Not done", HTML.action_refused(explanation, LearningActivity.path(id)))
  end

  defp learning_source_form(conn) do
    with [content_type] <- get_req_header(conn, "content-type"),
         true <-
           String.starts_with?(String.downcase(content_type), "application/x-www-form-urlencoded"),
         {:ok, body, conn} <- read_memory_form(conn),
         %{} = form <- decode_form(body) do
      {:ok, form, conn}
    else
      _ -> {:error, :form}
    end
  end

  defp memory_review_form(conn) do
    with [content_type] <- get_req_header(conn, "content-type"),
         true <-
           String.starts_with?(String.downcase(content_type), "application/x-www-form-urlencoded"),
         {:ok, body, conn} <- read_memory_form(conn),
         %{"_token" => token, "subject" => subject, "value" => value} = form <-
           decode_form(body),
         true <- Maps.exact_keys?(form, ["_token", "subject", "value"]),
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
         %{"_token" => token, "message" => message} = form <- decode_form(body),
         true <- Maps.exact_keys?(form, ["_token", "message"]),
         true <- is_binary(token) and is_binary(message) do
      {:ok, token, message, [], conn}
    else
      _invalid -> {:error, :form}
    end
  end

  defp lab_form(conn, "multipart/form-data" <> _parameters) do
    with {:ok, conn} <- parse_lab_multipart(conn),
         %{"_token" => token, "message" => message} = form <- conn.body_params,
         true <- Maps.exact_keys?(form, ["_token", "message"], ["attachments"]),
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
      {:error, :form} -> {:error, :form}
    end
  end

  defp lab_uploads(_uploads), do: {:error, :form}

  # The bytes, not the browser's label, decide whether Ryker can read a file:
  # a browser labels a .log file or a script application/octet-stream.
  defp readable_attachments(attachments) do
    Enum.reduce_while(attachments, {:ok, []}, fn attachment, {:ok, readable} ->
      case Artifacts.readable_media_type(attachment.media_type, attachment.data) do
        {:ok, media_type} -> {:cont, {:ok, [%{attachment | media_type: media_type} | readable]}}
        :error -> {:halt, {:error, {:unreadable_attachment, attachment}}}
      end
    end)
    |> case do
      {:ok, readable} -> {:ok, Enum.reverse(readable)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lab_record_form(conn, :answer_input) do
    with [content_type] <- get_req_header(conn, "content-type"),
         true <-
           String.starts_with?(String.downcase(content_type), "application/x-www-form-urlencoded"),
         {:ok, body, conn} <- read_form(conn),
         %{"_token" => token, "choice_index" => choice_index} = form <- decode_form(body),
         true <- Maps.exact_keys?(form, ["_token", "choice_index"]),
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
         } = form <- decode_form(body),
         true <- Maps.exact_keys?(form, ["_token", "choice_index", "publication_ref"]),
         {generation, ""} when generation > 0 <- Integer.parse(generation),
         {:ok, publication_ref} <- PathRef.decode(publication_ref) do
      {:ok, token, %{generation: generation, publication_ref: publication_ref}, conn}
    else
      _invalid -> {:error, :form}
    end
  end

  defp lab_record_form(conn, :approve_task_publication) do
    with [content_type] <- get_req_header(conn, "content-type"),
         true <-
           String.starts_with?(String.downcase(content_type), "application/x-www-form-urlencoded"),
         {:ok, body, conn} <- read_form(conn),
         %{"_token" => token, "publication_ref" => publication_ref} = form <- decode_form(body),
         true <- Maps.exact_keys?(form, ["_token", "publication_ref"]),
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

  # A body the query parser cannot read, such as broken percent-encoding, is a
  # bad form like any other; it raised and the person got a 500 (2026-10-04
  # review). Anything that is not a form decodes to nothing a parser matches.
  defp decode_form(body) do
    Query.decode(body)
  rescue
    Plug.Conn.InvalidQueryError -> :invalid
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
      |> put_resp_header("location", Paths.conversation(conversation_id))
      |> send_resp(303, "")
      |> halt()
    end
  end

  # The person using this console is "You" on every page, and "you" mid-sentence.
  defp object("You"), do: "you"
  defp object(name), do: name

  defp editable_memory_review(resource_ref, options) do
    case options.projection.memory_review.(resource_ref) do
      %{"entries" => [_entry], "kind" => "stale", "status" => "pending"} = review ->
        {:ok, review}

      _missing_or_incompatible ->
        {:error, :not_found}
    end
  end

  # A record action that did not go through keeps its action and conversation,
  # so its page can say what was not done and lead back. It once answered with a
  # bare "Record action is no longer available".
  defp act_on_lab_record(conn, options, conversation_id, record_ref, action, action_context) do
    case options.actions.act_on_lab_record.(
           conversation_id,
           record_ref,
           action,
           action_context,
           conn.assigns.viewer
         ) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:lab_record_failed, conversation_id, action, reason}}
    end
  end

  # A confirmed action or record view is a title and a body in the static
  # shell; the title is the page's only heading, led by the way back when the
  # page belongs to another, and the body owns the rest.
  defp html(conn, status, title, body, back \\ nil) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, HTML.page(title, nil, body, back))
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
