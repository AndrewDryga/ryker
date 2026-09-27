defmodule Ryker.RepositoryKnowledge.WorkerTest do
  use Ryker.DataCase, async: false

  alias Ryker.GitHub.Onboarding
  alias Ryker.{RepositoryKnowledge, Settings}
  alias Ryker.RepositoryKnowledge.Worker
  alias Ryker.TestSupport.{FakeCoopAPI, FakeGitHubRepository}

  @actor "control-plane:local"
  @head "783fc4801d274d5ee05feb3fbc5c70981b1bbd7a"

  defmodule API do
    alias Ryker.TestSupport.FakeCoopAPI, as: Fake

    defdelegate prepare_create_session(client, key, policy, ref, source), to: Fake
    defdelegate create_session(client, key, policy, ref, source), to: Fake
    defdelegate get_session(client, id), to: Fake
    defdelegate get_turn(client, session_id, turn_id), to: Fake
    defdelegate cancel_turn(client, session_id, turn_id, key, revision), to: Fake
    defdelegate operation_by_key(client, key), to: Fake
  end

  setup do
    {:ok, snapshot} = Settings.initialize(@actor)

    {:ok, snapshot} =
      Settings.put_repository(
        %{ref: "emisar", github_repository: "AndrewDryga/emisar", base_branch: "main"},
        snapshot.installation.revision,
        @actor
      )

    {:ok, _snapshot} =
      Settings.put_github_binding(
        %{
          name: "emisar",
          repository_ref: "emisar",
          installation_id: 10,
          repository_id: 20,
          ryker_actor_id: 30
        },
        snapshot.installation.revision,
        @actor
      )

    # A person's RYKER.md: the first check accepts it and asks the model
    # nothing, so the lane goes idle until something wakes it.
    start_supervised!(
      {FakeGitHubRepository,
       head: @head,
       tree: [{"README.md", "blob"}, {"RYKER.md", "blob"}],
       document: "# How we work\n\nRun `make check`.\n"}
    )

    {:ok, :ready} = Onboarding.run("emisar", api: FakeGitHubRepository)
    :ok
  end

  # The lane sleeps until a check falls due, a day away. Refresh knowledge on
  # the Repositories page has to wake it, or the row would say "Writing
  # RYKER.md" for a day while nothing wrote it.
  test "a refresh asked for while the lane sleeps starts at once" do
    {:ok, coop} = FakeCoopAPI.start_link([], async_create: true)

    worker =
      start_supervised!(
        {Worker,
         %{
           api: API,
           client: coop,
           remote: FakeGitHubRepository,
           worker_ref: "knowledge-worker-test",
           poll_interval_ms: 60_000,
           idle_interval_ms: 60_000,
           execution_timeout_seconds: 1_800,
           lease_seconds: 300,
           step_delay_seconds: 60,
           retry_delay_seconds: 60
         }}
      )

    # Its first polls checked the repository and found nothing to write.
    assert eventually(fn -> RepositoryKnowledge.entry("emisar").checked_at != nil end)
    _state = :sys.get_state(worker)
    assert FakeCoopAPI.state(coop).create_keys == []

    assert {:ok, :requested} = RepositoryKnowledge.refresh("emisar", @actor)
    assert eventually(fn -> FakeCoopAPI.state(coop).create_keys != [] end)
  end

  defp eventually(check, tries \\ 40) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && eventually(check, tries - 1)
    end
  end
end
