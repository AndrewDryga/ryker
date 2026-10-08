defmodule Ryker.Slack.Id do
  @moduledoc """
  A Slack id for a workspace, channel, person or bot: capital letters and
  digits, as in "T0123ABCD" or "C0456EFGH". Slack's own are a dozen or so
  characters; anything past 256 bytes is not one.
  """

  @pattern ~r/\A[A-Z0-9]+\z/

  @doc "Whether `value` is a Slack id."
  @spec valid?(term()) :: boolean()
  def valid?(value),
    do: is_binary(value) and byte_size(value) <= 256 and Regex.match?(@pattern, value)
end
