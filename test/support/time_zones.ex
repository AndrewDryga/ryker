defmodule Ryker.TestSupport.TimeZones do
  @moduledoc """
  A time zone database whose clock changes a test chooses, so a test of local
  times does not move with the IANA data the release reads. It knows three
  zones:

    * `Etc/UTC`;
    * `Test/Plus2`, two hours ahead of UTC all year;
    * `Test/Mountain`, seven hours behind UTC, six in summer: in 2026 the
      clock jumps from 02:00 to 03:00 on 8 March (09:00 UTC) and falls back
      from 02:00 to 01:00 on 1 November (08:00 UTC), as in the Rockies.
  """

  @behaviour Calendar.TimeZoneDatabase

  @utc %{utc_offset: 0, std_offset: 0, zone_abbr: "UTC"}
  @plus2 %{utc_offset: 7_200, std_offset: 0, zone_abbr: "TP2"}
  @standard %{utc_offset: -25_200, std_offset: 0, zone_abbr: "MST"}
  @summer %{utc_offset: -25_200, std_offset: 3_600, zone_abbr: "MDT"}

  @spring_utc ~N[2026-03-08 09:00:00]
  @autumn_utc ~N[2026-11-01 08:00:00]
  @spring_wall {~N[2026-03-08 02:00:00], ~N[2026-03-08 03:00:00]}
  @autumn_wall {~N[2026-11-01 01:00:00], ~N[2026-11-01 02:00:00]}

  @impl true
  def time_zone_period_from_utc_iso_days(_iso_days, "Etc/UTC"), do: {:ok, @utc}
  def time_zone_period_from_utc_iso_days(_iso_days, "Test/Plus2"), do: {:ok, @plus2}

  def time_zone_period_from_utc_iso_days(iso_days, "Test/Mountain") do
    utc = naive(iso_days)

    if NaiveDateTime.compare(utc, @spring_utc) != :lt and
         NaiveDateTime.compare(utc, @autumn_utc) == :lt,
       do: {:ok, @summer},
       else: {:ok, @standard}
  end

  def time_zone_period_from_utc_iso_days(_iso_days, _zone), do: {:error, :time_zone_not_found}

  @impl true
  def time_zone_periods_from_wall_datetime(_wall, "Etc/UTC"), do: {:ok, @utc}
  def time_zone_periods_from_wall_datetime(_wall, "Test/Plus2"), do: {:ok, @plus2}

  def time_zone_periods_from_wall_datetime(wall, "Test/Mountain") do
    {gap_from, gap_to} = @spring_wall
    {repeat_from, repeat_to} = @autumn_wall

    cond do
      before?(wall, gap_from) -> {:ok, @standard}
      before?(wall, gap_to) -> {:gap, {@standard, gap_from}, {@summer, gap_to}}
      before?(wall, repeat_from) -> {:ok, @summer}
      before?(wall, repeat_to) -> {:ambiguous, @summer, @standard}
      true -> {:ok, @standard}
    end
  end

  def time_zone_periods_from_wall_datetime(_wall, _zone), do: {:error, :time_zone_not_found}

  defp before?(wall, limit), do: NaiveDateTime.compare(wall, limit) == :lt

  defp naive(iso_days) do
    {year, month, day, hour, minute, second, microsecond} =
      Calendar.ISO.naive_datetime_from_iso_days(iso_days)

    NaiveDateTime.new!(year, month, day, hour, minute, second, microsecond)
  end
end
