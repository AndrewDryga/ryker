defmodule Ryker.ControlPlane.PublicationPositionTest do
  use Ryker.DataCase, async: true
  import Ecto.Query
  require Ryker.ControlPlane.PublicationPositionQuery
  alias Ryker.ControlPlane.PublicationPositionQuery

  @inserted ~N[2026-10-01 09:00:00.000000]
  @reviewed ~N[2026-10-01 09:05:00.000000]
  @updated ~N[2026-10-01 09:10:00.000000]
  @published ~N[2026-10-01 09:20:00.000000]

  # A conversation's cursor places a publication by the Elixir rule and its pages read it by the
  # SQL rule. A published draft without a published time stood at its update in one and at its
  # review in the other, so a page could repeat or skip it (2026-10-04 review).
  test "a publication stands at the same moment in the page and in the cursor" do
    for {status, published_at, reviewed_at} <- [
          {:published, @published, @reviewed},
          {:published, nil, @reviewed},
          {:published, nil, nil},
          {:reviewed, nil, @reviewed},
          {:review_pending, nil, nil}
        ] do
      row = %{
        status: status,
        published_at: published_at,
        reviewed_at: reviewed_at,
        updated_at: @updated,
        inserted_at: @inserted
      }

      sql =
        Repo.one(
          from(
            p in fragment(
              "SELECT ?::text AS status, ?::timestamp AS published_at, ?::timestamp AS reviewed_at, ?::timestamp AS updated_at, ?::timestamp AS inserted_at",
              ^Atom.to_string(status),
              ^published_at,
              ^reviewed_at,
              ^@updated,
              ^@inserted
            ),
            select: PublicationPositionQuery.sql(p)
          )
        )

      assert sql == PublicationPositionQuery.at(row), inspect(row)
    end
  end
end
