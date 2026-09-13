defmodule Ryker.ControlPlane.MemoryProjection do
  @moduledoc """
  The Memory page: learned conversation context, active behaviours, operational
  memory, pending memory reviews and live schedules. Expiry is applied at read
  time; every retained text is redacted the way the rest of the control plane
  redacts it.
  """

  import Ecto.Query

  alias Ryker.ControlPlane.{ConversationMemory, InspectionRedactor}
  alias Ryker.Repo
  alias Ryker.State.{Behavior, Memories, MemoryEntry, Schedule}

  def fetch(params \\ %{}) do
    secrets = InspectionRedactor.configured_secrets()

    %{
      conversation_memory: ConversationMemory.project(params),
      behaviors:
        Repo.all(
          from(behavior in Behavior,
            where:
              behavior.status in [:active, :disabled] and
                (is_nil(behavior.expires_at) or
                   behavior.expires_at > fragment("clock_timestamp()")),
            order_by: [desc: behavior.updated_at, desc: behavior.id],
            limit: 500,
            select: %{
              kind: behavior.kind,
              ref: behavior.ref,
              status: behavior.status,
              subject:
                fragment(
                  "COALESCE(?::jsonb->>'title', ?::jsonb->>'subject', ?::jsonb->>'key', ?::jsonb->>'task', ?)",
                  behavior.payload,
                  behavior.payload,
                  behavior.payload,
                  behavior.payload,
                  behavior.identity_key
                )
            }
          )
        )
        |> Enum.map(&redact_fields(&1, [:subject], secrets)),
      # A memory is a person's own words, confirmed as a fact; they are redacted
      # here exactly as the channel page and the behavior library redact them.
      memories:
        Repo.all(
          from(memory in MemoryEntry,
            where:
              memory.status == :active and
                (is_nil(memory.expires_at) or memory.expires_at > fragment("clock_timestamp()")),
            order_by: [desc: memory.updated_at, desc: memory.id],
            limit: 100,
            select: %{
              kind: memory.kind,
              ref: memory.ref,
              scope: memory.scope_kind,
              applicability: fragment("?::jsonb->>'applicability'", memory.payload),
              value: fragment("?::jsonb->>'value'", memory.payload),
              status: memory.status,
              subject: memory.subject
            }
          )
        )
        |> Enum.map(&redact_fields(&1, [:applicability, :subject, :value], secrets)),
      reviews: Memories.pending_reviews(100),
      schedules:
        Repo.all(
          from(schedule in Schedule,
            where:
              schedule.status in [:active, :paused] and
                (is_nil(schedule.expires_at) or
                   schedule.expires_at > fragment("clock_timestamp()")),
            order_by: [asc: schedule.next_occurrence_at, asc: schedule.id],
            limit: 100,
            select: %{
              next_occurrence_at: schedule.next_occurrence_at,
              ref: schedule.ref,
              status: schedule.status,
              title: schedule.title
            }
          )
        )
    }
  end

  defp redact_fields(row, keys, secrets) do
    Enum.reduce(keys, row, fn key, row ->
      case Map.fetch!(row, key) do
        text when is_binary(text) ->
          Map.put(row, key, InspectionRedactor.artifact(text, secrets: secrets).text)

        _absent ->
          row
      end
    end)
  end
end
