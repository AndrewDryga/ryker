defmodule Ryker.GitHub.Router do
  @moduledoc """
  Minimal asynchronous GitHub App webhook ingress.

  A `202` response means the exact normalized event is durably queued. GitHub
  authentication and trusted binding checks happen before arbitrary payload
  content can reach the generic admission queue.
  """

  @behaviour Plug

  alias Ryker.BundledCoop
  alias Ryker.GitHub.{Access, Auth, Binding, Confirmations, Engagement, Events}
  alias Ryker.Ingress.{Adapters, HTTP, Inbox}
  alias Ryker.Publication.Followups

  @lifecycle_events ~w(check_run check_suite pull_request status workflow_job workflow_run)
  @access_events ~w(installation installation_repositories repository)
  @conversation_events ~w(issue_comment pull_request_review pull_request_review_comment)

  @impl Plug
  def init(options) do
    bindings = Keyword.fetch!(options, :bindings)
    bot_login = Keyword.get(options, :bot_login)

    repository_access =
      Keyword.get(options, :repository_access, &unconfigured_repository_access/2)

    secret = Keyword.fetch!(options, :secret)

    validate_options!(bindings, bot_login, repository_access, secret)

    binding_index = binding_index!(bindings)

    confirmations = confirmations(options)

    %{
      binding_index: binding_index,
      bindings: bindings,
      bot_login: bot_login,
      confirmations: confirmations,
      max_body_bytes: bindings |> Map.values() |> Enum.map(& &1.max_body_bytes) |> Enum.max(),
      repository_access: repository_access,
      secret: secret
    }
  end

  defp validate_options!(bindings, bot_login, repository_access, secret) do
    unless is_map(bindings) and map_size(bindings) > 0 and
             Enum.all?(bindings, &valid_binding_entry?/1),
           do: raise(ArgumentError, "GitHub bindings must map names to matching bindings")

    unless is_binary(secret) and byte_size(secret) in 32..1_024,
      do: raise(ArgumentError, "GitHub webhook secret must contain 32 to 1024 bytes")

    unless is_function(repository_access, 2),
      do: raise(ArgumentError, "GitHub repository access checker is invalid")

    unless is_binary(bot_login) and
             Regex.match?(~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\z/, bot_login),
           do: raise(ArgumentError, "GitHub bot login is invalid")
  end

  defp confirmations(options) do
    case Keyword.get(options, :confirmations) do
      nil -> nil
      configured -> Confirmations.options!(configured)
    end
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

  defp route_event(conn, options, body, delivery_ref, event_name, payload)
       when event_name in @access_events do
    bindings = Access.affected(event_name, payload, options.bindings)
    event_ref = authenticated_event_ref(body)

    receipts =
      Enum.map(bindings, &Events.record(&1, delivery_ref, event_ref, event_name, payload))

    cond do
      Enum.any?(receipts, &(&1 == {:error, :github_event_conflict})) ->
        HTTP.respond(conn, 409, %{"error" => "event_conflict"})

      Enum.any?(receipts, &match?({:error, _}, &1)) ->
        HTTP.respond(conn, 503, %{"error" => "temporarily_unavailable"})

      bindings == [] ->
        HTTP.respond(conn, 200, %{"status" => "ignored"})

      Enum.all?(receipts, &(&1 == {:ok, :duplicate})) ->
        HTTP.respond(conn, 202, %{"status" => "duplicate"})

      true ->
        case Access.apply(event_name, payload, options.bindings) do
          {:ok, changed} ->
            complete_receipts(receipts, "metadata", "access_updated")

            HTTP.respond(conn, 202, %{"repositories" => length(changed), "status" => "updated"})

          {:error, _reason} ->
            complete_receipts(receipts, "failed", "settings_update_failed")

            HTTP.respond(conn, 503, %{"error" => "temporarily_unavailable"})
        end
    end
  end

  defp route_event(conn, options, body, delivery_ref, event_name, payload) do
    with {:ok, binding} <- binding_for_payload(options.binding_index, payload),
         true <- byte_size(body) <= binding.max_body_bytes do
      event_ref = authenticated_event_ref(body)

      case Events.record(binding, delivery_ref, event_ref, event_name, payload) do
        {:ok, :duplicate} ->
          HTTP.respond(conn, 202, %{"status" => "duplicate"})

        {:ok, receipt} ->
          :ok = BundledCoop.request_materialization(binding.name, receipt.occurred_at)

          response =
            admit_event(conn, binding, delivery_ref, event_ref, event_name, payload, options)

          _ = Events.complete(receipt, disposition(response), response_reason(response))
          response

        {:error, :github_event_conflict} ->
          HTTP.respond(conn, 409, %{"error" => "event_conflict"})

        {:error, _reason} ->
          HTTP.respond(conn, 503, %{"error" => "temporarily_unavailable"})
      end
    else
      false -> HTTP.respond(conn, 413, %{"error" => "payload_too_large"})
      {:error, :binding} -> HTTP.respond(conn, 400, %{"error" => "invalid_event"})
    end
  end

  defp complete_receipts(receipts, disposition, reason) do
    Enum.each(receipts, fn
      {:ok, receipt} -> Events.complete(receipt, disposition, reason)
      _duplicate -> :ok
    end)
  end

  defp admit_event(conn, binding, delivery_ref, event_ref, event_name, payload, options)
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
        options,
        outcome
      )
    else
      {:error, {:invalid_github_input, _field}} ->
        HTTP.respond(conn, 400, %{"error" => "invalid_event"})

      {:error, _reason} ->
        HTTP.respond(conn, 503, %{"error" => "temporarily_unavailable"})
    end
  end

  defp admit_event(conn, binding, delivery_ref, event_ref, event_name, payload, options) do
    admit_generic_event(
      conn,
      binding,
      delivery_ref,
      event_ref,
      event_name,
      payload,
      options
    )
  end

  defp route_lifecycle_outcome(
         conn,
         binding,
         delivery_ref,
         event_ref,
         event_name,
         payload,
         options,
         :ignored
       ) do
    admit_generic_event(
      conn,
      binding,
      delivery_ref,
      event_ref,
      event_name,
      payload,
      options
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
         options
       ) do
    event = %{
      delivery_ref: delivery_ref,
      event_name: event_name,
      event_ref: event_ref,
      payload: payload
    }

    with :ok <- authorize_repository_actor(event_name, binding, payload, options),
         {:ok, input} <- Adapters.normalize("github", event, binding) do
      confirm_or_record(conn, input, binding, options)
    else
      {:error, :actor_not_authorized} ->
        HTTP.respond(conn, 200, %{
          "reason" => "repository_write_access_required",
          "status" => "ignored"
        })

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

  defp authorize_repository_actor(event_name, binding, payload, options)
       when event_name in @conversation_events,
       do: options.repository_access.(binding, payload)

  defp authorize_repository_actor(_event_name, _binding, _payload, _options), do: :ok

  defp observe_and_record(conn, input, binding, options) do
    case Followups.observe_github_feedback(input) do
      {:ok, subscription} -> record_or_subscribe(conn, input, binding, subscription, options)
      {:error, reason} -> route_record_error(conn, reason)
    end
  end

  defp confirm_or_record(conn, input, binding, options) do
    case Confirmations.apply(input, options.confirmations) do
      {:ok, :not_confirmation} ->
        observe_and_record(conn, input, binding, options)

      {:ok, %{"status" => status} = confirmation} ->
        HTTP.respond(conn, 202, %{"confirmation" => confirmation, "status" => status})

      {:error, _reason} ->
        HTTP.respond(conn, 503, %{"error" => "temporarily_unavailable"})
    end
  end

  defp record_or_subscribe(conn, input, binding, :unmatched, options) do
    case Engagement.eligible?(input, binding, options.bot_login) do
      {:yes, reason} ->
        case Inbox.record(input,
               engagement_receipt: %{"reason" => Atom.to_string(reason)},
               revision_ties: :receipt_order,
               work_profile: binding.work_profile
             ) do
          {:ok, receipt} ->
            HTTP.respond(conn, 202, %{
              "input_ref" => Inbox.ref(receipt.entry),
              "status" => Atom.to_string(receipt.status)
            })

          {:error, record_reason} ->
            route_record_error(conn, record_reason)
        end

      :metadata ->
        HTTP.respond(conn, 200, %{"status" => "ignored", "reason" => "no_request_or_rule"})
    end
  end

  defp record_or_subscribe(conn, _input, _binding, %{event: event, status: status}, _options) do
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

  defp disposition(%Plug.Conn{status: 200}), do: "metadata"
  defp disposition(%Plug.Conn{status: 202}), do: "routed"
  defp disposition(%Plug.Conn{}), do: "failed"

  defp response_reason(%Plug.Conn{resp_body: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"reason" => reason}} when is_binary(reason) -> reason
      {:ok, %{"error" => reason}} when is_binary(reason) -> reason
      _other -> nil
    end
  end

  defp unconfigured_repository_access(_binding, _payload),
    do: {:error, {:github_repository_access_unavailable, :not_configured}}
end
