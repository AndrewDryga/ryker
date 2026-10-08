defmodule Ryker.ControlPlane.CasesProjection do
  @moduledoc """
  The Cases page: the cases Ryker kept of finished work, newest first
  (`Ryker.Memories.Cases`). A case outlives its request's history, and a later
  request about the same problem reads it as a worked example; this page is
  where a person reads one and forgets it. Nobody could delete a kept case
  before it (2026-10-04 review).
  """
  alias Ryker.ControlPlane.{PagedRelation, Search}
  alias Ryker.Memories
  alias Ryker.Repo
  alias Ryker.Slack

  @page_size 30

  @doc """
  One page of the cases Ryker still reads, newest first, narrowed by a search
  over each one's problem, cause and how it ended.
  """
  def list(params) do
    text = Search.term(params["q"]) || ""

    cases =
      if text == "",
        do: Memories.CaseRecord.Query.active(),
        else:
          Memories.CaseRecord.Query.active()
          |> Memories.CaseRecord.Query.mentioning(Search.contains(text))

    page =
      PagedRelation.read(cases, [desc: :closed_at, desc: :id], "page", params,
        page_size: @page_size
      )

    %{
      q: text,
      total: page.total,
      page: page.page,
      pages: page.pages,
      items: Enum.map(page.items, &item/1)
    }
  end

  @doc """
  One case for its own page and for the question Forget asks first, by the
  id of the work it was kept from; `:error` when there is no such case.
  """
  @spec fetch(String.t()) :: {:ok, map()} | :error
  def fetch(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, record} <- Repo.fetch(Memories.CaseRecord.Query.by_case_ref("case:" <> id)) do
      {:ok, item(record)}
    else
      _missing -> :error
    end
  end

  defp item(%Memories.CaseRecord{} = record) do
    %{
      id: record.episode_id,
      ref: record.case_ref,
      problem: record.problem,
      cause: record.cause,
      outcome: record.outcome,
      checked: record.attempted_actions,
      links: record.links,
      where: Slack.Names.destination(record.conversation_ref),
      repository: record.repository_ref,
      shadow?: record.execution_mode == :shadow,
      forgotten?: record.status == :deleted,
      at: record.closed_at
    }
  end
end
