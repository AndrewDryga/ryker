defmodule Ryker.GitHub.IssueIndexState.Changeset do
  @moduledoc false
  use Ryker, :changeset
  alias Ryker.GitHub.IssueIndexState

  @identity ~w(identity binding_ref repository_ref repository_id installation_id)a
  @mutable ~w(page backfill_complete next_attempt_at lease_ref lease_expires_at)a
  def insert(attributes) do
    %IssueIndexState{}
    |> cast(attributes, @identity ++ @mutable)
    |> validate_required(@identity)
    |> unique_constraint(:identity)
    |> check_constraint(:page, name: :github_issue_index_valid)
  end

  def update(%IssueIndexState{} = state, attributes), do: cast(state, attributes, @mutable)
end
