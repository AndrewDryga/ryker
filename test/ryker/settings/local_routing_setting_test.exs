defmodule Ryker.Settings.LocalRoutingSettingTest do
  use Ryker.DataCase, async: false
  alias Ryker.Settings

  @actor "control-plane:local"

  setup do
    {:ok, snapshot} = Settings.initialize(@actor)
    %{snapshot: snapshot}
  end

  test "a new installation leaves the local routing model off", %{snapshot: snapshot} do
    assert snapshot.work.local_routing_mode == :off
    assert snapshot.work.local_routing_endpoint == nil
    assert snapshot.work.local_routing_model == nil
  end

  # Comparing in the background with nowhere to send the prompt, or with no
  # model to ask, would queue work that can only fail; and plain http across
  # the internet would hand every conversation to whoever is on the path.
  test "comparing in the background needs an endpoint and a model, and http only nearby", %{
    snapshot: snapshot
  } do
    revision = snapshot.installation.revision

    assert {:error, {:invalid_settings, errors}} =
             Settings.save_work(%{local_routing_mode: :shadow}, revision, @actor)

    assert {:local_routing_endpoint, :required} in errors
    assert {:local_routing_model, :required} in errors

    assert {:error, {:invalid_settings, [{:local_routing_endpoint, :insecure}]}} =
             Settings.save_work(
               shadow("http://llm.example.com/v1", "qwen2.5:3b"),
               revision,
               @actor
             )

    assert {:error, {:invalid_settings, [{:local_routing_endpoint, :format}]}} =
             Settings.save_work(
               shadow("http://user:secret@localhost:11434/v1", "qwen2.5:3b"),
               revision,
               @actor
             )

    assert {:error, {:invalid_settings, [{:local_routing_model, :format}]}} =
             Settings.save_work(
               shadow("http://host.docker.internal:11434/v1", "qwen 2.5"),
               revision,
               @actor
             )

    assert Settings.fetch!().installation.revision == revision

    assert {:ok, saved} =
             Settings.save_work(
               shadow("http://host.docker.internal:11434/v1", "qwen2.5:3b"),
               revision,
               @actor
             )

    assert saved.work.local_routing_mode == :shadow
    assert saved.work.local_routing_endpoint == "http://host.docker.internal:11434/v1"
    assert saved.work.local_routing_model == "qwen2.5:3b"

    # Turning it off keeps what was typed, so turning it on again is one click.
    assert {:ok, off} =
             Settings.save_work(
               %{local_routing_mode: :off},
               saved.installation.revision,
               @actor
             )

    assert off.work.local_routing_mode == :off
    assert off.work.local_routing_endpoint == "http://host.docker.internal:11434/v1"
    assert off.work.local_routing_model == "qwen2.5:3b"
  end

  test "the database holds the same rule when a write skips the settings path" do
    assert_raise Postgrex.Error, ~r/work_settings_local_routing_valid/, fn ->
      Repo.query!("UPDATE work_settings SET local_routing_mode = 'shadow'")
    end
  end

  defp shadow(endpoint, model),
    do: %{
      local_routing_mode: :shadow,
      local_routing_endpoint: endpoint,
      local_routing_model: model
    }
end
