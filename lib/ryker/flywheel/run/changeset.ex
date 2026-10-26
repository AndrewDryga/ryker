defmodule Ryker.Flywheel.Run.Changeset do
  @moduledoc "Creates a run and records its lease and coverage transitions."
  use Ryker, :changeset
  alias Ryker.Flywheel.Run
  alias Ryker.Lease

  @fields [
    :request_ref,
    :mode,
    :starts_at,
    :ends_at,
    :progress,
    :policy,
    :lease_ref,
    :lease_expires_at
  ]

  def insert(attributes) do
    %Run{}
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> validate_length(:request_ref, max: 200, count: :codepoints)
    |> unique_constraint(:request_ref)
    |> check_constraint(:starts_at, name: :flywheel_run_valid)
  end

  def checkpoint(%Run{} = run, attributes) do
    run
    |> Lease.Changeset.renew(Map.fetch!(attributes, :lease_expires_at))
    |> cast(attributes, [:progress, :status, :lease_ref])
  end
end
