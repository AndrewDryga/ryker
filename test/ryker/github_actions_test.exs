defmodule Ryker.GitHubActionsTest do
  use Ryker.DataCase, async: false
  alias Ryker.Config
  alias Ryker.Fixtures.GitHubActions.Requester
  alias Ryker.GitHub
  alias Ryker.GitHubActions
  alias Ryker.Settings

  @actor "control-plane:local"

  setup do
    {:ok, settings} = Settings.initialize(@actor)

    {:ok, settings} =
      Settings.save_github(
        %{
          enabled: true,
          app_id: 1234,
          app_slug: "ryker-test",
          bot_actor_id: 4321,
          bot_login: "ryker-test[bot]"
        },
        settings.installation.revision,
        @actor
      )

    {:ok, settings} =
      Settings.put_repository(
        %{ref: "widget", github_repository: "acme/widget"},
        settings.installation.revision,
        @actor
      )

    {:ok, settings} =
      Settings.put_github_binding(
        %{
          name: "widget-app",
          repository_ref: "widget",
          installation_id: 41,
          repository_id: 99,
          ryker_actor_id: 4321
        },
        settings.installation.revision,
        @actor
      )

    %{settings: settings}
  end

  test "one selection freezes one authenticated request and repeated clicks reuse it" do
    {:ok, binding} =
      GitHub.Binding.new(%{
        name: "widget-app",
        repository_full_name: "acme/widget",
        repository_id: 99,
        installation_id: 41,
        ryker_actor_id: 4321,
        work_profile: %{
          policy: "widget-conversation",
          policy_digest: String.duplicate("b", 64),
          repository_ref: "widget"
        }
      })

    Config.put_override(:github, %{server: %{bindings: %{"widget-app" => binding}}})

    assert {:ok, review} =
             GitHubActions.review("widget-app", "writer-token", 42, requester: Requester)

    assert [%{"selected" => true, "thread_id" => "thread-one"}] = review.findings
    assert_received {:review_read, %{"number" => 42}}

    assert {:ok, first} =
             GitHubActions.fix_review(
               "widget-app",
               "writer-token",
               42,
               review.snapshot,
               ["thread-one"],
               requester: Requester
             )

    assert first.url == "https://github.com/acme/widget/pull/42"
    assert first.status == :recorded
    assert first.entry.actor_ref == "github-user:7"
    assert first.entry.content["action_evidence"]["head"] == String.duplicate("a", 40)

    assert [%{"body" => "Handle empty input."}] =
             first.entry.content["action_evidence"]["findings"]

    assert_received {:review_read, _variables}

    assert {:ok, duplicate} =
             GitHubActions.fix_review(
               "widget-app",
               "writer-token",
               42,
               review.snapshot,
               ["thread-one"],
               requester: Requester
             )

    assert duplicate.entry.id == first.entry.id
    assert duplicate.status == :duplicate
    refute_received {:review_read, _variables}
  end

  test "a repository writer is checked on every action without becoming an operator" do
    for _click <- 1..2 do
      assert {:ok, access} =
               GitHubActions.authorize("widget-app", "writer-token", requester: Requester)

      assert access.actor == %{"id" => 7, "login" => "ada", "type" => "User"}
      assert access.repository.ref == "widget"
      assert_received :user_checked
      assert_received :repository_checked
    end
  end

  test "readers, revoked tokens and different repository identities cannot start work" do
    for token <- ["reader-token", "revoked-token", "wrong-repository"] do
      assert GitHubActions.authorize("widget-app", token, requester: Requester) ==
               {:error, :repository_access_required}
    end
  end

  test "disconnecting the app refuses an existing user session before any GitHub request", %{
    settings: settings
  } do
    assert {:ok, _saved} =
             Settings.save_github(%{enabled: false}, settings.installation.revision, @actor)

    assert GitHubActions.authorize("widget-app", "writer-token", requester: Requester) ==
             {:error, :repository_access_required}

    refute_received :user_checked
  end

  test "unconfigured sign-in and off-site return URLs do not start OAuth" do
    assert GitHubActions.begin_sign_in("/github/actions/review/example", 1000) ==
             {:error, :github_sign_in_not_configured}

    assert GitHubActions.begin_sign_in("//another.example", 1000) ==
             {:error, :invalid_action_link}
  end
end
