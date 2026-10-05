defmodule Ryker.ControlPlane.FactsProjectionTest do
  @moduledoc """
  The Facts page's search (2026-09-24): a fact is found by what it is about or
  by what it says, in any letter case, while the page still knows how many
  facts exist, so a search that misses is not mistaken for having none.
  """
  use Ryker.DataCase, async: false

  alias Ryker.ControlPlane.{FactsPage, MemoryProjection}
  alias Ryker.Fixtures.SavedEntities
  alias Ryker.Memories.MemoryEntry

  test "fact search matches what a fact is about or what it says, and still counts every fact" do
    source = SavedEntities.source!("slack:T123:C456")
    SavedEntities.memory!(source, "pay-gw", "the payments gateway")
    SavedEntities.memory!(source, "checkout-api", "deploys from acme/checkout-api")
    # The fixture's expiry is a fixed date; these facts must not age out of the test.
    Repo.update_all(MemoryEntry, set: [expires_at: DateTime.add(DateTime.utc_now(), 30, :day)])

    all = MemoryProjection.fetch(%{})
    assert all.memory_total == 2
    assert all.memories |> Enum.map(& &1.subject) |> Enum.sort() == ["checkout-api", "pay-gw"]

    by_value = MemoryProjection.fetch(%{"q" => "PAYMENTS"})
    assert Enum.map(by_value.memories, & &1.subject) == ["pay-gw"]
    assert by_value.memory_total == 2
    assert by_value.q == "PAYMENTS"

    by_subject = MemoryProjection.fetch(%{"q" => " checkout "})
    assert Enum.map(by_subject.memories, & &1.subject) == ["checkout-api"]

    miss = MemoryProjection.fetch(%{"q" => "absent"})
    assert miss.memories == []
    html = miss |> FactsPage.html() |> IO.iodata_to_binary()
    assert html =~ "No facts match &quot;absent&quot;"
    refute html =~ "No facts yet"
  end

  # The page showed the newest 100 facts and said nothing of the rest (2026-10-04 review).
  test "facts page past the first page, newest first, and a search pages its matches" do
    source = SavedEntities.source!("slack:T123:C456")
    for n <- 1..26, do: SavedEntities.memory!(source, "fact-#{n}", "value #{n}")

    Repo.update_all(MemoryEntry, set: [expires_at: DateTime.add(DateTime.utc_now(), 30, :day)])

    for {memory, n} <- Enum.with_index(Repo.all(MemoryEntry), 1),
        do: memory |> Ecto.Changeset.change(updated_at: minutes_ago(n)) |> Repo.update!()

    first = MemoryProjection.fetch(%{})
    assert %{page: 1, pages: 2, total: 26} = first.facts_page
    assert length(first.memories) == 25

    last = MemoryProjection.fetch(%{"page" => "2"})
    assert [_oldest] = last.memories
    refute hd(last.memories).ref in Enum.map(first.memories, & &1.ref)

    html = last |> FactsPage.html(%{"page" => "2"}) |> IO.iodata_to_binary()
    assert html =~ "Page 2 of 2"
    assert html =~ ~s(href="/memory?page=1")
  end

  defp minutes_ago(n), do: DateTime.add(DateTime.utc_now(), -n, :minute)
end
