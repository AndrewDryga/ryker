defmodule Ryker.ControlPlane.MemoryProjection do
  @moduledoc """
  The Facts page's read model: the operational memory people confirmed and the
  pending reviews of it. Expiry is applied at read time; every retained text is
  redacted the way the rest of the control plane redacts it.

  The page lists the newest hundred facts and the first hundred reviews, and
  search finds the rest; an action finds its fact or review by reference
  (`fact/1`, `review/1`), wherever it falls.
  """

  import Ecto.Query

  alias Ryker.InspectionRedactor
  alias Ryker.Memories
  alias Ryker.Memories.MemoryEntry
  alias Ryker.Repo

  @doc "The query keys the Facts page reads."
  def query_keys, do: ["q"]

  @doc "Every collection the Facts page shows, expiry applied at read time."
  def fetch(params \\ %{}) do
    secrets = InspectionRedactor.configured_secrets()
    search = search_text(params["q"])

    %{
      q: search,
      memory_total: Repo.aggregate(active(), :count),
      memories:
        Repo.all(
          from(memory in search(fact_rows(), search),
            order_by: [desc: memory.updated_at, desc: memory.id],
            limit: 100
          )
        )
        |> Enum.map(&redact(&1, secrets)),
      reviews: Memories.pending_reviews(100)
    }
  end

  @doc "One active fact as the page shows it, by reference, or nil."
  def fact(ref) when is_binary(ref) do
    case Repo.one(from(memory in fact_rows(), where: memory.ref == ^ref)) do
      nil -> nil
      fact -> redact(fact, InspectionRedactor.configured_secrets())
    end
  end

  @doc "One pending review as the page shows it, by reference, or nil."
  def review(review_ref) when is_binary(review_ref), do: Memories.pending_review(review_ref)

  defp active do
    from(memory in MemoryEntry,
      where:
        memory.status == :active and
          (is_nil(memory.expires_at) or memory.expires_at > fragment("clock_timestamp()"))
    )
  end

  defp fact_rows do
    from(memory in active(),
      select: %{
        kind: memory.kind,
        ref: memory.ref,
        scope: memory.scope_kind,
        scope_ref: memory.scope_ref,
        applicability: fragment("?::jsonb->>'applicability'", memory.payload),
        value: fragment("?::jsonb->>'value'", memory.payload),
        status: memory.status,
        subject: memory.subject,
        recall_count: memory.recall_count,
        confirmed_at: memory.confirmed_at
      }
    )
  end

  # A memory is a person's own words, confirmed as a fact; they are redacted
  # here exactly as the channel page and the behavior library redact them.
  defp redact(fact, secrets), do: redact_fields(fact, [:applicability, :subject, :value], secrets)

  defp search(query, ""), do: query

  defp search(query, text),
    do:
      from(memory in query,
        where:
          fragment(
            "position(lower(?) in lower(concat_ws(' ', ?, ?::jsonb->>'value', ?::jsonb->>'applicability'))) > 0",
            ^text,
            memory.subject,
            memory.payload,
            memory.payload
          )
      )

  defp search_text(value) when is_binary(value), do: String.slice(String.trim(value), 0, 200)
  defp search_text(_value), do: ""

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
