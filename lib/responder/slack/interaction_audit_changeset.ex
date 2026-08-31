defmodule Responder.Slack.InteractionAuditChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Responder.Slack.InteractionAudit

  @fields [
    :action_id,
    :action_value_digest,
    :actor_ref,
    :attempt_count,
    :channel_ref,
    :event_ref,
    :id,
    :last_error_code,
    :last_error_detail,
    :lease_expires_at,
    :lease_owner,
    :lease_ref,
    :message_ref,
    :next_attempt_at,
    :occurred_at,
    :outcome,
    :repaint_status,
    :repainted_at,
    :request_fingerprint,
    :thread_ref,
    :workspace_ref
  ]

  @required_fields [
    :action_id,
    :action_value_digest,
    :actor_ref,
    :attempt_count,
    :channel_ref,
    :event_ref,
    :id,
    :message_ref,
    :occurred_at,
    :outcome,
    :repaint_status,
    :request_fingerprint,
    :workspace_ref
  ]

  def insert(attributes) do
    %InteractionAudit{}
    |> cast(attributes, @fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:event_ref)
    |> check_constraint(:event_ref, name: :slack_interaction_audit_valid)
  end

  def update(%InteractionAudit{} = audit, attributes) do
    audit
    |> cast(attributes, @fields -- [:id])
    |> validate_required(@required_fields)
    |> check_constraint(:event_ref, name: :slack_interaction_audit_valid)
  end
end
