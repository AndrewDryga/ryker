defmodule Ryker.Slack.Renderer.Fields do
  @moduledoc """
  Field checks shared by the Slack cards.

  Every card validates its document before rendering a block from it; these
  are the checks that do not belong to one card family. Each returns `:ok` or
  a reason the card folds into its own `{:invalid_slack_render, family}`.
  """

  @spec text?(term()) :: boolean()
  def text?(value) do
    is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      String.trim(value) != ""
  end

  @spec bounded_text(term(), pos_integer()) :: :ok | {:error, :invalid_text}
  def bounded_text(value, maximum) do
    if text?(value) and byte_size(value) <= maximum, do: :ok, else: {:error, :invalid_text}
  end

  @spec optional_bounded_text(term(), pos_integer()) :: :ok | {:error, :invalid_text}
  def optional_bounded_text(nil, _maximum), do: :ok
  def optional_bounded_text(value, maximum), do: bounded_text(value, maximum)

  @spec positive_integer(term()) :: :ok | {:error, :invalid_positive_integer}
  def positive_integer(value) when is_integer(value) and value > 0, do: :ok
  def positive_integer(_value), do: {:error, :invalid_positive_integer}

  @spec optional_positive_integer(term()) :: :ok | {:error, :invalid_positive_integer}
  def optional_positive_integer(nil), do: :ok
  def optional_positive_integer(value), do: positive_integer(value)

  @spec iso8601(term()) :: :ok | {:error, :invalid_datetime}
  def iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, 0} -> :ok
      _invalid -> {:error, :invalid_datetime}
    end
  end

  def iso8601(_value), do: {:error, :invalid_datetime}

  @spec optional_https_url(term()) :: :ok | {:error, :invalid_https_url | :invalid_text}
  def optional_https_url(nil), do: :ok

  def optional_https_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        bounded_text(value, 2_048)

      _invalid ->
        {:error, :invalid_https_url}
    end
  end

  def optional_https_url(_value), do: {:error, :invalid_https_url}

  @doc "A Slack user, channel or workspace id as Slack issues them."
  @spec slack_reference?(term()) :: boolean()
  def slack_reference?(value),
    do: is_binary(value) and Regex.match?(~r/\A[A-Z0-9]{1,64}\z/, value)

  @spec slack_user(term()) :: :ok | {:error, :invalid_slack_user}
  def slack_user(value),
    do: if(slack_reference?(value), do: :ok, else: {:error, :invalid_slack_user})
end
