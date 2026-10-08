defmodule Ryker.Slack.ID do
  @moduledoc """
  A Slack id for a workspace, channel, person or bot: capital letters and
  digits, as in "T0123ABCD" or "C0456EFGH". Slack's own are a dozen or so
  characters; anything past 256 bytes is not one.
  """

  @pattern ~r/\A[A-Z0-9]{1,256}\z/

  @doc "Whether `value` is a Slack id."
  @spec valid?(term()) :: boolean()
  def valid?(value), do: is_binary(value) and Regex.match?(@pattern, value)

  @doc "The pattern `valid?/1` matches, for a changeset's format check."
  @spec pattern() :: Regex.t()
  def pattern, do: @pattern
end
