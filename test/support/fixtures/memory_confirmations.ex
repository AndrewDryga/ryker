defmodule Ryker.Fixtures.MemoryConfirmations do
  @moduledoc "Host confirmation custody around harvested statement wording, not a model-memory decision."
  import Ecto.Query
  alias Ryker.Fixtures.Personalization
  alias Ryker.Fixtures.SavedEntities
  alias Ryker.Inspectors
  alias Ryker.Memories
  alias Ryker.Memories.MemoryEntry
  alias Ryker.Repo

  def current! do
    corpus =
      "testdata/learning/retained-people-about-themselves.json" |> File.read!() |> Jason.decode!()

    [first, second | _] = Jason.decode!(corpus["recorded_result"]["result"])["people"]
    workspace = "TMEMORYCONFIRM#{System.unique_integer([:positive])}"
    source = SavedEntities.source!("slack:#{workspace}:C1")
    memory = SavedEntities.memory!(source, first["fact"], first["fact"])
    old = Repo.now!() |> DateTime.add(-120, :second)
    memory = memory |> Ecto.Changeset.change(inserted_at: old, updated_at: old) |> Repo.update!()
    workspace_ref = "slack:" <> workspace
    {:ok, %{created: 1}} = Memories.Reviews.refresh_reviews(workspace_ref, 60)
    [review] = Inspectors.memory_reviews(workspace_ref)

    %{
      memory: memory,
      original: %{"subject" => first["fact"], "value" => first["fact"]},
      replacement: %{"subject" => second["fact"], "value" => second["fact"]},
      review_ref: review["review_ref"],
      workspace_ref: workspace_ref,
      source: source
    }
  end

  def edit!(context, replacement) do
    {:ok, result} =
      Memories.resolve_review(
        context.review_ref,
        :edit,
        "slack:user:U123",
        context.workspace_ref,
        replacement
      )

    result
  end

  def fetch!(context), do: Repo.get!(MemoryEntry, context.memory.id)

  def cleanup!(context) do
    workspace = context.workspace_ref

    Repo.delete_all(
      from(review in Memories.MemoryReviewItem, where: review.workspace_ref == ^workspace)
    )

    Repo.delete_all(MemoryEntry.Query.by_workspace(workspace))
    Personalization.cleanup!(context.source)
  end
end
