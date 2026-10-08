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
  def to_datetime(value) do
    if valid?(value),
      do: value |> microseconds() |> from_unix(),
      else: :error
  end

  @doc """
  The microseconds since 1970 a valid Slack message timestamp names, so two
  of them compare as numbers in the order Slack posted them.
  """
  @spec microseconds(String.t()) :: non_neg_integer()
  def microseconds(value) do
    [seconds, fraction] = String.split(value, ".", parts: 2)
    microseconds = fraction |> String.pad_trailing(6, "0") |> String.to_integer()
    String.to_integer(seconds) * 1_000_000 + microseconds
  end

  # Seconds past the year 9999 match the pattern and name no date.
  defp from_unix(microseconds) do
    case DateTime.from_unix(microseconds, :microsecond) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _beyond} -> :error
    end
  end
end
