defmodule Ryker.Flywheel.Sources.Query do
  @moduledoc "Fixed-schema, bounded exports with a timestamp and id keyset cursor."
  use Ryker, :query

  def page(schema, fields, clock, from, until, cursor) do
    query =
      from(records in schema,
        as: :flywheel_source,
        where: field(records, ^clock) >= ^from and field(records, ^clock) < ^until,
        order_by: [asc: field(records, ^clock), asc: records.id],
        select: map(records, ^fields),
        limit: 101
      )

    after_cursor(query, clock, cursor)
  end

  defp after_cursor(queryable, _clock, nil), do: queryable

  defp after_cursor(queryable, clock, {at, id}) do
    where(
      queryable,
      [flywheel_source: r],
      field(r, ^clock) > ^at or (field(r, ^clock) == ^at and r.id > ^id)
    )
  end
end
