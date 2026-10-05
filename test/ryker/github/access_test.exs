defmodule Ryker.GitHub.AccessTest do
  use Ryker.DataCase, async: false

  alias Ryker.GitHub.{Access, Binding}
  alias Ryker.Settings

  @actor "control-plane:local"
  @permissions %{"contents" => "write", "pull_requests" => "write"}

  setup do
    {:ok, snapshot} = Settings.initialize(@actor)
    {:ok, snapshot} = repository!(snapshot, "widget", 501)

    {:ok, _snapshot} =
      Settings.save_github(
        %{auto_add_repositories: true, bot_actor_id: 30, bot_login: "ryker[bot]"},
        snapshot.installation.revision,
        @actor
      )

    %{trusted: %{"widget" => trusted!("widget", 501)}}
  end

  # The membership change was saved binding by binding, then the auto-import
  # of the new repositories ran and failed, so GitHub was told the event
  # failed after half of it was applied: the repository it removed access
  # from read "removed" while the event stayed failed, and the redelivery
  # applied the same half again.
  test "an installation event whose new repository cannot be imported applies nothing else",
       %{trusted: trusted} do
    before = Settings.fetch!()

    payload =
      installation_payload(%{
        "repositories_added" => [
          %{
            "default_branch" => "bad branch",
            "full_name" => "acme/gadget",
            "id" => 502,
            "private" => true
          }
        ],
        "repositories_removed" => [%{"id" => 501}]
      })

    assert {:error, :github_repository_auto_import_failed} =
             Access.apply("installation_repositories", payload, trusted)

    snapshot = Settings.fetch!()
    assert repository(snapshot, "widget").github_access == :available
    assert repository(snapshot, "widget").onboarding_error == nil

    assert binding(snapshot, "widget").granted_permissions ==
             binding(before, "widget").granted_permissions

    refute Enum.any?(snapshot.repositories, &(&1.github_repository == "acme/gadget"))
  end

  # Every step re-read the settings for each binding it touched. One read per
  # step, carried through the puts, must still change every binding and
  # repository the event names.
  test "one event changes every binding and repository it names", %{trusted: trusted} do
    {:ok, _snapshot} = repository!(Settings.fetch!(), "gadget", 502)
    trusted = Map.put(trusted, "gadget", trusted!("gadget", 502))

    payload =
      installation_payload(%{"repositories_removed" => [%{"id" => 501}, %{"id" => 502}]})

    assert {:ok, changed} = Access.apply("installation_repositories", payload, trusted)
    assert changed |> Enum.map(& &1.name) |> Enum.sort() == ["gadget", "widget"]

    snapshot = Settings.fetch!()

    for ref <- ["widget", "gadget"] do
      assert repository(snapshot, ref).github_access == :removed
      assert repository(snapshot, ref).onboarding_state == :blocked
      assert binding(snapshot, ref).granted_permissions == @permissions
    end
  end

  # The delivery poller replays an access event that left no receipt, as a new
  # installation's does before its repositories have bindings, and the replay
  # set every repository of the installation back to "pending", so each one
  # set up again (2026-10-04 review). An event that leaves a repository's
  # access as it was changes nothing about it.
  test "an access event that gives a repository the access it has leaves its setup alone",
       %{trusted: trusted} do
    {:ok, _snapshot} =
      Settings.put_repository(
        %{ref: "widget", onboarding_state: :ready},
        Settings.fetch!().installation.revision,
        @actor
      )

    created = installation_payload(%{"action" => "created"})
    assert {:ok, _changed} = Access.apply("installation", created, trusted)

    added = installation_payload(%{"repositories_added" => [%{"id" => 501}]})
    assert {:ok, _changed} = Access.apply("installation_repositories", added, trusted)

    assert repository(Settings.fetch!(), "widget").onboarding_state == :ready
  end

  # Archiving blocks a repository's setup. Unarchiving gave its access back
  # but left the setup blocked, and nothing takes a blocked one up again.
  test "an unarchived repository sets up again", %{trusted: trusted} do
    archived = %{
      "action" => "archived",
      "installation" => %{"id" => 41},
      "repository" => %{"full_name" => "acme/widget", "id" => 501}
    }

    assert {:ok, _changed} = Access.apply("repository", archived, trusted)
    assert repository(Settings.fetch!(), "widget").onboarding_state == :blocked

    unarchived = %{archived | "action" => "unarchived"}
    assert {:ok, _changed} = Access.apply("repository", unarchived, trusted)

    snapshot = Settings.fetch!()
    assert repository(snapshot, "widget").github_access == :available
    assert repository(snapshot, "widget").onboarding_state == :pending
    assert repository(snapshot, "widget").onboarding_error == nil
  end

  defp installation_payload(changes) do
    Map.merge(
      %{
        "action" => "added",
        "installation" => %{
          "account" => %{"id" => 99, "login" => "Acme"},
          "id" => 41,
          "permissions" => @permissions
        }
      },
      Map.new(changes)
    )
  end

  defp repository!(snapshot, ref, repository_id) do
    {:ok, snapshot} =
      Settings.put_repository(
        %{
          ref: ref,
          display_name: "acme/#{ref}",
          github_repository: "acme/#{ref}",
          base_branch: "main"
        },
        snapshot.installation.revision,
        @actor
      )

    Settings.put_github_binding(
      %{
        name: ref,
        repository_ref: ref,
        installation_id: 41,
        repository_id: repository_id,
        ryker_actor_id: 30
      },
      snapshot.installation.revision,
      @actor
    )
  end

  defp trusted!(ref, repository_id) do
    {:ok, trusted} =
      Binding.new(%{
        action_grants: binding(Settings.fetch!(), ref).action_grants,
        installation_id: 41,
        name: ref,
        repository_full_name: "acme/#{ref}",
        repository_id: repository_id,
        ryker_actor_id: 30
      })

    trusted
  end

  defp repository(snapshot, ref), do: Enum.find(snapshot.repositories, &(&1.ref == ref))
  defp binding(snapshot, ref), do: Enum.find(snapshot.github_bindings, &(&1.name == ref))
end
