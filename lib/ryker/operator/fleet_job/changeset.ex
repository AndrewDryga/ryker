defmodule Ryker.Operator.FleetJob.Changeset do
  @moduledoc false
  use Ryker, :changeset
  alias Ryker.Operator.FleetJob

  def insert(id, episode, digest, placement, resources) do
    change(%FleetJob{},
      id: id,
      episode_id: episode,
      request_digest: digest,
      environment_ref: placement.environment,
      repository_ref: placement.repository,
      resources: resources,
      workspace_input: placement[:workspace_input] && placement.workspace_input.reference,
      workspace_input_id: placement[:workspace_input] && placement.workspace_input.id
    )
  end
end
