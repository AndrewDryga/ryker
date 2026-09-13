defmodule Ryker.Episodes.Kernel do
  @moduledoc """
  Applies an unseen command or reconciles a retry of an existing event.
  """

  alias Ryker.Episodes.{Command, Event, Reducer, Transition}

  @spec apply(struct() | nil, Event.t() | nil, Command.t()) ::
          {:ok, Transition.t()} | {:error, term()}
  def apply(episode, event, command) do
    command = Command.bind_episode(command, episode)

    with {:ok, command} <- Command.prepare(command) do
      apply_prepared(episode, event, command)
    end
  end

  defp apply_prepared(episode, nil, command), do: Reducer.decide(episode, command)

  defp apply_prepared(episode, %Event{} = event, command) do
    dedupe_key = Command.dedupe_key(command)
    fingerprint = Command.fingerprint(command)

    cond do
      event.dedupe_key != dedupe_key ->
        {:error, {:existing_event_key_mismatch, event.dedupe_key, dedupe_key}}

      event.fingerprint == fingerprint ->
        {:ok, %Transition{episode: episode, event: event, status: :duplicate}}

      true ->
        {:error,
         {:idempotency_conflict,
          dedupe_key: dedupe_key,
          stored_fingerprint: event.fingerprint,
          submitted_fingerprint: fingerprint}}
    end
  end
end
