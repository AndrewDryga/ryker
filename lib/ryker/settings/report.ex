defmodule Ryker.Settings.Report do
  @moduledoc "Weekly self report on the existing schedule boundary; opt-in."
  use Ecto.Schema
  import Ecto.Changeset
  alias Ryker.Settings.Validation

  @primary_key {:id, :string, autogenerate: false}
  @fields ~w(weekly_self_report_enabled channel_ref weekday local_time timezone)a

  schema "report_settings" do
    field(:weekly_self_report_enabled, :boolean, default: false)
    field(:channel_ref, :string)
    field(:weekday, :integer, default: 1)
    field(:local_time, :time, default: ~T[09:00:00])
    field(:timezone, :string, default: "Etc/UTC")
  end

  def fields, do: @fields

  def changeset(current, attributes, snapshot) do
    changeset =
      current
      |> cast(attributes, @fields)
      |> validate_required([:weekly_self_report_enabled, :weekday, :local_time, :timezone])
      |> validate_format(:channel_ref, Validation.slack_id_pattern())
      |> validate_inclusion(:weekday, 1..7)
      |> validate_timezone()

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

  defp validate_timezone(changeset) do
    validate_change(changeset, :timezone, fn :timezone, zone ->
      case DateTime.now(zone) do
        {:ok, _now} -> []
        {:error, _reason} -> [timezone: {"is not a known time zone", validation: :timezone}]
      end
    end)
  end
end
