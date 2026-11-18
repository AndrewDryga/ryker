defmodule Ryker.GitHubActions.IssueTriageRead do
  @moduledoc "Frozen evidence that this triage request inspected a related issue."
  use Ryker, :schema

  schema "github_issue_triage_reads" do
    belongs_to(:request, Ryker.GitHubActions.IssueRequest)
    field(:number, :integer)
    field(:fingerprint, :string)
    field(:document, Ryker.CanonicalJSON.Type)
    field(:inserted_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
