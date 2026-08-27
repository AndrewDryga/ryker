defmodule Responder.EpisodesReplayPersistenceTest do
  use Responder.DataCase, async: true

  alias Responder.Episodes
  alias Responder.Episodes.Replay

  @fixture_paths Path.wildcard(Path.join([__DIR__, "episodes", "fixtures", "*.json"]))
                 |> Enum.reject(&String.ends_with?(&1, ".golden.json"))

  for fixture_path <- @fixture_paths do
    @fixture_path fixture_path

    test "persists the exact #{Path.basename(fixture_path, ".json")} replay transcript" do
      fixture = Replay.read!(@fixture_path)
      pure = Replay.run!(fixture)
      persisted = Replay.run_with!(fixture, &persist_and_reload/1)

      assert Replay.encode_result!(persisted) == Replay.encode_result!(pure)
    end
  end

  test "uppercase UUID input has byte-identical pure and persisted linked history" do
    fixture =
      Path.join([__DIR__, "episodes", "fixtures", "linked_incident_keeps_own_thread.json"])
      |> Replay.read!()
      |> uppercase_uuids()

    pure = Replay.run!(fixture)
    persisted = Replay.run_with!(fixture, &persist_and_reload/1)

    assert Replay.encode_result!(persisted) == Replay.encode_result!(pure)
  end

  defp uppercase_uuids(%{} = value) do
    Map.new(value, fn
      {key, uuid} when key in ["episode_id", "linked_episode_id"] and is_binary(uuid) ->
        {key, String.upcase(uuid)}

      {key, nested} ->
        {key, uppercase_uuids(nested)}
    end)
  end

  defp uppercase_uuids(value) when is_list(value), do: Enum.map(value, &uppercase_uuids/1)
  defp uppercase_uuids(value), do: value

  defp persist_and_reload(command) do
    with {:ok, transition} <- Episodes.apply(command),
         {:ok, episode} <- Episodes.fetch_by_key(command.episode_key) do
      event =
        Enum.find(Episodes.list_events(command.episode_key), fn event ->
          event.dedupe_key == transition.event.dedupe_key
        end)

      {:ok, %{transition | episode: episode, event: event}}
    end
  end
end
