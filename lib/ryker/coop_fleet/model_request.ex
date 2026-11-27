defmodule Ryker.CoopFleet.ModelRequest do
  @moduledoc false
  alias Ryker.CoopFleet.ModelContracts

  def websocket(job, provider, account, body) do
    with {:ok, %Jason.OrderedObject{values: values}} <-
           Jason.decode(body, objects: :ordered_objects),
         true <- unique?(values),
         {:ok, lane} <- stream_id(values) do
      websocket_event(job, provider, account, body, values, lane)
    else
      _invalid -> {:error, :model_target_refused}
    end
  end

  defp websocket_event(job, provider, account, body, values, lane) do
    case List.keyfind(values, "type", 0) do
      {"type", "response.create"} ->
        with :ok <- validate(job, provider, account, "/v1/responses", body),
             do: {:ok, %{kind: :create, lane: lane}}

      {"type", "response.interrupt"} ->
        interrupt(values, lane)

      _unsupported ->
        {:error, :model_target_refused}
    end
  end

  defp interrupt(values, lane) do
    with {"response_id", response} when is_binary(response) and byte_size(response) in 1..512 <-
           List.keyfind(values, "response_id", 0),
         {"mode", "discard_partial_items"} <- List.keyfind(values, "mode", 0) do
      {:ok, %{kind: :interrupt, lane: lane, response_id: response}}
    else
      _invalid -> {:error, :model_target_refused}
    end
  end

  defp stream_id(values) do
    case List.keyfind(values, "stream_id", 0) do
      nil ->
        {:ok, nil}

      {"stream_id", value} when is_binary(value) and byte_size(value) in 1..256 ->
        if Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, value), do: {:ok, value}, else: :error

      _invalid ->
        :error
    end
  end

  def inference?(method, path), do: method == "POST" and inference_path?(path)

  defp inference_path?(path) do
    String.ends_with?(path, "/responses") or String.ends_with?(path, "/responses/compact") or
      path == "/v1/messages" or String.contains?(path, "/images/")
  end

  def validate(job, provider, account, path, body) do
    if inference_path?(path) do
      with {:ok, %Jason.OrderedObject{values: values}} <-
             Jason.decode(body, objects: :ordered_objects),
           true <- unique?(values),
           true <-
             List.keyfind(values, "background", 0) in [
               nil,
               {"background", false},
               {"background", nil}
             ],
           {"model", model} when is_binary(model) <- List.keyfind(values, "model", 0),
           true <-
             ModelContracts.model_allowed?(model, ModelContracts.models(job, provider, account)) do
        :ok
      else
        _refused -> {:error, :model_target_refused}
      end
    else
      :ok
    end
  end

  defp unique?(values) do
    keys = Enum.map(values, &elem(&1, 0))
    length(keys) == length(Enum.uniq(keys))
  end
end
