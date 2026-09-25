defmodule Ryker.Settings.ReportTest do
  # The weekly self report is the one setting that posts on its own, unattended,
  # every week. Every refusal here exists so an installation cannot save a
  # recurrence that nothing can deliver: no channel, no Slack connection, a day
  # outside the week or a zone the release cannot resolve.
  use Ryker.DataCase, async: false

  alias Ryker.Settings

  @actor "control-plane:local"

  setup do
    {:ok, snapshot} = Settings.initialize(@actor)
    %{revision: snapshot.installation.revision}
  end

  test "a new installation starts with the weekly report off and nowhere to post it" do
    assert {:ok, snapshot} = Settings.fetch()
    refute snapshot.report.weekly_self_report_enabled
    assert snapshot.report.channel_ref == nil
    assert snapshot.report.weekday == 1
    assert snapshot.report.local_time == ~T[09:00:00]
    assert snapshot.report.timezone == "Etc/UTC"
  end

  test "the weekly report cannot be enabled without a channel to post it in", %{
    revision: revision
  } do
    assert {:error, {:invalid_settings, errors}} =
             Settings.save_report(%{weekly_self_report_enabled: true}, revision, @actor)

    assert {:channel_ref, :required_to_enable} in errors
    refute Settings.fetch!().report.weekly_self_report_enabled
  end

  test "the weekly report cannot be enabled while Slack is disconnected", %{revision: revision} do
    # A report enabled against a disconnected workspace looks scheduled and
    # posts nothing; the save is refused instead of quietly becoming inert.
    assert {:error, {:invalid_settings, errors}} =
             Settings.save_report(
               %{weekly_self_report_enabled: true, channel_ref: "C0123456789"},
               revision,
               @actor
             )

    assert {:weekly_self_report_enabled, :slack_required} in errors
    refute Settings.fetch!().report.weekly_self_report_enabled
  end

  test "a connected workspace lets the report be scheduled on a chosen day and local time", %{
    revision: revision
  } do
    revision = connect_slack!(revision)

    assert {:ok, saved} =
             Settings.save_report(
               %{
                 weekly_self_report_enabled: true,
                 channel_ref: "C0123456789",
                 weekday: 5,
                 local_time: ~T[16:30:00],
                 timezone: "Etc/UTC"
               },
               revision,
               @actor
             )

    assert saved.report.weekly_self_report_enabled
    assert saved.report.channel_ref == "C0123456789"
    assert saved.report.weekday == 5
    assert saved.report.local_time == ~T[16:30:00]
    assert saved.installation.revision == revision + 1
  end

  test "a day outside the week is refused rather than wrapped into one", %{revision: revision} do
    revision = connect_slack!(revision)

    for weekday <- [0, 8] do
      assert {:error, {:invalid_settings, errors}} =
               Settings.save_report(
                 %{
                   weekly_self_report_enabled: true,
                   channel_ref: "C0123456789",
                   weekday: weekday
                 },
                 revision,
                 @actor
               )

      assert {:weekday, :inclusion} in errors
    end

    assert Settings.fetch!().report.weekday == 1
  end

  test "a time zone the release cannot resolve is refused before the post depends on it", %{
    revision: revision
  } do
    # The post follows a local time, so a zone nobody can resolve is a weekly
    # send nothing can compute. Note for whoever changes this: the release ships
    # Elixir's UTC-only time zone database, so Etc/UTC is the only zone this
    # validation accepts today — the Settings form's "such as Europe/Berlin"
    # help text is refused by this very check.
    revision = connect_slack!(revision)

    assert DateTime.now("Europe/Berlin") == {:error, :utc_only_time_zone_database}

    for zone <- ["Mars/Olympus", "Europe/Berlin"] do
      assert {:error, {:invalid_settings, errors}} =
               Settings.save_report(
                 %{
                   weekly_self_report_enabled: true,
                   channel_ref: "C0123456789",
                   timezone: zone
                 },
                 revision,
                 @actor
               )

      assert {:timezone, :timezone} in errors
    end

    assert Settings.fetch!().report.timezone == "Etc/UTC"
  end

  test "a channel that is not a Slack ID is refused rather than posted to", %{revision: revision} do
    revision = connect_slack!(revision)

    assert {:error, {:invalid_settings, errors}} =
             Settings.save_report(
               %{weekly_self_report_enabled: true, channel_ref: "#engineering"},
               revision,
               @actor
             )

    assert {:channel_ref, :format} in errors
    assert Settings.fetch!().report.channel_ref == nil
  end

  test "a report left off may still carry the schedule it would use once enabled", %{
    revision: revision
  } do
    # Turning it off must not force an operator to throw away the day and time
    # they picked, and must not demand a channel for a post nobody sends.
    assert {:ok, saved} =
             Settings.save_report(
               %{weekly_self_report_enabled: false, weekday: 3, local_time: ~T[07:15:00]},
               revision,
               @actor
             )

    refute saved.report.weekly_self_report_enabled
    assert saved.report.channel_ref == nil
    assert saved.report.weekday == 3
    assert saved.report.local_time == ~T[07:15:00]
  end

  test "the report cannot be blanked into a recurrence with no day, time or zone", %{
    revision: revision
  } do
    assert {:error, {:invalid_settings, errors}} =
             Settings.save_report(
               %{weekday: nil, local_time: nil, timezone: nil},
               revision,
               @actor
             )

    assert {:weekday, :required} in errors
    assert {:local_time, :required} in errors
    assert {:timezone, :required} in errors
  end

  test "a field the report does not own is refused by name", %{revision: revision} do
    assert Settings.save_report(%{"channel" => "C0123456789"}, revision, @actor) ==
             {:error, {:invalid_settings, [{"channel", :unknown}]}}
  end

  defp connect_slack!(revision) do
    {:ok, _repository} = Settings.put_repository(%{ref: "ryker"}, revision, @actor)

    {:ok, saved} =
      Settings.save_slack(
        %{
          enabled: true,
          workspace_ref: "T0123456789",
          bot_ref: "A0123456789",
          bot_user_ref: "U0123456789",
          operators: ["U1111111111"]
        },
        revision + 1,
        @actor
      )

    saved.installation.revision
  end
end
