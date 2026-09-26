defmodule Ryker.ControlPlane.FindingsProjection do
  @moduledoc """
  The Findings page: every recorded finding, newest first, with the evidence
  it cites and a link to the exact record on its episode's timeline when that
  record is still within the timeline's window.
  """

  import Ecto.Query

  alias Ryker.ControlPlane.{PagedRelation, Search}
  alias Ryker.Episodes.Episode
  alias Ryker.InspectionRedactor
  alias Ryker.Records.Record
  alias Ryker.Repo

  # The timeline shows an episode's newest records up to this bound, so a
  # finding older than that links to the episode rather than to an anchor the
  # page does not render.
  @timeline_record_limit 500
  @page_size 30

  @doc """
  One page of findings, newest first, with the evidence each cites, narrowed
  by a search over what each concluded, why and its scope; and how many of
  the listed findings are not explained yet.
  """
  def list(params) do
    q = Search.term(params["q"]) || ""

    findings =
      from(record in Record,
        join: episode in Episode,
        on: episode.id == record.episode_id,
        where: record.kind == "finding",
        select: {record, episode.key}
      )
      |> search(q)

    page =
      PagedRelation.read(
        findings,
        [desc: :inserted_at, desc: :id],
        "page",
        params,
        page_size: @page_size
      )

    unexplained =
      Repo.aggregate(
        from([record, _episode] in findings,
          where: fragment("?::jsonb->>'status' = 'unexplained'", record.payload)
        ),
        :count
      )

    rows = page.items

    secrets = InspectionRedactor.configured_secrets()

    refs =
      Enum.flat_map(rows, fn {record, _} -> Map.get(record.payload, "cause_evidence", []) end)

    episode_ids = Enum.map(rows, fn {record, _} -> record.episode_id end)
    visible_records = visible_episode_records(episode_ids)

    evidence =
      Repo.all(
        from(record in Record,
          where:
            record.kind == "evidence" and record.ref in ^refs and
              record.episode_id in ^episode_ids
        )
      )
      |> Map.new(&{{&1.episode_id, &1.ref}, &1})

    %{
      q: q,
      total: page.total,
      unexplained: unexplained,
      page: page.page,
      pages: page.pages,
      items: Enum.map(rows, &finding_item(&1, evidence, visible_records, secrets))
    }
  end

  defp search(query, ""), do: query

  defp search(query, q) do
    pattern = Search.contains(q)

    from([record, _episode] in query,
      where:
        fragment("?::jsonb->>'what' ILIKE ?", record.payload, ^pattern) or
          fragment("?::jsonb->>'reason' ILIKE ?", record.payload, ^pattern) or
          fragment("?::jsonb->>'scope' ILIKE ?", record.payload, ^pattern)
    )
  end

  defp visible_episode_records(episode_ids) do
    ranked =
      from(record in Record,
        where: record.episode_id in ^episode_ids,
        select: %{
          id: record.id,
          position:
            over(row_number(),
              partition_by: record.episode_id,
              order_by: [desc: record.sequence, desc: record.id]
            )
        }
      )

    Repo.all(
      from(record in subquery(ranked),
        where: record.position <= @timeline_record_limit,
        select: record.id
      )
    )
    |> MapSet.new()
  end

  defp finding_record_path(path, record_id, visible_records) do
    if MapSet.member?(visible_records, record_id),
      do: path <> "#event-record-" <> record_id,
      else: path
  end

  defp finding_item({record, episode_key}, evidence, visible_records, secrets) do
    payload = InspectionRedactor.document(record.payload, secrets)
    path = "/timeline/" <> URI.encode_www_form(episode_key)
    refs = Map.get(record.payload, "cause_evidence", [])

    %{
      id: record.id,
      at: record.inserted_at,
      what: payload["what"] || "Finding content is unavailable",
      classification: payload["status"],
      reason: payload["reason"],
      scope: payload["scope"],
      path: finding_record_path(path, record.id, visible_records),
      evidence:
        Enum.map(refs, fn ref ->
          case Map.get(evidence, {record.episode_id, ref}) do
            nil ->
              %{text: "Supporting evidence is no longer available.", path: nil, label: nil}

            item ->
              %{
                text:
                  InspectionRedactor.document(item.payload, secrets)["observation"] ||
                    "Evidence content is unavailable.",
                path: finding_record_path(path, item.id, visible_records),
                label:
                  if(MapSet.member?(visible_records, item.id),
                    do: "Show on the timeline",
                    else: "Open investigation"
                  )
              }
          end
        end)
    }
  end
end
