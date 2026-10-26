defmodule Ryker.ControlPlane.ModelUsageProjection do
  @moduledoc "Observed use of each Models setting, separate from the current model choices."
  alias Ryker.ControlPlane.{ModelUsage, SettingsSections}
  alias Ryker.CoopFleet
  alias Ryker.Repo

  @empty %{week: 0, month: 0, last_used_at: nil}

  def page(now \\ DateTime.utc_now(:microsecond)) do
    initial = %{
      categories: Map.new(SettingsSections.ladder_fields(), &{&1.name, @empty}),
      unattributed: 0
    }

    now |> ModelUsage.Query.recent() |> Repo.all() |> Enum.reduce(initial, &add/2)
  end

  defp add(row, usage) do
    field =
      if row.kind == "admission",
        do: :routing_models,
        else: CoopFleet.JobTemplates.model_field_for_policy(row.policy)

    if field do
      update_in(usage, [:categories, field], fn total ->
        %{
          week: total.week + row.week,
          month: total.month + row.month,
          last_used_at:
            Enum.max_by(
              Enum.reject([total.last_used_at, row.last_used_at], &is_nil/1),
              & &1,
              DateTime
            )
        }
      end)
    else
      %{usage | unattributed: usage.unattributed + row.month}
    end
  end
end
