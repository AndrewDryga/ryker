defmodule Ryker.GitHub.IndexedIssue do
  @moduledoc "A refreshable search cache, separate from immutable triage and plan history."
  use Ryker, :schema

  schema "github_indexed_issues" do
    belongs_to(:index, Ryker.GitHub.IssueIndexState)
    field(:number, :integer)
    field(:generation, :integer, default: 1)
    field(:pending, :boolean, default: true)
    field(:event_grant, :map)
    field(:triage_pending, :boolean, default: false)
    field(:document, Ryker.CanonicalJSON.Type)
    field(:embedding, {:array, :float})
    field(:embedding_model, :string)
    field(:last_triaged_digest, :string)
    field(:next_attempt_at, :utc_datetime_usec)
    timestamps()
  end

  @type t :: %__MODULE__{}
end
