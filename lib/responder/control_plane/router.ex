defmodule Responder.ControlPlane.Router do
  @moduledoc false

  import Plug.Conn

  alias Plug.Conn.Query
  alias Responder.ControlPlane.{CSRF, HTML}

  @behaviour Plug
  @maximum_form_bytes 4_096
  @maximum_lab_form_bytes 65_536
  @allowed_hosts ["127.0.0.1", "localhost", "::1"]
  @lab_action "conversation_lab:send"

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
    conn = conn |> security_headers() |> put_resp_header("x-responder-version", release_version())

    cond do
      conn.host not in @allowed_hosts -> text(conn, 421, "Misdirected request")
      not loopback?(conn.remote_ip) -> text(conn, 403, "Loopback access only")
      true -> route(conn, options)
    end
  end

  defp release_version do
    case Application.spec(:responder, :vsn) do
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

  defp route(%Plug.Conn{method: "GET", path_info: ["lab"]} = conn, options) do
    html(conn, 200, "Conversation Lab", HTML.lab_index(options.projection.lab_index.()))
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["lab", "new"]} = conn, _options) do
    conn
    |> put_resp_header("location", "/lab/#{Ecto.UUID.generate()}")
    |> send_resp(303, "")
    |> halt()
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["lab", conversation_id]} = conn, options) do
    case lab_id(conversation_id) do
      {:ok, conversation_id} -> render_lab(conn, options, conversation_id)
      {:error, :path_ref} -> html(conn, 404, "Not found", HTML.generic("Conversation", []))
    end
  end

  defp route(
         %Plug.Conn{method: "POST", path_info: ["lab", conversation_id, "messages"]} = conn,
         options
       ) do
    with {:ok, conversation_id} <- lab_id(conversation_id),
         {:ok, token, message, conn} <- lab_form(conn),
         true <- CSRF.valid?(options.csrf_secret, @lab_action, conversation_id, token),
         {:ok, _receipt} <- options.actions.send_lab_message.(conversation_id, message) do
      conn
      |> put_resp_header("location", "/lab/#{conversation_id}")
      |> send_resp(303, "")
      |> halt()
    else
      false -> text(conn, 403, "Invalid confirmation token")
      {:error, :path_ref} -> text(conn, 404, "Conversation not found")
      {:error, :form} -> text(conn, 400, "Invalid form")
      {:error, {:invalid_conversation_lab, _field}} -> text(conn, 422, "Invalid message")
      {:error, _reason} -> text(conn, 409, "Message could not be accepted")
    end
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["manual-tests"]} = conn, options) do
    html(
      conn,
      200,
      "Manual product journeys",
      HTML.manual_tests(options.projection.configuration.())
    )
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["episodes"]} = conn, options) do
    conn = fetch_query_params(conn)

    snapshot =
      options.projection.episodes.(
        Map.take(conn.query_params, ["page", "state", "q", "target", "repository"])
      )

    html(conn, 200, "Episodes", HTML.episodes(snapshot))
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["episodes", episode_ref]} = conn, options) do
    case path_ref(episode_ref) do
      {:ok, episode_ref} -> render_episode(conn, options, episode_ref)
      {:error, :path_ref} -> html(conn, 404, "Not found", HTML.generic("Episode", []))
    end
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["memory"]} = conn, options) do
    html(
      conn,
      200,
      "Memory and schedules",
      HTML.memory(options.projection.memory.(), options.csrf_secret)
    )
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["configuration"]} = conn, options) do
    html(conn, 200, "Configuration", HTML.configuration(options.projection.configuration.()))
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["usage"]} = conn, options) do
    conn = fetch_query_params(conn)
    snapshot = options.projection.usage.(Map.take(conn.query_params, ["window"]))
    html(conn, 200, "Usage and timing", HTML.usage(snapshot))
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["failures"]} = conn, options) do
    conn = fetch_query_params(conn)
    html(conn, 200, "Failures", HTML.failures(options.projection.failures.(conn.query_params)))
  end

  defp route(
         %Plug.Conn{method: "GET", path_info: ["failures", kind, resource_ref]} = conn,
         options
       ) do
    with true <- kind in failure_kinds(),
         {:ok, resource_ref} <- path_ref(resource_ref),
         %{} = row <-
           Enum.find(options.projection.failures.(%{}), fn row ->
             row.kind == kind and row.ref == resource_ref
           end) do
      html(conn, 200, "Failure context", HTML.failure(row))
    else
      _not_found -> html(conn, 404, "Not found", HTML.generic("Failure", []))
    end
  end

  defp route(%Plug.Conn{method: "GET", path_info: ["workspaces"]} = conn, options) do
    conn = fetch_query_params(conn)

    html(
      conn,
      200,
      "Workspaces",
      HTML.workspaces(options.projection.workspaces.(conn.query_params))
    )
  end

  defp route(%Plug.Conn{method: "GET", path_info: [page]} = conn, options)
       when page in ["decisions", "findings", "audit"] do
    conn = fetch_query_params(conn)
    callback = Map.fetch!(options.projection, String.to_existing_atom(page))
    rows = callback.(conn.query_params)
    html(conn, 200, String.capitalize(page), HTML.generic(String.capitalize(page), rows))
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
        HTML.confirmation(title, explanation, path, token, action_return_path(kind))
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
         {:ok, _resource} <- perform(kind, resource_ref, action, options.actions) do
      conn
      |> put_resp_header("location", action_return_path(kind))
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

  defp render_episode(conn, options, episode_ref) do
    case options.projection.episode.(episode_ref) do
      {:ok, detail} -> html(conn, 200, "Episode", HTML.episode(detail))
      :not_found -> html(conn, 404, "Not found", HTML.generic("Episode", []))
      {:error, _reason} -> html(conn, 503, "Unavailable", HTML.generic("Episode", []))
    end
  end

  defp render_lab(conn, options, conversation_id) do
    snapshot =
      case options.projection.lab_conversation.(conversation_id) do
        {:ok, snapshot} -> snapshot
        :not_found -> empty_lab(conversation_id)
        {:error, _reason} -> nil
      end

    if snapshot do
      token = CSRF.token(options.csrf_secret, @lab_action, conversation_id)
      html(conn, 200, "Conversation Lab", HTML.lab_conversation(snapshot, token))
    else
      html(conn, 503, "Unavailable", HTML.generic("Conversation", []))
    end
  end

  defp empty_lab(conversation_id) do
    %{
      blocked: false,
      conversation_id: conversation_id,
      conversation_ref: "control-plane:lab:#{conversation_id}",
      episodes: [],
      live: false,
      messages: [],
      pending: 0
    }
  end

  defp confirmation("memory", resource_ref, "forget", options) do
    snapshot = options.projection.memory.()

    case Enum.find(snapshot.memories, &(&1.ref == resource_ref and &1.status == :active)) do
      nil ->
        {:error, :not_found}

      memory ->
        {:ok, "Forget #{memory.subject} memory?", "The stored value will be redacted.",
         "memory:forget"}
    end
  end

  defp confirmation("behavior", resource_ref, action, options)
       when action in ["active", "disabled", "deleted"] do
    snapshot = options.projection.memory.()

    case Enum.find(
           snapshot.behaviors,
           &(&1.ref == resource_ref and &1.status in [:active, :disabled])
         ) do
      nil ->
        {:error, :not_found}

      behavior ->
        {:ok, "Change #{behavior.subject}?",
         "The typed behavior lifecycle will change to #{action}.", "behavior:#{action}"}
    end
  end

  defp confirmation("schedule", resource_ref, action, options)
       when action in ["active", "paused", "deleted"] do
    snapshot = options.projection.memory.()

    case Enum.find(
           snapshot.schedules,
           &(&1.ref == resource_ref and &1.status in [:active, :paused])
         ) do
      nil ->
        {:error, :not_found}

      schedule ->
        {:ok, "Change #{schedule.title}?", "The schedule lifecycle will change to #{action}.",
         "schedule:#{action}"}
    end
  end

  defp confirmation("delivery", resource_ref, "rearm", options) do
    case options.projection.delivery.(resource_ref) do
      {:ok, %{status: :blocked}} ->
        {:ok, "Rearm this delivery?",
         "Responder will retry the exact accepted message, reaction, or platform action at its original destination.",
         "delivery:rearm"}

      _not_blocked ->
        {:error, :not_found}
    end
  end

  defp confirmation("admission", resource_ref, "rearm", options) do
    case options.projection.admission.(resource_ref) do
      {:ok, %{action: :rearm, status: :blocked}} ->
        {:ok, "Rearm this admission?",
         "Responder will reconcile the same frozen input, context, and Coop operation identities.",
         "admission:rearm"}

      _unavailable ->
        {:error, :not_found}
    end
  end

  defp confirmation("work", resource_ref, "retry", options) do
    case options.projection.work.(resource_ref) do
      {:ok, %{action: :retry, status: :blocked}} ->
        {:ok, "Retry this blocked work?",
         "Responder will preserve the episode and immutable stopped turn, then continue in a fresh logical turn.",
         "work:retry"}

      _unavailable ->
        {:error, :not_found}
    end
  end

  defp confirmation("emisar", resource_ref, "rearm", options) do
    case options.projection.emisar.(resource_ref) do
      {:ok, %{action: :rearm, status: :blocked}} ->
        {:ok, "Rearm this approval monitor?",
         "Responder will resume read-only observation of the same governed Emisar request. It will not approve, deny, or repeat the action.",
         "emisar:rearm"}

      _unavailable ->
        {:error, :not_found}
    end
  end

  defp confirmation("slack_interaction", resource_ref, "rearm", options) do
    case options.projection.slack_interaction.(resource_ref) do
      {:ok, %{action: :rearm, status: :blocked}} ->
        {:ok, "Rearm this Slack repaint?",
         "Responder will repaint the exact host-owned message recorded by the original interaction audit.",
         "slack_interaction:rearm"}

      _unavailable ->
        {:error, :not_found}
    end
  end

  defp confirmation("slack_incident", resource_ref, "rearm", options) do
    case options.projection.slack_incident.(resource_ref) do
      {:ok, %{action: :rearm, status: :blocked}} ->
        {:ok, "Rearm this incident room?",
         "Responder will continue the exact durable Slack room reconciliation without duplicating resources already recorded.",
         "slack_incident:rearm"}

      _unavailable ->
        {:error, :not_found}
    end
  end

  defp confirmation("retention", resource_ref, "rearm", options) do
    case options.projection.workspace.(resource_ref) do
      {:ok, %{action: :rearm, status: :blocked}} ->
        {:ok, "Rearm this cleanup?",
         "Responder will resume the exact blocked cleanup phase without changing its frozen Coop identity.",
         "retention:rearm"}

      _unavailable ->
        {:error, :not_found}
    end
  end

  defp confirmation("retention", resource_ref, "discard", options) do
    case options.projection.workspace.(resource_ref) do
      {:ok, %{action: :discard_unmerged, status: :retained}} ->
        {:ok, "Discard this unmerged workspace?",
         "Responder will request a fresh exact Coop discard plan that accepts unmerged commits. Dirty work will still be retained.",
         "retention:discard_unmerged"}

      _unavailable ->
        {:error, :not_found}
    end
  end

  defp confirmation(_kind, _resource_ref, _action, _snapshot), do: {:error, :not_found}

  defp perform("memory", resource_ref, "forget", actions),
    do: actions.forget_memory.(resource_ref)

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

  defp perform("work", resource_ref, "retry", actions),
    do: actions.retry_work.(resource_ref)

  defp perform("behavior", resource_ref, action, actions)
       when action in ["active", "disabled", "deleted"],
       do: actions.set_behavior_status.(resource_ref, String.to_existing_atom(action))

  defp perform("schedule", resource_ref, action, actions)
       when action in ["active", "paused", "deleted"],
       do: actions.set_schedule_status.(resource_ref, String.to_existing_atom(action))

  defp perform(_kind, _resource_ref, _action, _actions), do: {:error, :invalid_action}

  defp action_return_path("delivery"), do: "/failures"
  defp action_return_path("retention"), do: "/workspaces"

  defp action_return_path(kind)
       when kind in ["admission", "emisar", "slack_incident", "slack_interaction", "work"],
       do: "/failures"

  defp action_return_path(_kind), do: "/memory"

  defp failure_kinds,
    do: ~w(admission delivery emisar retention slack_incident slack_interaction work)

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

  defp lab_form(conn) do
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

  defp read_form(conn) do
    case read_body(conn, length: @maximum_form_bytes + 1, read_length: @maximum_form_bytes + 1) do
      {:ok, body, conn} when byte_size(body) <= @maximum_form_bytes -> {:ok, body, conn}
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

  defp action_path(kind, resource_ref, action),
    do: "/actions/#{kind}/#{URI.encode(resource_ref, &URI.char_unreserved?/1)}/#{action}"

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

  defp html(conn, status, title, body) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, HTML.page(title, body))
    |> halt()
  end

  defp text(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
    |> halt()
  end

  defp security_headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header(
      "content-security-policy",
      "default-src 'none'; style-src 'self'; script-src 'self'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
    )
    |> put_resp_header("cross-origin-resource-policy", "same-origin")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-content-type-options", "nosniff")
  end

  defp loopback?({127, _b, _c, _d}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_ip), do: false
end
