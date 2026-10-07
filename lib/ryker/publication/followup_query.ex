defmodule Ryker.Publication.FollowupQuery do
  @moduledoc "How each published pull request is followed up, for every read of `episode_publication_followups`."
  import Ecto.Query
  alias Ryker.Episodes.Episode
  alias Ryker.Publication.{Followup, Publication}

  def all, do: from(followups in Followup, as: :episode_publication_followups)

  @doc """
  The live pull requests opened between `from` and `to`, and every one still
  open, newest first, each with its publication and conversation. A pull
  request is opened when its publication first goes out, which is when its
  follow-up starts; a follow-up rearmed later keeps that time.
  """
  def pull_requests(from, to) do
    from(followup in all(),
      join: publication in Publication,
      on: publication.id == followup.publication_id,
      join: episode in Episode,
      on: episode.id == followup.episode_id and episode.execution_mode == :live,
      where:
        (followup.inserted_at >= ^from and followup.inserted_at < ^to) or
          followup.pr_state in [:open, :stale],
      order_by: [desc: followup.inserted_at, desc: followup.id],
      select: %{
        state: followup.pr_state,
        opened_at: followup.inserted_at,
        merged_at: followup.merged_at,
        number: publication.pull_request_number,
        url: publication.pull_request_url,
        title: publication.title,
        repository: publication.github_repository,
        conversation: episode.destination_conversation_ref
      }
    )
  end
end
