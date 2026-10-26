defmodule Ryker.Flywheel.Receipt.Query do
  @moduledoc "Analyzed versions of source records."
  use Ryker, :query
  alias Ryker.Flywheel.Receipt

  def all, do: from(receipts in Receipt, as: :flywheel_receipts)

  def by_identity(queryable \\ all(), source, ref, version) do
    where(
      queryable,
      [flywheel_receipts: r],
      r.source == ^source and r.ref == ^ref and r.version == ^version
    )
  end
end
