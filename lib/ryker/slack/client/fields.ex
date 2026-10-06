defmodule Ryker.Slack.Client.Fields do
  @moduledoc """
  The argument and value checks the Slack client applies before it spends a
  request, and the shape checks it applies to what Slack sends back.

  Checks of a request argument return `:ok` or `{:error,
  {:invalid_slack_api_request, field}}`; predicates over a response value
  return a boolean, and the caller names the protocol error.
  """

  alias Ryker.CanonicalJSON

  @maximum_conversation_name_bytes 80
  @maximum_result_bytes 768 * 1_024

  @spec text(term()) :: :ok | {:error, {:invalid_slack_api_request, :text}}
  def text(value) do
    if is_binary(value) and String.valid?(value) and byte_size(value) > 0 and
         byte_size(value) <= 256 * 1_024,
       do: :ok,
       else: {:error, {:invalid_slack_api_request, :text}}
  end

  @spec optional_text(term()) :: :ok | {:error, {:invalid_slack_api_request, :text}}
  def optional_text(nil), do: :ok
  def optional_text(value), do: text(value)

  @spec bounded_text(term(), pos_integer()) :: :ok | {:error, {:invalid_slack_api_request, :text}}
  def bounded_text(value, maximum) do
    if is_binary(value) and String.valid?(value) and String.trim(value) != "" and
         byte_size(value) <= maximum,
       do: :ok,
       else: {:error, {:invalid_slack_api_request, :text}}
  end

  @spec slack_id(term()) :: :ok | {:error, {:invalid_slack_api_request, :id}}
  def slack_id(value) do
    if is_binary(value) and Regex.match?(~r/\A[A-Z0-9]+\z/, value),
      do: :ok,
      else: {:error, {:invalid_slack_api_request, :id}}
  end

  @spec unique_slack_ids(term()) :: :ok | {:error, {:invalid_slack_api_request, :users}}
  def unique_slack_ids(values) when is_list(values) and length(values) <= 200 do
    if values == Enum.uniq(values) and Enum.all?(values, &(slack_id(&1) == :ok)),
      do: :ok,
      else: {:error, {:invalid_slack_api_request, :users}}
  end

  def unique_slack_ids(_values), do: {:error, {:invalid_slack_api_request, :users}}

  @spec message_timestamp(term()) :: :ok | {:error, {:invalid_slack_api_request, :timestamp}}
  def message_timestamp(value) do
    if is_binary(value) and Regex.match?(~r/\A[0-9]{10,}\.[0-9]{1,6}\z/, value),
      do: :ok,
      else: {:error, {:invalid_slack_api_request, :timestamp}}
  end

  @spec optional_message_timestamp(term()) ::
          :ok | {:error, {:invalid_slack_api_request, :timestamp}}
  def optional_message_timestamp(nil), do: :ok
  def optional_message_timestamp(value), do: message_timestamp(value)

  @spec thread_status(term()) :: :ok | {:error, {:invalid_slack_api_request, :thread_status}}
  def thread_status(value) do
    if is_binary(value) and String.valid?(value) and byte_size(value) <= 100 and
         :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, {:invalid_slack_api_request, :thread_status}}
  end

  @spec conversation_name(term()) ::
          :ok | {:error, {:invalid_slack_api_request, :conversation_name}}
  def conversation_name(value) do
    if is_binary(value) and byte_size(value) in 1..@maximum_conversation_name_bytes and
         Regex.match?(~r/\A[a-z0-9_-]+\z/, value),
       do: :ok,
       else: {:error, {:invalid_slack_api_request, :conversation_name}}
  end

  @spec utc_datetime(term()) :: :ok | {:error, {:invalid_slack_api_request, :requested_at}}
  def utc_datetime(%DateTime{} = value) do
    if value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0,
      do: :ok,
      else: {:error, {:invalid_slack_api_request, :requested_at}}
  end

  def utc_datetime(_value), do: {:error, {:invalid_slack_api_request, :requested_at}}

  # --- listing documents ----------------------------------------------------
  #
  # A value a caller's listing document may carry, as `{:ok, value}` for the
  # query; the listing's own check names the refused request.

  @spec listing_cursor(term()) :: {:ok, String.t() | nil} | {:error, :cursor}
  def listing_cursor(nil), do: {:ok, nil}

  def listing_cursor(value) when is_binary(value) and byte_size(value) in 1..4_096,
    do: {:ok, value}

  def listing_cursor(_value), do: {:error, :cursor}

  @spec listing_boolean(term()) :: {:ok, boolean()} | {:error, :boolean}
  def listing_boolean(value) when is_boolean(value), do: {:ok, value}
  def listing_boolean(_value), do: {:error, :boolean}

  # --- what Slack sent back -------------------------------------------------

  @doc "A reply body the client will hand on: canonical JSON within the retained bound."
  @spec bounded_result(term(), atom()) :: :ok | {:error, {:slack_protocol_error, atom()}}
  def bounded_result(document, field) do
    if CanonicalJSON.validate(document, max_bytes: @maximum_result_bytes) == :ok,
      do: :ok,
      else: {:error, {:slack_protocol_error, field}}
  end

  @spec resource_id?(term()) :: boolean()
  def resource_id?(value) do
    is_binary(value) and byte_size(value) in 1..256 and
      Regex.match?(~r/\A[A-Za-z0-9]+\z/, value)
  end

  @spec optional_resource_id?(term()) :: boolean()
  def optional_resource_id?(nil), do: true
  def optional_resource_id?(value), do: resource_id?(value)

  @spec bounded_token?(term(), pos_integer()) :: boolean()
  def bounded_token?(value, maximum) do
    is_binary(value) and byte_size(value) in 1..maximum and
      Regex.match?(~r/\A[a-z0-9_]+\z/, value)
  end

  @spec bounded_string?(term(), pos_integer()) :: boolean()
  def bounded_string?(value, maximum) do
    is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
      :binary.match(value, <<0>>) == :nomatch and String.trim(value) != ""
  end

  @spec optional_bounded_string?(term(), pos_integer()) :: boolean()
  def optional_bounded_string?(nil, _maximum), do: true
  def optional_bounded_string?(value, maximum), do: bounded_string?(value, maximum)

  @spec filename?(term()) :: boolean()
  def filename?(value) do
    bounded_string?(value, 255) and value not in [".", ".."] and
      not String.contains?(value, ["/", "\\"])
  end
end
