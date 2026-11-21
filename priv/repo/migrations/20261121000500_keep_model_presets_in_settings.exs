defmodule Ryker.Repo.Migrations.KeepModelPresetsInSettings do
  use Ecto.Migration

  # Andrew, 2026-11-21: "how do I use presets in models selector?!" A preset could be chosen
  # only once its export sat as a file in the controller's state volume, which an install on
  # Nomad cannot reach. Presets are now saved with the rest of Settings › Models, each one the
  # output of `coop presets NAME --export-job` under its name.
  def change do
    alter table(:work_settings) do
      add(:presets, :map, null: false, default: %{})
    end

    create(
      constraint(:work_settings, :work_settings_presets_valid,
        check: "jsonb_typeof(presets) = 'object'"
      )
    )
  end
end
