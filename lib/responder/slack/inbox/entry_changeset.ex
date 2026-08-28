defmodule Responder.Slack.Inbox.EntryChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Responder.Slack.Admission.Decision
  alias Responder.Slack.Inbox.Entry
  alias Responder.Slack.Input

  @spec insert(Input.t(), Ecto.UUID.t()) :: Ecto.Changeset.t()
  def insert(%Input{} = input, id) do
    fields = %{
      actor_kind: input.actor.kind,
      actor_ref: input.actor.ref,
      channel_ref: input.channel_ref,
      content: input.content,
      dedupe_key: Input.dedupe_key(input),
      event_fingerprint: Input.fingerprint(input),
      event_kind: input.event_kind,
      event_ref: input.event_ref,
      id: id,
      message_ref: input.message_ref,
      occurred_at: input.occurred_at,
      revision: input.revision,
      status: :pending,
      thread_ref: input.thread_ref,
      workspace_ref: input.workspace_ref
    }

    %Entry{}
    |> cast(fields, Map.keys(fields))
    |> validate_required(Map.keys(fields) -- [:thread_ref])
    |> unique_constraint(:dedupe_key)
    |> check_constraint(:status, name: :slack_inbox_decision_matches_status)
  end

  @spec decide(Entry.t(), Decision.t(), String.t(), Ecto.UUID.t() | nil) ::
          Ecto.Changeset.t()
  def decide(%Entry{} = entry, %Decision{} = decision, decision_ref, episode_id) do
    document = Decision.document(decision)

    fields = %{
      decision_action: decision.action,
      decision_document: document,
      decision_fingerprint: Decision.fingerprint(decision),
      decision_ref: decision_ref,
      episode_id: episode_id,
      status: :decided
    }

    entry
    |> cast(fields, Map.keys(fields))
    |> validate_required(Map.keys(fields) -- [:episode_id])
    |> unique_constraint(:decision_ref)
    |> foreign_key_constraint(:episode_id)
    |> check_constraint(:status, name: :slack_inbox_decision_matches_status)
  end
end
