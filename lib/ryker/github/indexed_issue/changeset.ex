defmodule Ryker.GitHub.IndexedIssue.Changeset do
  @moduledoc false
  use Ryker, :changeset
  alias Ryker.GitHub.IndexedIssue

  @fields ~w(generation pending event_grant triage_pending document embedding embedding_model last_triaged_digest next_attempt_at)a
  def insert(attributes) do
    %IndexedIssue{}
    |> cast(attributes, [:index_id, :number] ++ @fields)
    |> validate_required([:index_id, :number])
    |> unique_constraint([:index_id, :number])
    |> foreign_key_constraint(:index_id)
    |> check_constraint(:number, name: :github_indexed_issue_valid)
  end

  def update(%IndexedIssue{} = issue, attributes), do: cast(issue, attributes, @fields)
end
