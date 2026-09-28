defmodule Ryker.ControlPlane.FindingsProjection do
  @moduledoc """
  The Findings page: every recorded finding, newest first, with the evidence
  it cites, a link to the exact record on its episode's timeline when that
  record is still within the timeline's window, and whether a person forgot
  it or marked it explained (`Ryker.Records.Findings`).
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

  @views ~w(unexplained explained expected out_of_scope forgotten)

  @doc "The views the Findings toggle offers, in its order."
  def views, do: @views

  @doc """
  One page of findings, newest first, narrowed by a search over what each
  concluded, why and its scope, and by one view (`?view=unexplained`): how
  many each view holds, and how many of the listed findings are not
  explained yet.
  """
  def list(params) do
    q = Search.term(params["q"]) || ""
    view = if params["view"] in @views, do: params["view"]

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
        in_view(findings, view),
        [desc: :inserted_at, desc: :id],
        "page",
        params,
        page_size: @page_size
      )

    view_counts = view_counts(findings)
    secrets = InspectionRedactor.configured_secrets()

    %{
      q: q,
      view: view,
      views: view_counts,
      total: page.total,
      # A finding a person forgot or marked explained is no longer an open
      # question.
      unexplained: Map.get(view_counts, "unexplained", 0),
      page: page.page,
      pages: page.pages,
      items: Enum.map(page.items, &row(&1, secrets))
    }
  end

  @doc """
  One finding for its own page and for the question its Forget or Mark
  explained asks first: what it concluded, how Ryker classified it, whether a
  person settled it, why, its scope and the evidence it cites. `:error` when
  there is no such finding.
  """
  @spec fetch(String.t()) :: {:ok, map()} | :error
  def fetch(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {%Record{kind: "finding"} = record, episode_key} <-
           Repo.one(
             from(record in Record,
               join: episode in Episode,
               on: episode.id == record.episode_id,
               where: record.id == ^id,
               select: {record, episode.key}
             )
           ) do
      refs = Map.get(record.payload, "cause_evidence", [])

      evidence =
        Repo.all(
          from(item in Record,
            where:
              item.kind == "evidence" and item.ref in ^refs and
                item.episode_id == ^record.episode_id
          )
        )
        |> Map.new(&{{&1.episode_id, &1.ref}, &1})

      visible = visible_episode_records([record.episode_id])
      secrets = InspectionRedactor.configured_secrets()
      {:ok, finding_item({record, episode_key}, evidence, visible, secrets)}
    else
      _missing -> :error
    end
  end

  # Settled comes first: a finding a person forgot is forgotten, one they
  # marked explained is explained; an open one is what Ryker classified it.
  defp in_view(query, nil), do: query

  defp in_view(query, "forgotten"),
    do: from([record, _episode] in query, where: record.status == :dismissed)

  defp in_view(query, "explained"),
    do:
      from([record, _episode] in query,
        where:
          record.status == :answered or
            (record.status == :open and
               fragment("?::jsonb->>'status' = 'explained'", record.payload))
      )

  defp in_view(query, classification),
    do:
      from([record, _episode] in query,
        where:
          record.status == :open and
            fragment("?::jsonb->>'status' = ?", record.payload, ^classification)
      )

  defp view_counts(query) do
    from([record, _episode] in exclude(query, :select),
      group_by: [record.status, fragment("?::jsonb->>'status'", record.payload)],
      select: {record.status, fragment("?::jsonb->>'status'", record.payload), count()}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {status, classification, count}, views ->
      Map.update(views, view_of(status, classification), count, &(&1 + count))
    end)
    |> Map.delete(nil)
  end

  defp view_of(:dismissed, _classification), do: "forgotten"
  defp view_of(:answered, _classification), do: "explained"
  defp view_of(:open, classification), do: classification
  defp view_of(_superseded, _classification), do: nil

  # A row of the list: the conclusion, how it stands, its scope and when.
  defp row({record, _episode_key}, secrets) do
    payload = InspectionRedactor.document(record.payload, secrets)

    %{
      id: record.id,
      at: record.inserted_at,
      what: payload["what"] || "Finding content is unavailable",
      classification: payload["status"],
      status: record.status,
      scope: payload["scope"]
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
      status: record.status,
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
