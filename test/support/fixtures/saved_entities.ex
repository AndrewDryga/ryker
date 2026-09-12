defmodule Responder.Fixtures.SavedEntities do
  @moduledoc """
  Confirmed schedules, standing rules, preferences, guidance and memories with
  their real offer provenance.

  The requested-collection thread page and the App Home complete list read the
  same rows, so both are tested against these fixtures rather than against two
  differently shaped hand-written sets.
  """

  alias Responder.{Episodes, Repo}
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.State.{Behavior, MemoryEntry, Records, Schedule}
  alias Responder.Work.Custody

  @now ~U[2026-08-28 12:00:00.000000Z]

  @doc "An admitted episode and its claimed turn, so offers have real provenance."
  @spec source!(String.t()) :: map()
  def source!(conversation_ref) do
    id = Ecto.UUID.generate()

    {:ok, started} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          destination: %{
            conversation_ref: conversation_ref,
            thread_ref: "1.000001",
            transport: "slack"
          },
          episode_id: id,
          episode_key: "collections:#{id}",
          native_input_id: "collections:#{id}",
          turn_ref: "turn:#{id}"
        })
      )

    {:ok, _session} = Custody.pin_episode(id, "policy:collections", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("collections:#{id}", 60, :work)

    %{conversation_ref: conversation_ref, episode: started.episode, turn: claim.turn}
  end

  @spec schedule!(map(), String.t(), integer(), keyword()) :: Schedule.t()
  def schedule!(source, title, index, overrides \\ []) do
    payload = %{
      "authority" => "read_only",
      "catch_up" => "latest",
      "expires_at" => nil,
      "recurrence" => %{"kind" => "daily", "time" => "13:00:00"},
      "repository" => nil,
      "task" => "Inspect #{title}.",
      "timezone" => "Etc/UTC",
      "title" => title
    }

    record = offer!(source, "schedule_offer", payload)
    id = Ecto.UUID.generate()
    at = DateTime.add(@now, index, :hour)

    Repo.insert!(%Schedule{
      id: id,
      ref: "schedule:#{id}",
      offer_record_id: record.id,
      source_episode_id: source.episode.id,
      status: Keyword.get(overrides, :status, :active),
      title: title,
      task: payload["task"],
      recurrence: payload["recurrence"],
      timezone: "Etc/UTC",
      catch_up: :latest,
      authority: :read_only,
      repository: nil,
      destination_transport: "slack",
      destination_conversation_ref: Keyword.get(overrides, :destination, source.conversation_ref),
      destination_thread_ref: "1.000001",
      confirmed_by_actor_ref: "slack:user:U123",
      confirmation_ref: "interaction:#{id}",
      confirmed_at: @now,
      next_occurrence_at: at,
      inserted_at: at,
      updated_at: at
    })
  end

  @spec behavior!(map(), atom(), map(), keyword()) :: Behavior.t()
  def behavior!(source, kind, payload, overrides) do
    record = offer!(source, "#{kind}_offer", payload)
    id = Ecto.UUID.generate()
    source_conversation_ref = Keyword.get(overrides, :source, source.conversation_ref)

    Repo.insert!(%Behavior{
      id: id,
      ref: "behavior:#{id}",
      offer_record_id: record.id,
      kind: kind,
      status: Keyword.get(overrides, :status, :active),
      workspace_ref: workspace_ref(source.conversation_ref),
      scope_kind: Keyword.get(overrides, :scope_kind, :conversation),
      scope_ref: Keyword.fetch!(overrides, :scope_ref),
      identity_key:
        payload["subject"] || payload["key"] || payload["title"] ||
          Keyword.get(overrides, :identity_key, payload["task"]),
      payload: payload,
      confirmed_by_actor_ref: "slack:user:U123",
      confirmation_ref: "interaction:#{id}",
      confirmed_at: @now,
      source_transport: "slack",
      source_conversation_ref: source_conversation_ref,
      source_thread_ref: "1.000001",
      source_message_ref: "1.000002",
      expires_at: DateTime.add(@now, 30, :day),
      inserted_at: @now,
      updated_at: @now
    })
  end

  @spec memory!(map(), String.t(), String.t(), keyword()) :: MemoryEntry.t()
  def memory!(source, subject, value, overrides \\ []) do
    scope_kind = Keyword.get(overrides, :scope_kind, :workspace)
    workspace_ref = workspace_ref(source.conversation_ref)

    scope_ref =
      Keyword.get(
        overrides,
        :scope_ref,
        if(scope_kind == :conversation, do: source.conversation_ref, else: workspace_ref)
      )

    payload = %{
      "expires_in" => "30d",
      "kind" => "entity_relationship",
      "repository" => nil,
      "scope" => Atom.to_string(scope_kind),
      "subject" => subject,
      "value" => value,
      "visibility" => "workspace"
    }

    record = offer!(source, "memory_offer", payload)
    id = Ecto.UUID.generate()

    Repo.insert!(%MemoryEntry{
      id: id,
      ref: "memory:#{id}",
      offer_record_id: record.id,
      kind: :entity_relationship,
      status: :active,
      workspace_ref: workspace_ref,
      scope_kind: scope_kind,
      scope_ref: scope_ref,
      visibility: :workspace,
      subject: subject,
      payload: payload,
      payload_fingerprint: Responder.CanonicalJSON.digest(payload),
      confirmed_by_actor_ref: "slack:user:U123",
      confirmation_ref: "interaction:#{id}",
      confirmed_at: @now,
      source_transport: "slack",
      source_conversation_ref: Keyword.get(overrides, :source, source.conversation_ref),
      source_thread_ref: "1.000001",
      source_message_ref: "1.000002",
      expires_at: DateTime.add(@now, 30, :day),
      inserted_at: @now,
      updated_at: @now
    })
  end

  defp offer!(source, kind, payload) do
    {:ok, record} =
      Records.create(Records.token(source.turn), "offer:#{Ecto.UUID.generate()}", kind, payload)

    record
  end

  defp workspace_ref("slack:" <> rest) do
    [workspace_ref | _channel] = String.split(rest, ":", parts: 2)
    "slack:#{workspace_ref}"
  end
end
