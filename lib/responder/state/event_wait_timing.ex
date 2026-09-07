defmodule Responder.State.EventWaitTiming do
  @moduledoc false

  @maximum_delay_us 365 * 24 * 60 * 60 * 1_000_000
  @duration ~r/\A\+?(?:[0-9]+(?:\.[0-9]*)?[hms]|\.[0-9]+[hms])+\z/
  @component ~r/([0-9]+(?:\.[0-9]*)?|\.[0-9]+)([hms])/
  @unit_us %{"h" => 3_600_000_000, "m" => 60_000_000, "s" => 1_000_000}

  @spec delay_microseconds(term()) :: {:ok, pos_integer()} | {:error, :delay}
  def delay_microseconds(value) when is_binary(value) and byte_size(value) in 1..64 do
    if Regex.match?(@duration, value) do
      @component
      |> Regex.scan(value)
      |> Enum.reduce_while({:ok, 0}, &add_component/2)
      |> positive_delay()
    else
      {:error, :delay}
    end
  end

  def delay_microseconds(_value), do: {:error, :delay}

  defp add_component([_component, number, unit], {:ok, total}) do
    [whole | fractional] = String.split(number, ".")
    fraction = List.first(fractional) || ""
    denominator = Integer.pow(10, byte_size(fraction))
    numerator = String.to_integer(whole <> fraction) * Map.fetch!(@unit_us, unit)
    microseconds = div(numerator, denominator)

    if rem(numerator, denominator) == 0 and total + microseconds <= @maximum_delay_us,
      do: {:cont, {:ok, total + microseconds}},
      else: {:halt, {:error, :delay}}
  end

  defp positive_delay({:ok, value}) when value > 0, do: {:ok, value}
  defp positive_delay(_value), do: {:error, :delay}

  @spec due_at(map(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, :delay | :at}
  def due_at(%{"type" => "after", "delay" => delay}, %DateTime{} = inserted_at) do
    with {:ok, microseconds} <- delay_microseconds(delay) do
      {:ok, DateTime.add(inserted_at, microseconds, :microsecond)}
    end
  rescue
    ArgumentError -> {:error, :delay}
  end

  def due_at(%{"type" => "at", "at" => value}, %DateTime{}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _invalid -> {:error, :at}
    end
  end

  def due_at(_trigger, _inserted_at), do: {:error, :at}
end
