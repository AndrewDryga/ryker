defmodule Ryker.Continuity.ConversationSummaryDraft.Query do
  @moduledoc "Summaries a Work turn staged before its answer is accepted, for every read of `conversation_summary_drafts`."
  import Ecto.Query
  alias Ryker.Continuity.ConversationSummaryDraft
  alias Ryker.Episodes.Episode

  def all, do: from(drafts in ConversationSummaryDraft, as: :conversation_summary_drafts)

  def by_turn_id(queryable \\ all(), turn_id),
    do: where(queryable, [conversation_summary_drafts: d], d.turn_id == ^turn_id)

  def by_episode_id(queryable, episode_id),
    do: where(queryable, [conversation_summary_drafts: d], d.episode_id == ^episode_id)

  def by_ids(queryable \\ all(), ids),
    do: where(queryable, [conversation_summary_drafts: d], d.id in ^ids)

  @doc "Drafts of the episodes that answer in Slack conversation `conversation_ref`."
  def by_slack_conversation_ref(conversation_ref) do
    all()
    |> join(:inner, [conversation_summary_drafts: d], e in Episode,
      on: e.id == d.episode_id,
      as: :episode_kernel_episodes
    )
    |> where(
      [episode_kernel_episodes: e],
      e.destination_transport == "slack" and e.destination_conversation_ref == ^conversation_ref
    )
  end

  def select_ids(queryable), do: select(queryable, [conversation_summary_drafts: d], d.id)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
