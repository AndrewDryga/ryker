defmodule Ryker.Settings.Report.Changeset do
  @moduledoc "Changes to the weekly report (`Ryker.Settings.Report`)."
  @behaviour Ryker.Settings.Section.Changeset
  use Ryker, :changeset
  alias Ryker.Settings.{Report, Validation}

  @fields ~w(weekly_self_report_enabled channel_ref weekday local_time timezone)a

  @impl true
  def fields, do: @fields

  @impl true
  def update(%Report{} = report, attributes, snapshot) do
    changeset =
      report
      |> cast(attributes, @fields)
      |> validate_required([:weekly_self_report_enabled, :weekday, :local_time, :timezone])
      |> validate_format(:channel_ref, Validation.slack_id_pattern())
      |> validate_inclusion(:weekday, 1..7)
      |> validate_timezone()
      |> stamp_saved()

    cond do
      not get_field(changeset, :weekly_self_report_enabled) ->
        changeset

      is_nil(get_field(changeset, :channel_ref)) ->
        add_error(changeset, :channel_ref, "is required", validation: :required_to_enable)

      not snapshot.slack.enabled ->
        add_error(changeset, :weekly_self_report_enabled, "requires Slack",
          validation: :slack_required
        )

      true ->
        changeset
    end
  end

  defp stamp_saved(%{changes: changes} = changeset) when changes == %{}, do: changeset
  defp stamp_saved(changeset), do: put_change(changeset, :saved_at, DateTime.utc_now())

  defp validate_timezone(changeset) do
    validate_change(changeset, :timezone, fn :timezone, zone ->
      case DateTime.now(zone) do
        {:ok, _now} -> []
        {:error, _reason} -> [timezone: {"is not a known time zone", validation: :timezone}]
      end
    end)
  end
end
