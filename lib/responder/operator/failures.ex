defmodule Responder.Operator.Failures do
  @moduledoc """
  Typed inspection and recovery for retryable durable failures.

  Semantic publication review is deliberately absent: a result judged
  non-publishable is a product decision, not failed infrastructure custody.
  """

  alias Responder.ControlPlane.Projection
  alias Responder.Delivery.Operator, as: DeliveryOperator
  alias Responder.Emisar.Operator, as: EmisarOperator
  alias Responder.Ingress.Inbox
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Operator.Actions
  alias Responder.Retention.Operator, as: RetentionOperator
  alias Responder.Retention.OperatorAction
  alias Responder.Slack.{IncidentRoom, IncidentRooms, InteractionAudit, InteractionAudits}
  alias Responder.Work.Custody
  alias Responder.Work.Session

  @kinds ~w(admission delivery emisar retention slack_incident slack_interaction work)
  @spec list(map()) :: {:ok, [map()]} | {:error, term()}
  def list(params \\ %{})
  def list(params) when is_map(params), do: Projection.failures(params)
  def list(_params), do: {:error, {:invalid_operator_failure, :params}}

  @spec retry(String.t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def retry(kind, ref, options) do
    with :ok <- kind(kind),
         :ok <- reference(ref, :ref),
         {:ok, settings} <- settings(options) do
      Actions.run(
        %{
          action: :retry,
          action_ref: settings.action_ref,
          actor_ref: settings.actor_ref,
          kind: kind,
          request: %{"operation" => "retry"},
          resource_ref: ref
        },
        fn -> retry_with_context(kind, ref, settings) end
      )
    end
  end

  defp retry_with_context(kind, ref, settings) do
    with {:ok, failure} <- fetch_failure(kind, ref),
         {:ok, result} <- retry_kind(kind, ref, settings) do
      {:ok, %{outcome: outcome(kind, ref, result), previous: previous(failure)}}
    end
  end

  defp fetch_failure(kind, ref) do
    case Projection.failure(kind, ref) do
      {:ok, failure} -> {:ok, failure}
      :not_found -> {:error, :operator_failure_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp retry_kind("admission", ref, _settings), do: Inbox.rearm(ref)
  defp retry_kind("delivery", ref, _settings), do: DeliveryOperator.rearm(ref)
  defp retry_kind("emisar", ref, _settings), do: EmisarOperator.rearm(ref)
  defp retry_kind("slack_incident", ref, _settings), do: IncidentRooms.rearm(ref)
  defp retry_kind("slack_interaction", ref, _settings), do: InteractionAudits.rearm(ref)
  defp retry_kind("work", ref, _settings), do: Custody.retry_blocked(ref)

  defp retry_kind("retention", ref, settings) do
    RetentionOperator.rearm(ref, settings.actor_ref, settings.action_ref)
  end

  defp outcome("admission", ref, %Entry{} = entry) do
    %{
      "attempt_count" => entry.attempt_count,
      "kind" => "admission",
      "ref" => ref,
      "status" => Atom.to_string(entry.status)
    }
  end

  defp outcome("delivery", ref, item) when is_map(item) do
    %{
      "attempt_count" => item.attempt_count,
      "kind" => "delivery",
      "ref" => ref,
      "retry_generation" => item.retry_generation,
      "status" => Atom.to_string(item.status)
    }
  end

  defp outcome("emisar", ref, item) when is_map(item) do
    %{
      "attempt_count" => item.failure_count,
      "kind" => "emisar",
      "ref" => ref,
      "status" => Atom.to_string(item.status)
    }
  end

  defp outcome("retention", ref, %{
         action: %OperatorAction{} = action,
         outcome: outcome,
         session: %Session{} = session
       }) do
    %{
      "retention_action_ref" => action.action_ref,
      "retention_actor_ref" => action.actor_ref,
      "kind" => "retention",
      "outcome" => Atom.to_string(outcome),
      "ref" => ref,
      "status" => Atom.to_string(session.cleanup_status)
    }
  end

  defp outcome("slack_incident", ref, %IncidentRoom{} = room) do
    %{
      "attempt_count" => room.attempt_count,
      "kind" => "slack_incident",
      "ref" => ref,
      "status" => Atom.to_string(room.status)
    }
  end

  defp outcome("slack_interaction", ref, %InteractionAudit{} = audit) do
    %{
      "attempt_count" => audit.attempt_count,
      "kind" => "slack_interaction",
      "ref" => ref,
      "status" => Atom.to_string(audit.repaint_status)
    }
  end

  defp outcome("work", ref, episode) do
    %{"kind" => "work", "ref" => ref, "status" => Atom.to_string(episode.state)}
  end

  defp previous(failure) do
    %{
      "attempt_count" => Map.get(failure, :attempt_count, 0),
      "detail" => failure.detail,
      "kind" => failure.kind,
      "ref" => failure.ref,
      "status" => Atom.to_string(failure.status),
      "summary" => failure.summary
    }
  end

  defp settings(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
         Keyword.keys(options) -- [:actor_ref, :action_ref] == [] do
      with {:ok, actor_ref} <- Keyword.fetch(options, :actor_ref),
           {:ok, action_ref} <- Keyword.fetch(options, :action_ref),
           :ok <- reference(actor_ref, :actor_ref),
           :ok <- reference(action_ref, :action_ref) do
        {:ok, %{action_ref: action_ref, actor_ref: actor_ref}}
      else
        :error -> {:error, {:invalid_operator_failure, :options}}
        {:error, _reason} = error -> error
      end
    else
      {:error, {:invalid_operator_failure, :options}}
    end
  end

  defp settings(_options), do: {:error, {:invalid_operator_failure, :options}}

  defp kind(kind) when kind in @kinds, do: :ok
  defp kind(_kind), do: {:error, {:invalid_operator_failure, :kind}}

  defp reference(value, field)
       when is_binary(value) and byte_size(value) in 1..1_024 do
    if String.valid?(value) and String.trim(value) != "" and
         :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, {:invalid_operator_failure, field}}
  end

  defp reference(_value, field), do: {:error, {:invalid_operator_failure, field}}
end
