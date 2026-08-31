defmodule Responder.Work.Measurement do
  @moduledoc false

  @maximum_target_bytes 512
  @maximum_cost_usd Decimal.new("1000000000")
  @usage_keys ~w(input_tokens cached_input_tokens output_tokens reasoning_tokens)

  @type t :: map()

  @spec prepare(map(), map()) :: t()
  def prepare(remote_turn, remote_session) when is_map(remote_turn) and is_map(remote_session) do
    {target, errors} = target(remote_session, [])
    {usage, errors} = usage(remote_turn, errors)
    {timing, errors} = timing(remote_turn, errors)

    %{}
    |> Map.merge(target)
    |> Map.merge(usage)
    |> Map.merge(timing)
    |> Map.put(:measurement_error_code, error_code(errors))
  end

  @spec acceptance_attributes(t(), DateTime.t()) :: map()
  def acceptance_attributes(measurement, %DateTime{} = accepted_at) when is_map(measurement) do
    host_ms =
      case measurement do
        %{timing_recorded: true, remote_finished_at: finished_at} ->
          max(DateTime.diff(accepted_at, finished_at, :millisecond), 0)

        _other ->
          nil
      end

    Map.put(measurement, :usage_host_ms, host_ms)
  end

  @spec target_parts(String.t() | nil) :: map()
  def target_parts(nil),
    do: %{effort: "default", model: "default", provider: "unrecorded"}

  def target_parts(target) when is_binary(target) do
    [head | _accounts] = String.split(target, "@", parts: 2)
    [model_spec | effort] = String.split(head, "/", parts: 2)
    [provider | model] = String.split(model_spec, ":", parts: 2)

    %{
      effort: List.first(effort) || "default",
      model: List.first(model) || "default",
      provider: provider
    }
  end

  defp target(%{"target" => value}, errors)
       when is_binary(value) and byte_size(value) in 1..@maximum_target_bytes do
    if String.contains?(value, <<0>>),
      do: {%{execution_target: nil}, [:target | errors]},
      else: {%{execution_target: value}, errors}
  end

  defp target(_session, errors), do: {%{execution_target: nil}, [:target | errors]}

  defp usage(remote_turn, errors) do
    case Map.fetch(remote_turn, "usage") do
      :error -> {empty_usage(), errors}
      {:ok, %{} = value} -> measured_usage(value, errors)
      {:ok, _invalid} -> {empty_usage(), [:usage | errors]}
    end
  end

  defp measured_usage(value, errors) do
    with {:ok, tokens} <- usage_tokens(value),
         {:ok, cost} <- usage_cost(value),
         cost_recorded when is_boolean(cost_recorded) <- Map.get(value, "cost_recorded", false),
         true <- Enum.any?(Map.values(tokens), &(&1 > 0)) or cost_recorded do
      {%{
         usage_cached_input_tokens: tokens["cached_input_tokens"],
         usage_cost_recorded: cost_recorded,
         usage_cost_usd: cost,
         usage_input_tokens: tokens["input_tokens"],
         usage_output_tokens: tokens["output_tokens"],
         usage_reasoning_tokens: tokens["reasoning_tokens"],
         usage_recorded: true
       }, errors}
    else
      _invalid -> {empty_usage(), [:usage | errors]}
    end
  end

  defp usage_tokens(value) do
    Enum.reduce_while(@usage_keys, {:ok, %{}}, fn key, {:ok, values} ->
      case Map.get(value, key, 0) do
        number when is_integer(number) and number >= 0 ->
          {:cont, {:ok, Map.put(values, key, number)}}

        _invalid ->
          {:halt, :error}
      end
    end)
  end

  defp usage_cost(value) do
    with {:ok, decimal} <- decimal(Map.get(value, "cost_usd", 0)),
         true <- Decimal.compare(decimal, Decimal.new(0)) in [:eq, :gt],
         true <- Decimal.compare(decimal, @maximum_cost_usd) in [:eq, :lt] do
      {:ok, decimal}
    else
      _invalid -> :error
    end
  end

  defp decimal(value) when is_integer(value), do: {:ok, Decimal.new(value)}
  defp decimal(value) when is_float(value), do: {:ok, Decimal.from_float(value)}
  defp decimal(_value), do: :error

  defp empty_usage do
    %{
      usage_cached_input_tokens: nil,
      usage_cost_recorded: nil,
      usage_cost_usd: nil,
      usage_input_tokens: nil,
      usage_output_tokens: nil,
      usage_reasoning_tokens: nil,
      usage_recorded: false
    }
  end

  defp timing(remote_turn, errors) do
    with {:ok, queued_at} <- timestamp(remote_turn["queued_at"]),
         {:ok, started_at} <- timestamp(remote_turn["started_at"]),
         {:ok, finished_at} <- timestamp(remote_turn["finished_at"]),
         :lt_or_eq <- compare(queued_at, started_at),
         :lt_or_eq <- compare(started_at, finished_at) do
      {%{
         remote_finished_at: finished_at,
         remote_queued_at: queued_at,
         remote_started_at: started_at,
         timing_recorded: true,
         usage_host_ms: nil,
         usage_provider_ms: DateTime.diff(finished_at, started_at, :millisecond),
         usage_queued_ms: DateTime.diff(started_at, queued_at, :millisecond)
       }, errors}
    else
      _invalid -> {empty_timing(), timing_error(remote_turn, errors)}
    end
  end

  defp timing_error(remote_turn, errors) do
    if Enum.all?(~w(queued_at started_at finished_at), &is_nil(remote_turn[&1])),
      do: errors,
      else: [:timing | errors]
  end

  defp empty_timing do
    %{
      remote_finished_at: nil,
      remote_queued_at: nil,
      remote_started_at: nil,
      timing_recorded: false,
      usage_host_ms: nil,
      usage_provider_ms: nil,
      usage_queued_ms: nil
    }
  end

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, DateTime.truncate(datetime, :microsecond)}
      _invalid -> :error
    end
  end

  defp timestamp(_value), do: :error

  defp compare(left, right) do
    if DateTime.compare(left, right) in [:lt, :eq], do: :lt_or_eq, else: :invalid
  end

  defp error_code([]), do: nil

  defp error_code(errors) do
    errors
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map_join(",", &"invalid_#{&1}")
  end
end
