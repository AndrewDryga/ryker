defmodule Ryker.GitHub.Router do
  @moduledoc """
  Minimal asynchronous GitHub App webhook ingress.

  A `202` response means the exact normalized event is durably queued. GitHub
  authentication and trusted binding checks happen before arbitrary payload
  content can reach the generic admission queue.
  """
  @behaviour Plug
  alias Ryker.Crypto
  alias Ryker.GitHub
  alias Ryker.GitHub.{Access, Auth, Binding, Confirmations, Engagement, Events}
  alias Ryker.HTTPConnection
  alias Ryker.Ingress
  alias Ryker.Publication
  alias Ryker.Secret

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
      max_body_bytes:
        bindings
        |> Map.values()
        |> Enum.map(& &1.max_body_bytes)
        |> Enum.max(fn -> Binding.default_max_body_bytes() end),
      repository_access: repository_access,
      secret: secret
    }
  end

  defp validate_options!(bindings, bot_login, repository_access, secret) do
    # No binding is a verified App with no repository added yet: it still
    # answers GitHub's ping and installation events.
    unless is_map(bindings) and Enum.all?(bindings, &valid_binding_entry?/1),
      do: raise(ArgumentError, "GitHub bindings must map names to matching bindings")

    unless GitHub.webhook_secret?(secret),
      do: raise(ArgumentError, "GitHub webhook secret must be sealed and hold 32 to 1024 bytes")

    unless is_function(repository_access, 2),
      do: raise(ArgumentError, "GitHub repository access checker is invalid")

    unless GitHub.login?(bot_login), do: raise(ArgumentError, "GitHub bot login is invalid")
  end

  defp confirmations(options) do
    case Keyword.get(options, :confirmations) do
      nil -> nil
      configured -> Confirmations.options!(configured)
    end
  end

  @impl Plug
  def call(conn, options),
    do: conn |> HTTPConnection.close_after_refusal() |> route(options)

  defp route(%Plug.Conn{method: "POST", path_info: ["v1", "github"]} = conn, options),
    do: admit(conn, options)

  defp route(conn, _options),
    do: Ingress.InboundHTTP.respond(conn, 404, %{"error" => "not_found"})

  defp admit(conn, options) do
    with :ok <- Ingress.InboundHTTP.json_content_type(conn),
         {:ok, body, conn} <- Ingress.InboundHTTP.read_bounded_body(conn, options.max_body_bytes),
         :ok <- Auth.authorize(conn, Secret.reveal(options.secret), body),
         {:ok, delivery_ref} <-
           Ingress.InboundHTTP.required_header(conn, "x-github-delivery", :delivery_ref),
         {:ok, event_name} <-
           Ingress.InboundHTTP.required_header(conn, "x-github-event", :event_name),
         {:ok, payload} <- Ingress.InboundHTTP.decode_json(body, :object) do
      route_event(conn, options, body, delivery_ref, event_name, payload)
    else
      {:error, :unsupported_media_type} ->
        Ingress.InboundHTTP.respond(conn, 415, %{"error" => "unsupported_media_type"})

      {:error, :too_large} ->
        Ingress.InboundHTTP.respond(conn, 413, %{"error" => "payload_too_large"})

      {:error, :unauthorized} ->
        Ingress.InboundHTTP.respond(conn, 401, %{"error" => "unauthorized"})

      {:error, field} when field in [:delivery_ref, :event_name] ->
        Ingress.InboundHTTP.respond(conn, 400, %{"error" => "invalid_metadata"})

      {:error, :json} ->
        Ingress.InboundHTTP.respond(conn, 400, %{"error" => "invalid_json"})

      {:error, :body} ->
        Ingress.InboundHTTP.respond(conn, 503, %{"error" => "temporarily_unavailable"})
    end
  end

  defp route_event(conn, _options, _body, _delivery_ref, "ping", _payload),
    do: Ingress.InboundHTTP.respond(conn, 200, %{"status" => "ignored"})

  defp route_event(conn, options, body, delivery_ref, event_name, payload)
       when event_name in @access_events do
    bindings = Access.affected(event_name, payload, options.bindings)
    event_ref = authenticated_event_ref(body)

    receipts =
      Enum.map(bindings, &Events.record(&1, delivery_ref, event_ref, event_name, payload))

    case access_step(receipts, bindings, event_name, payload) do
      :conflict ->
        Ingress.InboundHTTP.respond(conn, 409, %{"error" => "event_conflict"})

      :unavailable ->
        Ingress.InboundHTTP.respond(conn, 503, %{"error" => "temporarily_unavailable"})

      :ignored ->
        Ingress.InboundHTTP.respond(conn, 200, %{"status" => "ignored"})

      :duplicate ->
        Ingress.InboundHTTP.respond(conn, 202, %{"status" => "duplicate"})

      :apply ->
        apply_access(conn, receipts, event_name, payload, options)
    end
  end

  defp route_event(conn, options, body, delivery_ref, event_name, payload) do
    with {:ok, binding} <- binding_for_payload(options.binding_index, payload),
         true <- byte_size(body) <= binding.max_body_bytes do
      event_ref = authenticated_event_ref(body)

      case Events.record(binding, delivery_ref, event_ref, event_name, payload) do
        {:ok, :duplicate} ->
          Ingress.InboundHTTP.respond(conn, 202, %{"status" => "duplicate"})

        {:ok, receipt} ->
          response =
            admit_event(conn, binding, delivery_ref, event_ref, event_name, payload, options)

          _ = Events.complete(receipt, disposition(response), response_reason(response))
          response

        {:error, :github_event_conflict} ->
          Ingress.InboundHTTP.respond(conn, 409, %{"error" => "event_conflict"})

        {:error, _reason} ->
          Ingress.InboundHTTP.respond(conn, 503, %{"error" => "temporarily_unavailable"})
      end
    else
      false -> Ingress.InboundHTTP.respond(conn, 413, %{"error" => "payload_too_large"})
      {:error, :binding} -> Ingress.InboundHTTP.respond(conn, 400, %{"error" => "invalid_event"})
    end
  end

  # What an access event's receipts and bindings call for. A repository the
  # App was just given has no binding yet, so an event that adds one goes on
  # to Access, which adds it when auto-add is on.
  defp access_step(receipts, bindings, event_name, payload) do
    cond do
      Enum.any?(receipts, &(&1 == {:error, :github_event_conflict})) -> :conflict
      Enum.any?(receipts, &match?({:error, _}, &1)) -> :unavailable
      bindings == [] and not Access.adds_repositories?(event_name, payload) -> :ignored
      receipts != [] and Enum.all?(receipts, &(&1 == {:ok, :duplicate})) -> :duplicate
      true -> :apply
    end
  end

  defp apply_access(conn, receipts, event_name, payload, options) do
    case Access.apply(event_name, payload, options.bindings) do
      {:ok, changed} ->
        complete_receipts(receipts, "metadata", "access_updated")

        Ingress.InboundHTTP.respond(conn, 202, %{
          "repositories" => length(changed),
          "status" => "updated"
        })

      {:error, _reason} ->
        complete_receipts(receipts, "failed", "settings_update_failed")
        Ingress.InboundHTTP.respond(conn, 503, %{"error" => "temporarily_unavailable"})
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
           Publication.Followups.nudge_github_event(
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
        Ingress.InboundHTTP.respond(conn, 400, %{"error" => "invalid_event"})

      {:error, _reason} ->
        Ingress.InboundHTTP.respond(conn, 503, %{"error" => "temporarily_unavailable"})
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
       do: Ingress.InboundHTTP.respond(conn, 202, %{"status" => Atom.to_string(outcome)})

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
         {:ok, input} <- Ingress.Adapters.normalize("github", event, binding) do
      confirm_or_record(conn, input, binding, options)
    else
      {:error, :actor_not_authorized} ->
        Ingress.InboundHTTP.respond(conn, 200, %{
          "reason" => "repository_write_access_required",
          "status" => "ignored"
        })

      {:error, {:invalid_github_input, _field}} ->
        Ingress.InboundHTTP.respond(conn, 400, %{"error" => "invalid_event"})

      {:error, {:invalid_input, _field}} ->
        Ingress.InboundHTTP.respond(conn, 400, %{"error" => "invalid_event"})

      {:error, {:invalid_input, _field, _reason}} ->
        Ingress.InboundHTTP.respond(conn, 400, %{"error" => "invalid_event"})

      {:error, {:github_input_ignored, _reason}} ->
        Ingress.InboundHTTP.respond(conn, 200, %{"status" => "ignored"})

      {:error, {:input_conflict, _details}} ->
        Ingress.InboundHTTP.respond(conn, 409, %{"error" => "event_conflict"})

      {:error, _reason} ->
        Ingress.InboundHTTP.respond(conn, 503, %{"error" => "temporarily_unavailable"})
    end
  end

  defp authorize_repository_actor(event_name, binding, payload, options)
       when event_name in @conversation_events,
       do: options.repository_access.(binding, payload)

  defp authorize_repository_actor(_event_name, _binding, _payload, _options), do: :ok

  # Someone asking needs write access to the repository, whatever carried the
  # ask. Comments and reviews were checked on arrival; an issue or a pull
  # request is checked here, once Ryker would take it. An edit of the exact item
  # Ryker already took, and an event an operator's standing rule chose, are not
  # someone asking.
  defp authorize_engagement(
         reason,
         %{content: %{"event_name" => event_name, "payload" => payload}},
         binding,
         options
       )
       when reason in [:mention, :continuation] and event_name not in @conversation_events,
       do: options.repository_access.(binding, payload)

  defp authorize_engagement(_reason, _input, _binding, _options), do: :ok

  defp observe_and_record(conn, input, binding, options) do
    case Publication.Followups.observe_github_feedback(input) do
      {:ok, subscription} -> record_or_subscribe(conn, input, binding, subscription, options)
      {:error, reason} -> route_record_error(conn, reason)
    end
  end

  defp confirm_or_record(conn, input, binding, options) do
    case Confirmations.apply(input, options.confirmations) do
      {:ok, :not_confirmation} ->
        observe_and_record(conn, input, binding, options)

      {:ok, %{"status" => status} = confirmation} ->
        Ingress.InboundHTTP.respond(conn, 202, %{
          "confirmation" => confirmation,
          "status" => status
        })

      {:error, _reason} ->
        Ingress.InboundHTTP.respond(conn, 503, %{"error" => "temporarily_unavailable"})
    end
  end

  defp record_or_subscribe(conn, input, binding, :unmatched, options) do
    with {:yes, reason} <- Engagement.reason(input, binding, options.bot_login),
         :ok <- authorize_engagement(reason, input, binding, options) do
      case Ingress.Inbox.record(input,
             engagement_receipt: %{"reason" => Atom.to_string(reason)},
             revision_ties: :receipt_order,
             work_profile: binding.work_profile
           ) do
        {:ok, receipt} ->
          Ingress.InboundHTTP.respond(conn, 202, %{
            "input_ref" => Ingress.Inbox.ref(receipt.entry),
            "status" => Atom.to_string(receipt.status)
          })

        {:error, record_reason} ->
          route_record_error(conn, record_reason)
      end
    else
      :metadata ->
        Ingress.InboundHTTP.respond(conn, 200, %{
          "status" => "ignored",
          "reason" => "no_request_or_rule"
        })

      {:error, :actor_not_authorized} ->
        Ingress.InboundHTTP.respond(conn, 200, %{
          "reason" => "repository_write_access_required",
          "status" => "ignored"
        })

      {:error, _reason} ->
        Ingress.InboundHTTP.respond(conn, 503, %{"error" => "temporarily_unavailable"})
    end
  end

  defp record_or_subscribe(conn, _input, _binding, %{event: event, status: status}, _options) do
    Ingress.InboundHTTP.respond(conn, 202, %{
      "publication_event_ref" => event.ref,
      "status" => Atom.to_string(status)
    })
  end

  defp route_record_error(conn, {:invalid_input, _field}),
    do: Ingress.InboundHTTP.respond(conn, 400, %{"error" => "invalid_event"})

  defp route_record_error(conn, {:invalid_input, _field, _reason}),
    do: Ingress.InboundHTTP.respond(conn, 400, %{"error" => "invalid_event"})

  defp route_record_error(conn, {:input_conflict, _details}),
    do: Ingress.InboundHTTP.respond(conn, 409, %{"error" => "event_conflict"})

  defp route_record_error(conn, _reason),
    do: Ingress.InboundHTTP.respond(conn, 503, %{"error" => "temporarily_unavailable"})

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
    digest = Crypto.sha256_hex(body)
    "github-body:#{digest}"
  end

  defp disposition(%Plug.Conn{status: 200}), do: "metadata"
  defp disposition(%Plug.Conn{status: 202}), do: "routed"
  defp disposition(%Plug.Conn{}), do: "failed"

  # From the document sent, never the sent body: under Bandit, which serves
  # GitHub's real deliveries, a sent response keeps no body.
  defp response_reason(conn) do
    case Ingress.InboundHTTP.response(conn) do
      %{"reason" => reason} when is_binary(reason) -> reason
      %{"error" => reason} when is_binary(reason) -> reason
      _other -> nil
    end
  end

  defp unconfigured_repository_access(_binding, _payload),
    do: {:error, {:github_repository_access_unavailable, :not_configured}}
end
