defmodule Ryker.Operator.Failures do
  @moduledoc """
  Typed inspection and recovery for retryable durable failures.

  Semantic publication review is deliberately absent: a result judged
  non-publishable is a product decision, not failed infrastructure custody.
  """

  alias Ryker.ControlPlane.FailureProjection
  alias Ryker.Delivery.Operator, as: DeliveryOperator
  alias Ryker.Emisar.Operator, as: EmisarOperator
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Operator.{Actions, Reference}
  alias Ryker.Retention.Operator, as: RetentionOperator
  alias Ryker.Retention.OperatorAction
  alias Ryker.Slack.{IncidentRoom, IncidentRooms, InteractionAudit, InteractionAudits}
  alias Ryker.Work.Custody
  alias Ryker.Work.Session

  @kinds ~w(admission delivery emisar retention slack_incident slack_interaction work)
  @spec list(map()) :: {:ok, [map()]} | {:error, term()}
  def list(params \\ %{})
  def list(params) when is_map(params), do: FailureProjection.list(params)
  def list(_params), do: {:error, {:invalid_operator_failure, :params}}

  @spec retry(String.t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def retry(kind, ref, options) do
    with :ok <- kind(kind),
         :ok <- reference(ref, :ref),
         {:ok, settings} <- settings(options),
         :ok <- recovery_confirmation(kind, settings.expected_recovery) do
      Actions.run(
        %{
          action: :retry,
          action_ref: settings.action_ref,
          actor_ref: settings.actor_ref,
          kind: kind,
          request:
            Map.merge(
              %{"operation" => "retry"},
              if(kind == "work",
                do: %{"expected_recovery" => settings.expected_recovery},
                else: %{}
              )
            ),
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
    case FailureProjection.fetch(kind, ref) do
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

  defp retry_kind("work", ref, settings),
    do: Custody.retry_blocked(ref, settings.expected_recovery)

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
         Keyword.keys(options) -- [:actor_ref, :action_ref, :expected_recovery] == [] do
      with {:ok, actor_ref} <- Keyword.fetch(options, :actor_ref),
           {:ok, action_ref} <- Keyword.fetch(options, :action_ref),
           :ok <- reference(actor_ref, :actor_ref),
           :ok <- reference(action_ref, :action_ref) do
        {:ok,
         %{
           action_ref: action_ref,
           actor_ref: actor_ref,
           expected_recovery: Keyword.get(options, :expected_recovery)
         }}
      else
        :error -> {:error, {:invalid_operator_failure, :options}}
        {:error, _reason} = error -> error
      end
    else
      {:error, {:invalid_operator_failure, :options}}
    end
  end

  defp settings(_options), do: {:error, {:invalid_operator_failure, :options}}

  defp recovery_confirmation("work", value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, value),
      do: :ok,
      else: {:error, {:invalid_operator_failure, :expected_recovery}}
  end

  defp recovery_confirmation(kind, nil) when kind != "work", do: :ok

  defp recovery_confirmation(_kind, _value),
    do: {:error, {:invalid_operator_failure, :expected_recovery}}

  defp kind(kind) when kind in @kinds, do: :ok
  defp kind(_kind), do: {:error, {:invalid_operator_failure, :kind}}

  defp reference(value, field), do: Reference.check(value, field, :invalid_operator_failure)
end
