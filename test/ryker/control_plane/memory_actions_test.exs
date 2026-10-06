defmodule Ryker.ControlPlane.MemoryActionsTest do
  use Ryker.DataCase, async: true
  import Plug.Test
  alias Ryker.ControlPlane.{MemoryProjection, Paths, Projection, Router}
  alias Ryker.Fixtures.{ControlPlaneOptions, SavedEntities}
  alias Ryker.Memories.MemoryReviewItem

  # The Memory page lists facts a page at a time and the oldest hundred
  # reviews, but Forget and every review action looked their item up in what
  # the page showed and answered 404 for any other (2026-10-04 review).
  test "a fact on a later page can still be forgotten" do
    source = SavedEntities.source!("slack:TMEMORYACTIONS:C456")
    facts = for n <- 1..26, do: SavedEntities.memory!(source, "service #{n}", "owner #{n}")

    listed = MapSet.new(MemoryProjection.fetch(%{}).memories, & &1.ref)
    assert [older] = Enum.reject(facts, &MapSet.member?(listed, &1.ref))

    response = get("/actions/memory/#{Paths.id("memory", older.ref)}/forget")
    assert response.status == 200
    assert response.resp_body =~ "Forget #{older.subject}?"
  end

  test "a review past the first hundred can still be settled" do
    source = SavedEntities.source!("slack:TMEMORYREVIEWS:C456")
    fact = SavedEntities.memory!(source, "checkout-api", "owned by payments")
    first = DateTime.add(DateTime.utc_now(), -3_600, :second)

    reviews =
      for index <- 1..101 do
        id = Ecto.UUID.generate()

        Repo.insert!(%MemoryReviewItem{
          entry_refs: [fact.ref],
          id: id,
          inserted_at: DateTime.add(first, index, :second),
          kind: :stale,
          reason: "Review #{index}",
          ref: "memory-review:later:#{id}",
          source_digest: Ryker.CanonicalJSON.digest(%{"review" => index}),
          status: :pending,
          updated_at: DateTime.add(first, index, :second),
          workspace_ref: "slack:TMEMORYREVIEWS"
        })
      end

    listed = MapSet.new(MemoryProjection.fetch(%{}).reviews, & &1["review_ref"])
    assert [later] = Enum.reject(reviews, &MapSet.member?(listed, &1.ref))

    response = get("/actions/memory-review/#{later.ref}/keep")
    assert response.status == 200
  end

  defp get(path) do
    options = Map.put(ControlPlaneOptions.options(self()), :projection, Projection.callbacks())

    conn(:get, path)
    |> Map.put(:host, "localhost")
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> Router.call(Router.init(options))
  end
end
