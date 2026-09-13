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

  @doc "A view Slack publishes to the App Home: exactly `blocks` and `type`, bounded."
  @spec home_view(term()) :: :ok | {:error, {:invalid_slack_api_request, :home_view}}
  def home_view(%{"blocks" => blocks, "type" => "home"} = view)
      when is_list(blocks) and length(blocks) <= 100 do
    if Map.keys(view) |> Enum.sort() == ["blocks", "type"] and
         Enum.all?(blocks, &is_map/1) and byte_size(Jason.encode!(view)) <= 256 * 1_024,
       do: :ok,
       else: {:error, {:invalid_slack_api_request, :home_view}}
  end

  def home_view(_view), do: {:error, {:invalid_slack_api_request, :home_view}}

  @spec modal_view(term()) :: :ok | {:error, {:invalid_slack_api_request, :modal_view}}
  def modal_view(%{"blocks" => blocks, "type" => "modal"} = view)
      when is_list(blocks) and length(blocks) <= 100 do
    required = ~w(blocks callback_id close private_metadata submit title type)

    if Map.keys(view) |> Enum.sort() == Enum.sort(required) and
         Enum.all?(blocks, &is_map/1) and byte_size(Jason.encode!(view)) <= 256 * 1_024,
       do: :ok,
       else: {:error, {:invalid_slack_api_request, :modal_view}}
  end

  def modal_view(_view), do: {:error, {:invalid_slack_api_request, :modal_view}}

  # --- what Slack sent back -------------------------------------------------

  @doc "A reply body the client will hand on: canonical JSON within the retained bound."
  @spec bounded_result(term(), atom()) :: :ok | {:error, {:slack_protocol_error, atom()}}
  def bounded_result(document, field) do
    if CanonicalJSON.validate(document, max_bytes: @maximum_result_bytes) == :ok,
      do: :ok,
      else: {:error, {:slack_protocol_error, field}}
  end

  @spec resource_id?(term()) :: boolean()
  def resource_id?(value),
    do:
      is_binary(value) and byte_size(value) in 1..256 and
        Regex.match?(~r/\A[A-Za-z0-9]+\z/, value)

  @spec optional_resource_id?(term()) :: boolean()
  def optional_resource_id?(nil), do: true
  def optional_resource_id?(value), do: resource_id?(value)

  @spec bounded_token?(term(), pos_integer()) :: boolean()
  def bounded_token?(value, maximum),
    do:
      is_binary(value) and byte_size(value) in 1..maximum and
        Regex.match?(~r/\A[a-z0-9_]+\z/, value)

  @spec bounded_string?(term(), pos_integer()) :: boolean()
  def bounded_string?(value, maximum),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
        :binary.match(value, <<0>>) == :nomatch and String.trim(value) != ""

  @spec optional_bounded_string?(term(), pos_integer()) :: boolean()
  def optional_bounded_string?(nil, _maximum), do: true
  def optional_bounded_string?(value, maximum), do: bounded_string?(value, maximum)

  @spec filename?(term()) :: boolean()
  def filename?(value) do
    bounded_string?(value, 255) and value not in [".", ".."] and
      not String.contains?(value, ["/", "\\"])
  end
end
