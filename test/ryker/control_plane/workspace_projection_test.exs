defmodule Ryker.ControlPlane.WorkspaceProjectionTest do
  use Ryker.DataCase, async: true

  alias Ryker.ControlPlane.{Pages, Projection, WorkspaceProjection}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Work.{Custody, Session}

  @now ~U[2026-10-05 12:00:00.000000Z]

  # One 100-row list held the copies in use, the removed ones and the Learning page's sessions,
  # so the page counted only the removed copies that fitted: "33 removed" with 48 live on
  # 2026-10-05, the learning sessions taking the other rows (2026-10-04 review).
  test "every copy in use is listed and the removed ones are counted in full, a page at a time" do
    in_use = pinned_session!("in-use")
    removed = for n <- 1..102, do: copy!(in_use, n + 1, :discarded, n)

    copies = WorkspaceProjection.copies(%{})
    assert Enum.map(copies.current, & &1.ref) == [in_use.external_ref]
    assert %{total: 102, page: 1, pages: 5} = copies.removed
    assert length(copies.removed.items) == 25
    # Newest first: the last one removed leads.
    assert hd(copies.removed.items).ref == List.last(removed).external_ref

    page = page(%{"view" => "removed", "page" => "5"})

    assert counts(page) == ["1 copy in use", "1 ready for cleanup", "102 removed"]
    assert page |> LazyHTML.query("nav.pagination span") |> LazyHTML.text() =~ "Page 5 of 5"
    assert copies_on(page) == 2
  end

  test "learning sessions are the Learning page's, and copies are the Working copies page's" do
    in_use = pinned_session!("work-only")

    assert WorkspaceProjection.learning_sessions() == []
    assert [%{ref: ref}] = WorkspaceProjection.copies(%{}).current
    assert ref == in_use.external_ref
  end

  defp page(params) do
    %{body: body} =
      Pages.page(["working-copies"], params, %{projection: Projection.callbacks()})

    LazyHTML.from_fragment(body)
  end

  defp counts(page) do
    for count <- page |> LazyHTML.query(".kit-count") |> Enum.to_list(),
        do: count |> LazyHTML.text() |> String.split() |> Enum.join(" ")
  end

  defp copies_on(page),
    do:
      page
      |> LazyHTML.query("div.working-copies-page > .entity-list > article")
      |> Enum.count()

  # A Work request whose worker session holds a checkout of a repository.
  defp pinned_session!(suffix) do
    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: id,
        episode_key: "working-copies:#{suffix}:#{id}",
        native_input_id: "source:working-copies:#{suffix}:#{id}",
        occurred_at: @now,
        turn_ref: "turn:working-copies:#{suffix}:#{id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, session} =
             Custody.pin_episode(id, "recorded-work-policy", String.duplicate("a", 64))

    session
    |> Ecto.Changeset.change(repository_ref: "acme/checkout-api")
    |> Repo.update!()
  end

  # Another session of the same request, as a replacement leaves one: the first's row under a
  # later generation, removed `minutes` after the first.
  defp copy!(%Session{} = session, generation, status, minutes) do
    %Session{
      session
      | id: Ecto.UUID.generate(),
        generation: generation,
        external_ref: "#{session.external_ref}:#{generation}",
        cleanup_status: status,
        updated_at: DateTime.add(@now, minutes, :minute)
    }
    |> Ecto.put_meta(state: :built)
    |> Repo.insert!()
  end
end
