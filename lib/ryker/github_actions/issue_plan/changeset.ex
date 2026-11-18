defmodule Ryker.GitHubActions.IssuePlan.Changeset do
  @moduledoc false
  use Ryker, :changeset
  alias Ryker.GitHubActions.IssuePlan
  alias Ryker.GitObject

  @fields ~w(workflow_id revision parent_plan_id source_key body source_commit issue_snapshot author_ref inserted_at)a

  def insert(attributes) do
    %IssuePlan{}
    |> cast(attributes, @fields)
    |> validate_required(@fields -- [:parent_plan_id])
    |> validate_length(:body, min: 1, max: 16_000, count: :bytes)
    |> validate_change(:source_commit, fn :source_commit, commit ->
      if GitObject.id?(commit), do: [], else: [source_commit: "must name the inspected commit"]
    end)
    |> unique_constraint([:workflow_id, :revision])
    |> unique_constraint([:workflow_id, :source_key])
    |> foreign_key_constraint(:workflow_id)
    |> foreign_key_constraint(:parent_plan_id, name: :github_issue_plan_parent_owned)
    |> check_constraint(:body, name: :github_issue_plan_valid)
  end
end
