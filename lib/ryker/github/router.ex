defmodule Ryker.GitHub.Router do
  @moduledoc """
  Minimal asynchronous GitHub App webhook ingress.

  A `202` response means the exact normalized event is durably queued. GitHub
  authentication and trusted binding checks happen before arbitrary payload
  content can reach the generic admission queue.
  """

  @behaviour Plug

  alias Ryker.GitHub.{Auth, Binding, Confirmations}
  alias Ryker.Ingress.{Adapters, HTTP, Inbox}
  alias Ryker.Publication.Followups

  @ignored_events ~w(pull_request_review_thread)
  @lifecycle_events ~w(check_run check_suite pull_request status workflow_run)

  @impl Plug
  def init(options) do
    bindings = Keyword.fetch!(options, :bindings)
    secret = Keyword.fetch!(options, :secret)

    unless is_map(bindings) and map_size(bindings) > 0 and
             Enum.all?(bindings, &valid_binding_entry?/1),
           do: raise(ArgumentError, "GitHub bindings must map names to matching bindings")

    unless is_binary(secret) and byte_size(secret) in 32..1_024,
      do: raise(ArgumentError, "GitHub webhook secret must contain 32 to 1024 bytes")

    binding_index = binding_index!(bindings)

    confirmations =
      case Keyword.get(options, :confirmations) do
        nil -> nil
        configured -> Confirmations.options!(configured)
      end

    %{
      binding_index: binding_index,
      bindings: bindings,
      confirmations: confirmations,
      max_body_bytes: bindings |> Map.values() |> Enum.map(& &1.max_body_bytes) |> Enum.max(),
      secret: secret
    }
  end

  @impl Plug
  def call(%Plug.Conn{method: "POST", path_info: ["v1", "github"]} = conn, options),
    do: admit(conn, options)

  def call(conn, _options), do: HTTP.respond(conn, 404, %{"error" => "not_found"})

  defp admit(conn, options) do
    with :ok <- HTTP.json_content_type(conn),
         {:ok, body, conn} <- HTTP.read_bounded_body(conn, options.max_body_bytes),
         :ok <- Auth.authorize(conn, options.secret, body),
         {:ok, delivery_ref} <-
           HTTP.required_header(conn, "x-github-delivery", :delivery_ref),
         {:ok, event_name} <- HTTP.required_header(conn, "x-github-event", :event_name),
         {:ok, payload} <- HTTP.decode_json(body, :object) do
      route_event(conn, options, body, delivery_ref, event_name, payload)
    else
      {:error, :unsupported_media_type} ->
        HTTP.respond(conn, 415, %{"error" => "unsupported_media_type"})

      {:error, :too_large} ->
        HTTP.respond(conn, 413, %{"error" => "payload_too_large"})

      {:error, :unauthorized} ->
        HTTP.respond(conn, 401, %{"error" => "unauthorized"})

      {:error, field} when field in [:delivery_ref, :event_name] ->
        HTTP.respond(conn, 400, %{"error" => "invalid_metadata"})

      {:error, :json} ->
        HTTP.respond(conn, 400, %{"error" => "invalid_json"})

      {:error, :body} ->
        HTTP.respond(conn, 503, %{"error" => "temporarily_unavailable"})
    end
  end

  defp route_event(conn, _options, _body, _delivery_ref, "ping", _payload),
    do: HTTP.respond(conn, 200, %{"status" => "ignored"})

  defp route_event(conn, options, body, delivery_ref, event_name, payload) do
    with {:ok, binding} <- binding_for_payload(options.binding_index, payload),
         true <- byte_size(body) <= binding.max_body_bytes do
      admit_event(
        conn,
        binding,
        delivery_ref,
        authenticated_event_ref(body),
        event_name,
        payload,
        options.confirmations
      )
    else
      false -> HTTP.respond(conn, 413, %{"error" => "payload_too_large"})
      {:error, :binding} -> HTTP.respond(conn, 400, %{"error" => "invalid_event"})
    end
  end

  defp admit_event(conn, binding, delivery_ref, event_ref, event_name, payload, confirmations)
       when event_name in @lifecycle_events do
    with :ok <- Binding.authorize_payload(binding, payload),
         {:ok, outcome} <-
           Followups.nudge_github_event(
             binding.repository_full_name,
             event_name,
             event_ref,
             payload
           ) do
      route_lifecycle_outcome(
        conn,
        binding,
        delivery_ref,
        event_ref,
        event_name,
        payload,
        confirmations,
        outcome
      )
    else
      {:error, {:invalid_github_input, _field}} ->
        HTTP.respond(conn, 400, %{"error" => "invalid_event"})

      {:error, _reason} ->
        HTTP.respond(conn, 503, %{"error" => "temporarily_unavailable"})
    end
  end

  defp admit_event(conn, binding, _delivery_ref, _event_ref, event_name, payload, _confirmations)
       when event_name in @ignored_events do
    case Binding.authorize_payload(binding, payload) do
      :ok ->
        HTTP.respond(conn, 200, %{"status" => "ignored"})

      {:error, {:invalid_github_input, _field}} ->
        HTTP.respond(conn, 400, %{"error" => "invalid_event"})
    end
  end

  defp admit_event(conn, binding, delivery_ref, event_ref, event_name, payload, confirmations) do
    admit_generic_event(
      conn,
      binding,
      delivery_ref,
      event_ref,
      event_name,
      payload,
      confirmations
    )
  end

  defp route_lifecycle_outcome(
         conn,
         binding,
         delivery_ref,
         event_ref,
         "pull_request" = event_name,
         payload,
         confirmations,
         :ignored
       ) do
    admit_generic_event(
      conn,
      binding,
      delivery_ref,
      event_ref,
      event_name,
      payload,
      confirmations
    )
  end

  defp route_lifecycle_outcome(
         conn,
         _binding,
         _delivery_ref,
         _event_ref,
         _event_name,
         _payload,
         _confirmations,
         outcome
       ),
       do: HTTP.respond(conn, 202, %{"status" => Atom.to_string(outcome)})

  defp admit_generic_event(
         conn,
         binding,
         delivery_ref,
         event_ref,
         event_name,
         payload,
         confirmations
       ) do
    event = %{
      delivery_ref: delivery_ref,
      event_name: event_name,
      event_ref: event_ref,
      payload: payload
    }

    case Adapters.normalize("github", event, binding) do
      {:ok, input} ->
        confirm_or_record(conn, input, binding, confirmations)

      {:error, {:invalid_github_input, _field}} ->
        HTTP.respond(conn, 400, %{"error" => "invalid_event"})

      {:error, {:invalid_input, _field}} ->
        HTTP.respond(conn, 400, %{"error" => "invalid_event"})

      {:error, {:invalid_input, _field, _reason}} ->
        HTTP.respond(conn, 400, %{"error" => "invalid_event"})

      {:error, {:github_input_ignored, _reason}} ->
        HTTP.respond(conn, 200, %{"status" => "ignored"})

      {:error, {:input_conflict, _details}} ->
        HTTP.respond(conn, 409, %{"error" => "event_conflict"})

      {:error, _reason} ->
        HTTP.respond(conn, 503, %{"error" => "temporarily_unavailable"})
    end
  end

  defp observe_and_record(conn, input, binding) do
    case Followups.observe_github_feedback(input) do
      {:ok, subscription} -> record_or_subscribe(conn, input, binding, subscription)
      {:error, reason} -> route_record_error(conn, reason)
    end
  end

  defp confirm_or_record(conn, input, binding, confirmations) do
    case Confirmations.apply(input, confirmations) do
      {:ok, :not_confirmation} ->
        observe_and_record(conn, input, binding)

      {:ok, %{"status" => status} = confirmation} ->
        HTTP.respond(conn, 202, %{"confirmation" => confirmation, "status" => status})

      {:error, _reason} ->
        HTTP.respond(conn, 503, %{"error" => "temporarily_unavailable"})
    end
  end

  defp record_or_subscribe(conn, input, binding, :unmatched) do
    case Inbox.record(input,
           revision_ties: :receipt_order,
           work_profile: binding.work_profile
         ) do
      {:ok, receipt} ->
        HTTP.respond(conn, 202, %{
          "input_ref" => Inbox.ref(receipt.entry),
          "status" => Atom.to_string(receipt.status)
        })

      {:error, reason} ->
        route_record_error(conn, reason)
    end
  end

  defp record_or_subscribe(conn, _input, _binding, %{event: event, status: status}) do
    HTTP.respond(conn, 202, %{
      "publication_event_ref" => event.ref,
      "status" => Atom.to_string(status)
    })
  end

  defp route_record_error(conn, {:invalid_input, _field}),
    do: HTTP.respond(conn, 400, %{"error" => "invalid_event"})

  defp route_record_error(conn, {:invalid_input, _field, _reason}),
    do: HTTP.respond(conn, 400, %{"error" => "invalid_event"})

  defp route_record_error(conn, {:input_conflict, _details}),
    do: HTTP.respond(conn, 409, %{"error" => "event_conflict"})

  defp route_record_error(conn, _reason),
    do: HTTP.respond(conn, 503, %{"error" => "temporarily_unavailable"})

  defp valid_binding_entry?({name, %Binding{name: name}}) when is_binary(name), do: true
  defp valid_binding_entry?(_entry), do: false

  defp binding_index!(bindings) do
    Enum.reduce(bindings, %{}, fn {_name, binding}, index ->
      key = {binding.installation_id, binding.repository_id}

      case Map.fetch(index, key) do
        :error -> Map.put(index, key, binding)
        {:ok, _duplicate} -> raise ArgumentError, "GitHub bindings must have unique identities"
      end
    end)
  end

  defp binding_for_payload(index, %{
         "installation" => %{"id" => installation_id},
         "repository" => %{"id" => repository_id}
       })
       when is_integer(installation_id) and is_integer(repository_id) do
    case Map.fetch(index, {installation_id, repository_id}) do
      {:ok, binding} -> {:ok, binding}
      :error -> {:error, :binding}
    end
  end

  defp binding_for_payload(_index, _payload), do: {:error, :binding}

  defp authenticated_event_ref(body) do
    digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    "github-body:#{digest}"
  end
end
