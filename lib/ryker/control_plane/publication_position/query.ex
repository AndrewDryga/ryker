defmodule Ryker.ControlPlane.PublicationPosition.Query do
  @moduledoc """
  Where a publication stands in a conversation: at the delivery it currently
  shows. The cursor places it by `at/1` and pages read it by `sql/1`. The two
  lived in different modules and disagreed for a published draft without a
  published time, which then stood at its review on a page and at its update
  in the cursor (2026-10-04 review).
  """

  @doc "`at/1` as SQL, for a query that imports `Ecto.Query`."
  defmacro sql(publication) do
    quote do
      fragment(
        "CASE WHEN ? = 'published' THEN COALESCE(?, ?, ?) ELSE COALESCE(?, ?, ?) END",
        unquote(publication).status,
        unquote(publication).published_at,
        unquote(publication).updated_at,
        unquote(publication).inserted_at,
        unquote(publication).reviewed_at,
        unquote(publication).updated_at,
        unquote(publication).inserted_at
      )
    end
  end

  @doc "The delivery a publication currently shows."
  def at(publication) do
    if publication.status == :published,
      do: publication.published_at || publication.updated_at || publication.inserted_at,
      else: publication.reviewed_at || publication.updated_at || publication.inserted_at
  end
end
