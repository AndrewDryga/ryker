defmodule Ryker.UTCDateTime do
  @moduledoc """
  The one shape a persisted timestamp takes: an exact UTC `DateTime` at
  microsecond precision. A datetime in any other zone, or with an offset, is
  refused rather than converted, because the caller's clock claim is part of
  what is being recorded.
  """

  @spec exact(term()) :: {:ok, DateTime.t()} | :error
  def exact(%DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0} = value) do
    {microsecond, _precision} = value.microsecond
    {:ok, %{value | microsecond: {microsecond, 6}}}
  end

  def exact(_value), do: :error

  @doc "An ISO 8601 string carrying an explicit zero offset, or an exact UTC datetime."
  @spec parse(term()) :: {:ok, DateTime.t()} | :error
  def parse(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _invalid -> :error
    end
  end

  def parse(value), do: exact(value)
end
