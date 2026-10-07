defmodule Ryker.Delivery.Retry do
  @moduledoc """
  Whether a failure from Slack, GitHub or a publisher may pass on a later
  attempt, whether the provider asked Ryker to slow down, and what an attempt
  uploaded that the next one must wait for.

  Every lane that retries a provider call asks here. Lanes that each kept their
  own list disagreed: one treated a 408 as final, another a network blip
  repainting a card (2026-10-04 review).
  """

  @doc """
  Whether a failure may pass on a later attempt. Anything else is a refusal a
  retry cannot change.
  """
  @spec retryable?(term()) :: boolean()
  def retryable?({:delivery_credentials_unavailable, _reason}), do: true
  def retryable?({:delivery_publisher_crashed, _kind, _reason}), do: true
  def retryable?({:delivery_publisher_exit, _reason}), do: true

  def retryable?({:delivery_rate_limited, delay, _reason})
      when is_nil(delay) or (is_integer(delay) and delay > 0),
      do: true

  def retryable?({:delivery_share_pending, [_ | _]}), do: true
  def retryable?({:delivery_transport_unavailable, _reason}), do: true
  def retryable?({:delivery_uncertain, _reason}), do: true
  def retryable?({:delivery_reconciliation_failed, reason}), do: retryable?(reason)
  def retryable?({:github_api_error, status, _body}), do: retryable_status?(status)
  def retryable?({:slack_http_error, status, _body}), do: retryable_status?(status)

  def retryable?({:slack_api_error, error}),
    do: error in ~w(fatal_error internal_error ratelimited request_timeout service_unavailable)

  def retryable?(_reason), do: false

  @doc """
  `{:ok, seconds}` when the provider asked Ryker to slow down, with the wait it
  named or nil. A wait like that is the provider's pace, not a failed attempt,
  so a lane does not count it against the attempts an item has.
  """
  @spec rate_limited(term()) :: {:ok, pos_integer() | nil} | :error
  def rate_limited({:delivery_rate_limited, delay, _reason}) when is_integer(delay) and delay > 0,
    do: {:ok, delay}

  def rate_limited({:delivery_rate_limited, nil, _reason}), do: {:ok, nil}
  def rate_limited({:slack_api_error, "ratelimited"}), do: {:ok, nil}
  def rate_limited({:slack_http_error, 429, _body}), do: {:ok, nil}
  def rate_limited({:github_api_error, 429, _body}), do: {:ok, nil}

  def rate_limited({wrapper, reason})
      when wrapper in [:delivery_reconciliation_failed, :delivery_uncertain],
      do: rate_limited(reason)

  def rate_limited(_reason), do: :error

  @doc """
  The platform's ids for the files a failed attempt uploaded and did not see
  shared yet. The next attempt waits for that share instead of uploading them
  again; any other failure uploaded nothing a retry must remember.
  """
  @spec uploaded(term()) :: [String.t()]
  def uploaded({:delivery_share_pending, [_ | _] = upload_refs}), do: upload_refs
  def uploaded(_reason), do: []

  defp retryable_status?(status),
    do: status in [408, 409, 425, 429] or (is_integer(status) and status >= 500)
end
