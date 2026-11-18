defmodule Ryker.GitHubActions.IssueTriageRead.Changeset do
  @moduledoc false
  use Ryker, :changeset
  alias Ryker.GitHubActions.IssueTriageRead
  @fields ~w(request_id number fingerprint document inserted_at)a
  def insert(attributes) do
    %IssueTriageRead{}
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> foreign_key_constraint(:request_id)
    |> unique_constraint([:request_id, :fingerprint])
    |> check_constraint(:document, name: :github_issue_triage_read_valid)
  end
end
