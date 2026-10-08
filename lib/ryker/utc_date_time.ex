defmodule Ryker.UTCDateTime do
  @moduledoc """
  The one shape a persisted timestamp takes: an exact UTC `DateTime` at
  microsecond precision. A datetime in any other zone, or with an offset, is
  refused rather than converted, because the caller's clock claim is part of
  what is being recorded.
  """

  @doc """
  An exact UTC datetime with microsecond precision: `{:ok, datetime}`, or
  `:error` for anything that is not a `DateTime` in UTC.
  """
  @spec exact(term()) :: {:ok, DateTime.t()} | :error
  def exact(%DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0} = value),
    do: {:ok, to_usec(value)}

  def exact(_value), do: :error

  @doc "`value` at microsecond precision, as a `utc_datetime_usec` field keeps it."
  @spec to_usec(DateTime.t()) :: DateTime.t()
  def to_usec(%DateTime{microsecond: {microsecond, _precision}} = value),
    do: %{value | microsecond: {microsecond, 6}}

  @doc """
  A time in UTC: a zoned one shifted to UTC, a zone-less one read as UTC,
  since Ryker stores every time in UTC.
  """
  @spec to_utc(DateTime.t() | NaiveDateTime.t()) :: DateTime.t()
  def to_utc(%DateTime{} = value), do: DateTime.shift_zone!(value, "Etc/UTC")
  def to_utc(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")

  @doc "A time as ISO 8601 text; nil without one."
  @spec iso8601(DateTime.t() | nil) :: String.t() | nil
  def iso8601(nil), do: nil
  def iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)

  @doc ~s(A moment as a person reads it, on every page and card alike: "05 Oct 2026, 14:03 UTC".)
  @spec readable(DateTime.t()) :: String.t()
  def readable(%DateTime{} = at), do: Calendar.strftime(at, "%d %b %Y, %H:%M UTC")

  @doc "Whether `value` is a `DateTime` in UTC, with no offset."
  @spec utc?(term()) :: boolean()
  def utc?(%DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0}), do: true
  def utc?(_value), do: false

  @doc "An ISO 8601 string carrying an explicit zero offset, or an exact UTC datetime."
  @spec parse(term()) :: {:ok, DateTime.t()} | :error
  def parse(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _invalid -> :error
    end
  end

  def parse(value), do: exact(value)

  @doc "Whether `value` is ISO 8601 text with an explicit zero offset."
  @spec iso8601?(term()) :: boolean()
  def iso8601?(value), do: is_binary(value) and parse(value) != :error

  @doc """
  The earliest of `values`, skipping nils; nil when every one is nil.

  An aggregate the database computes comes back without a zone while a typed
  field comes back as a `DateTime`; Ryker stores every time in UTC, so a
  zone-less value is read as UTC.
  """
  @spec earliest([DateTime.t() | NaiveDateTime.t() | nil]) :: DateTime.t() | nil
  def earliest(values) when is_list(values) do
    values
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_utc/1)
    |> Enum.min(DateTime, fn -> nil end)
  end

  @doc """
  Whole seconds from `at` to `now`, never negative; nothing to age is zero.

  A timestamp stored without a zone comes back naive and is aged in naive
  time, which counts the whole-second boundaries between the two readings.
  """
  @spec age_seconds(DateTime.t(), DateTime.t() | NaiveDateTime.t() | nil) :: non_neg_integer()
  def age_seconds(_now, nil), do: 0

  def age_seconds(%DateTime{} = now, %NaiveDateTime{} = at),
    do: max(NaiveDateTime.diff(DateTime.to_naive(now), at, :second), 0)

  def age_seconds(now, at), do: max(DateTime.diff(now, at, :second), 0)
end
