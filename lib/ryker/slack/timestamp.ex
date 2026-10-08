defmodule Ryker.Slack.Timestamp do
  @moduledoc """
  A Slack message timestamp (`ts`): whole seconds since 1970, a dot, and up to
  six digits of the second, as in "1712345678.123456". Slack names a message
  by it within its channel, so it is the message's id and the moment it was
  posted.
  """

  @pattern ~r/\A([0-9]{10,})\.([0-9]{1,6})\z/

  @doc "Whether `value` is a Slack message timestamp."
  @spec valid?(term()) :: boolean()
  def valid?(value), do: is_binary(value) and Regex.match?(@pattern, value)

  @doc "The pattern a Slack message timestamp matches, for a changeset's format check."
  @spec pattern() :: Regex.t()
  def pattern, do: @pattern

  @doc "The moment a Slack message timestamp names: `{:ok, datetime}`, or `:error`."
  @spec to_datetime(term()) :: {:ok, DateTime.t()} | :error
  def to_datetime(value) when is_binary(value) do
    case Regex.run(@pattern, value) do
      [_whole, seconds, fraction] ->
        microseconds =
          String.to_integer(seconds) * 1_000_000 +
            String.to_integer(String.pad_trailing(fraction, 6, "0"))

        from_unix(microseconds)

      nil ->
        :error
    end
  end

  def to_datetime(_value), do: :error

  # Seconds past the year 9999 match the pattern and name no date.
  defp from_unix(microseconds) do
    case DateTime.from_unix(microseconds, :microsecond) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _beyond} -> :error
    end
  end
end
