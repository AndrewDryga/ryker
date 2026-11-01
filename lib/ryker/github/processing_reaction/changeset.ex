defmodule Ryker.GitHub.ProcessingReaction.Changeset do
  @moduledoc false
  use Ryker, :changeset
  alias Ryker.GitHub.ProcessingReaction

  @identity ~w(binding repository_id actor_id comment_kind comment_id)a
  @state ~w(desired reaction_id uncertain blocked attempt_count next_attempt_at lease_ref lease_expires_at last_error_code last_error_detail)a

  def insert(attributes) do
    %ProcessingReaction{}
    |> cast(attributes, @identity)
    |> validate_required(@identity)
    |> check_constraint(:comment_kind, name: :github_processing_reaction_valid)
    |> unique_constraint(@identity, name: :github_processing_reaction_identity_unique)
  end

  def update(%ProcessingReaction{} = reaction, attributes),
    do: cast(reaction, attributes, @state)
end
