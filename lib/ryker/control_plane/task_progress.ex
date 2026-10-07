defmodule Ryker.ControlPlane.TaskProgress do
  @moduledoc """
  Where a code task stands, for the top of its page: the stage ledger, pull
  request and repository its Slack card shows, read through the same
  projection (`Ryker.Slack.TaskCardProjection`), so the page and the card
  never disagree about a task.

  Andrew, 2026-09-28, of a task's page: "this is basically a task timeline?
  if yes then design it's header properly not like a bunch of random text
  that you can't digest". The header read like a conversation's, with
  "Conversation span: Not measured", "Received 0", a follow-up status and a
  worker checklist saying "To do" beside "Completed".
  """
  alias Ryker.Episodes.Episode
  alias Ryker.Records.Record
  alias Ryker.Repo
  alias Ryker.Slack.TaskCardProjection

  @doc "The task a confirmed offer started as this episode, or nil for any other request."
  @spec for_episode(Episode.t()) :: map() | nil
  def for_episode(%Episode{id: id}) do
    offer = id |> Record.Query.task_offer_confirming() |> Repo.one()

    with %Record{} <- offer,
         {:ok, %{document: %{"task_card" => task}}} <- TaskCardProjection.page(offer) do
      %{
        publication: task["publication"],
        repository: task["repository"],
        repository_url: task["repository_url"],
        stages: Enum.map(task["stages"], &draft_reason(&1, task["publication"]))
      }
    else
      _not_a_task -> nil
    end
  end

  @doc """
  A stage with the reason the card gives on its publication line: the page has
  no such line, so a failed Draft PR row says why the pull request could not
  be made.
  """
  @spec draft_reason(map(), map() | nil) :: map()
  def draft_reason(
        %{"stage" => "draft_pr", "state" => "failed", "reason" => nil} = stage,
        %{"blocked_reason" => reason}
      )
      when is_binary(reason) and reason != "",
      do: %{stage | "reason" => "PR creation failed: " <> reason}

  def draft_reason(stage, _publication), do: stage
end
