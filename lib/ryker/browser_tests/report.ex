defmodule Ryker.BrowserTests.Report do
  @moduledoc "Immutable browser observations reported by one task turn."
  use Ryker, :schema

  schema "browser_test_reports" do
    belongs_to(:turn, Ryker.Work.Turn)
    field(:fingerprint, :string)
    field(:source, Ryker.CanonicalJSON.Type)
    field(:document, Ryker.CanonicalJSON.Type)
    timestamps(updated_at: false)
  end

  @type t :: %__MODULE__{}
end
