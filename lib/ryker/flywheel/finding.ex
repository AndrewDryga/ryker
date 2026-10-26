defmodule Ryker.Flywheel.Finding do
  @moduledoc "One correlated improvement proposal, its ownership and the evidence for its eventual outcome."
  use Ryker, :schema
  alias Ryker.Flywheel.Run

  schema "flywheel_findings" do
    field(:key, :string)
    belongs_to(:run, Run)

    field(:status, Ecto.Enum,
      values: [
        :proposed,
        :ready,
        :waiting_user,
        :in_progress,
        :shipped,
        :verified,
        :regressed,
        :deferred,
        :dismissed
      ],
      default: :proposed
    )

    field(:owner, Ecto.Enum, values: [:ryker, :user, :both])

    field(:kind, Ecto.Enum,
      values: [:code, :prompt, :settings, :tools, :user_action, :investigation]
    )

    field(:proposal, :map)
    field(:evidence, {:array, :map}, default: [])
    field(:history, {:array, :map}, default: [])
    field(:task_id, :string)
    field(:revisit_at, :utc_datetime_usec)
    field(:deployed_version, :string)
    field(:shipped_at, :utc_datetime_usec)
    field(:outcome, :map)
    timestamps()
  end

  @type t :: %__MODULE__{}
end
