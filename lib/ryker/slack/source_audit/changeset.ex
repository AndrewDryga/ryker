defmodule Ryker.Slack.SourceAudit.Changeset do
  @moduledoc false

  import Ecto.Changeset
  alias Ryker.Slack.SourceAudit

  @fields [
    :authorized,
    :capability,
    :channel_ref,
    :complete,
    :episode_id,
    :id,
    :range_fingerprint,
    :request_fingerprint,
    :requester_ref,
    :result_count,
    :source_fingerprint,
    :tool,
    :turn_id,
    :workspace_ref
  ]

  @spec insert(map()) :: Ecto.Changeset.t()
  def insert(attributes) do
    %SourceAudit{}
    |> cast(attributes, @fields)
    |> validate_required(@fields -- [:channel_ref, :source_fingerprint])
    |> foreign_key_constraint(:episode_id)
    |> foreign_key_constraint(:turn_id)
  end
end
