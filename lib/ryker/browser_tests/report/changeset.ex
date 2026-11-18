defmodule Ryker.BrowserTests.Report.Changeset do
  @moduledoc false
  use Ryker, :changeset
  alias Ryker.BrowserTests.Report

  @fields ~w(turn_id fingerprint source document)a
  def insert(attributes) do
    %Report{}
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> foreign_key_constraint(:turn_id)
    |> unique_constraint([:turn_id, :fingerprint])
    |> check_constraint(:document, name: :browser_test_report_valid)
  end
end
