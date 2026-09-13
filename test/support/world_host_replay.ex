defmodule Ryker.TestSupport.WorldHostReplay do
  @moduledoc false

  alias Ryker.Evals.{WorldCase, WorldCassette}
  alias Ryker.State.Records
  alias Ryker.StateTools.Tools
  alias Ryker.TestSupport.FakeWorkCoopAPI

  @placeholder ~r/\A\$call:(\d+):([A-Za-z0-9_.:-]{1,256})\z/

  @spec before_execute(WorldCase.t(), pid(), keyword()) ::
          {:ok, (map(), WorldCase.t() -> :ok | {:error, term()})} | {:error, term()}
  def before_execute(scenario, fake, options \\ [])

  def before_execute(%WorldCase{} = scenario, fake, options)
      when is_pid(fake) and is_list(options) do
    with :ok <- options(options),
         events when is_list(events) and events != [] <- scenario.host_replay["model_events"],
         :ok <- input_indexes(events),
         {:ok, counter} <- Agent.start_link(fn -> 0 end) do
      cassette = Keyword.get(options, :cassette)

      {:ok,
       fn claim, _scenario ->
         input_index = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

         case Enum.find(events, &(&1["input_index"] == input_index)) do
           nil -> {:error, {:invalid_world_host_replay, :input_index}}
           event -> execute_event(event, claim, fake, cassette)
         end
       end}
    else
      [] -> {:error, {:invalid_world_host_replay, :model_events}}
      false -> {:error, {:invalid_world_host_replay, :model_events}}
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_world_host_replay, :model_events}}
    end
  end

  def before_execute(_scenario, _fake, _options),
    do: {:error, {:invalid_world_host_replay, :arguments}}

  defp execute_event(event, claim, fake, cassette) do
    with {:ok, output_artifacts} <- output_artifacts(Map.get(event, "output_artifacts", [])),
         {:ok, outputs} <- execute_calls(event["calls"], claim, cassette),
         {:ok, candidates} <- render_candidates(event["candidates"], outputs),
         {:ok, preflight} <- preflight(event, candidates, claim) do
      on_validation_reject =
        case {event["preflight_candidate_index"], preflight} do
          {1, :ok} -> nil
          {_later, function} when is_function(function, 0) -> function
        end

      FakeWorkCoopAPI.update(fake, fn state ->
        state
        |> Map.put(:candidates, candidates)
        |> Map.put(:on_validation_reject, on_validation_reject)
        |> Map.put(:output_artifact_metadata, output_artifacts.metadata)
        |> Map.put(:output_artifacts, output_artifacts.bodies)
        |> apply_faults(Map.get(event, "faults", []))
      end)

      :ok
    end
  end

  defp apply_faults(state, faults) do
    Enum.reduce(faults, state, fn
      "lose_submit_response", current ->
        Map.put(current, :lose_first_submit_response, true)

      "lose_validation_response", current ->
        Map.put(current, :lose_first_validation_response, true)

      "lose_delivery_response", current ->
        current

      "rate_limit_submit_once", current ->
        Map.put(current, :submit_errors, [
          {:error, {:coop_error, 429, "rate_limited", "simulated provider cooldown"}}
        ])

      "crash_after_submit", current ->
        current
    end)
  end

  defp output_artifacts(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, %{bodies: %{}, metadata: []}}, fn value, {:ok, prepared} ->
      case output_artifact(value) do
        {:ok, metadata, body} ->
          {:cont,
           {:ok,
            %{
              bodies: Map.put(prepared.bodies, metadata["id"], body),
              metadata: prepared.metadata ++ [metadata]
            }}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp output_artifacts(_values),
    do: {:error, {:invalid_world_host_replay, :output_artifacts}}

  defp output_artifact(%{"data_base64" => encoded} = value) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, data} ->
        metadata = Map.drop(value, ["data_base64"])
        {:ok, metadata, Map.put(metadata, "data", data)}

      :error ->
        {:error, {:invalid_world_host_replay, :output_artifacts}}
    end
  end

  defp output_artifact(_value),
    do: {:error, {:invalid_world_host_replay, :output_artifacts}}

  defp execute_calls(calls, claim, cassette) when is_list(calls) do
    calls
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, outputs} ->
      case execute_call(call, claim, cassette) do
        {:ok, output} -> {:cont, {:ok, outputs ++ [output]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp execute_calls(_calls, _claim, _cassette),
    do: {:error, {:invalid_world_host_replay, :calls}}

  defp execute_call(
         %{
           "arguments" => arguments,
           "expected_error" => expected,
           "kind" => "state",
           "tool" => tool
         },
         claim,
         _cassette
       )
       when is_binary(tool) and is_binary(expected) and is_map(arguments) do
    state_call(tool, arguments, claim, expected)
  end

  defp execute_call(%{"arguments" => arguments, "kind" => "state", "tool" => tool}, claim, _)
       when is_binary(tool) and is_map(arguments) do
    state_call(tool, arguments, claim, nil)
  end

  defp execute_call(
         %{"arguments" => arguments, "kind" => "fabricated", "tool" => tool},
         _claim,
         cassette
       )
       when is_binary(tool) and is_map(arguments) and not is_nil(cassette) do
    case WorldCassette.call(cassette, tool, arguments) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, {:world_host_replay_fabricated_call, tool, reason}}
    end
  end

  defp execute_call(%{"kind" => "fabricated"}, _claim, nil),
    do: {:error, {:invalid_world_host_replay, :cassette}}

  defp execute_call(_call, _claim, _cassette),
    do: {:error, {:invalid_world_host_replay, :call}}

  defp state_call(tool, arguments, claim, nil) do
    case Tools.call(tool, arguments, binding_options(claim)) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, {:world_host_replay_state_call, tool, reason}}
    end
  end

  defp state_call(tool, arguments, claim, expected) do
    case Tools.call(tool, arguments, binding_options(claim)) do
      {:error, ^expected} -> {:ok, %{"error" => expected}}
      {:error, reason} -> {:error, {:world_host_replay_state_call, tool, reason}}
      {:ok, output} -> {:error, {:world_host_replay_expected_error, tool, output}}
    end
  end

  defp render_candidates(candidates, outputs) when is_list(candidates) and candidates != [] do
    candidates
    |> Enum.reduce_while({:ok, []}, fn candidate, {:ok, rendered} ->
      case render_candidate(candidate, outputs) do
        {:ok, bytes} -> {:cont, {:ok, rendered ++ [bytes]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp render_candidates(_candidates, _outputs),
    do: {:error, {:invalid_world_host_replay, :candidates}}

  defp render_candidate(%{"bytes" => bytes, "kind" => "raw"}, _outputs)
       when is_binary(bytes),
       do: {:ok, bytes}

  defp render_candidate(%{"document" => document, "kind" => "final"}, outputs)
       when is_map(document) do
    with {:ok, rendered} <- render(document, outputs) do
      {:ok, Jason.encode!(rendered)}
    end
  end

  defp render_candidate(_candidate, _outputs),
    do: {:error, {:invalid_world_host_replay, :candidate}}

  defp render(value, outputs) when is_map(value) do
    value
    |> Enum.reduce_while({:ok, %{}}, fn {key, nested}, {:ok, rendered} ->
      case render(nested, outputs) do
        {:ok, result} -> {:cont, {:ok, Map.put(rendered, key, result)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp render(value, outputs) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn nested, {:ok, rendered} ->
      case render(nested, outputs) do
        {:ok, result} -> {:cont, {:ok, rendered ++ [result]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp render(value, outputs) when is_binary(value) do
    case Regex.run(@placeholder, value) do
      [_, index, field] -> placeholder(outputs, String.to_integer(index), field)
      nil -> {:ok, value}
    end
  end

  defp render(value, _outputs), do: {:ok, value}

  defp placeholder(outputs, index, field) do
    case Enum.at(outputs, index) do
      %{} = output ->
        case Map.fetch(output, field) do
          {:ok, value} -> {:ok, value}
          :error -> {:error, {:invalid_world_host_replay, :placeholder}}
        end

      _missing ->
        {:error, {:invalid_world_host_replay, :placeholder}}
    end
  end

  defp preflight(event, candidates, claim) do
    index = event["preflight_candidate_index"]

    with true <- is_integer(index) and index > 0,
         candidate when is_binary(candidate) <- Enum.at(candidates, index - 1),
         {:ok, document} <- Jason.decode(candidate) do
      validate = fn -> validate_final(document, claim) end

      preflight_result(index, validate)
    else
      _invalid -> {:error, {:invalid_world_host_replay, :preflight_candidate_index}}
    end
  end

  defp preflight_result(1, validate) do
    case validate.() do
      :ok -> {:ok, :ok}
      {:error, _reason} = error -> error
    end
  end

  defp preflight_result(_later, validate), do: {:ok, validate}

  defp validate_final(document, claim) do
    case Tools.call(
           "validate_final",
           %{"candidate" => document},
           binding_options(claim)
         ) do
      {:ok, %{"accepted" => true}} -> :ok
      {:ok, response} -> {:error, {:world_host_replay_preflight, response}}
      {:error, reason} -> {:error, {:world_host_replay_preflight, reason}}
    end
  end

  defp binding_options(claim) do
    %{
      binding: %{
        episode: claim.episode,
        session: claim.session,
        state_token: Records.token(claim.turn),
        turn: claim.turn
      },
      capabilities: [:event_waits, :publication, :schedules]
    }
  end

  defp input_indexes(events) do
    indexes = Enum.map(events, & &1["input_index"])

    if indexes == Enum.to_list(1..length(events)),
      do: :ok,
      else: {:error, {:invalid_world_host_replay, :input_index}}
  end

  defp options(options) do
    if Keyword.keyword?(options) and Keyword.keys(options) -- [:cassette] == [],
      do: :ok,
      else: {:error, {:invalid_world_host_replay, :options}}
  end
end
