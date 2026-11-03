defmodule Ryker.Slack.TaskAccessTest do
  use Ryker.DataCase, async: false
  alias Ryker.Fixtures.{ChannelEnvironments, Corrections}
  alias Ryker.Settings
  alias Ryker.Slack.{ChannelConfiguration, TaskAccess}

  setup do
    source = Corrections.correction!(actor_kind: :bot)
    ChannelEnvironments.environment!("proactive", %{repositories: ["ryker", "api"]})

    assert {:ok, settings} =
             Settings.save_slack(
               %{
                 enabled: true,
                 workspace_ref: source.entry.source_ref,
                 bot_ref: "A0123456789",
                 bot_user_ref: "U0123456789",
                 operators: ["UOPERATOR"],
                 default_participation: :mentions
               },
               Settings.fetch!().installation.revision,
               "control-plane:local"
             )

    configuration =
      Repo.insert!(%ChannelConfiguration{
        workspace_ref: source.entry.source_ref,
        channel_ref: "C1",
        participation: :proactive,
        environment_ref: "proactive",
        alert_policy: :reply,
        revision: 1,
        actor_ref: "control-plane:local",
        saved_at: Repo.now!()
      })

    policies =
      Map.new(["ryker", "api"], fn repository ->
        {repository,
         %{
           name: "#{repository}-contributor",
           digest: String.duplicate("b", 64),
           repository_ref: repository
         }}
      end)

    options = %{
      workspace_ref: source.entry.source_ref,
      authority_configuration: TaskAccess.authority_configuration(settings),
      environments: %{"proactive" => %{contributor_policies: policies}},
      conversation_environment: fn workspace, channel ->
        case Repo.fetch(ChannelConfiguration.Query.by_channel(workspace, channel)) do
          {:ok, configuration} -> configuration.environment_ref
          _missing -> nil
        end
      end
    }

    %{
      entry: source.entry,
      claim: source.claim,
      episode: source.claim.episode,
      configuration: configuration,
      options: options
    }
  end

  test "the current turn knows whether its channel permits proactive fixes", %{
    claim: claim,
    configuration: configuration
  } do
    assert {:ok, submission} = Ryker.Inspectors.submission(claim)
    assert submission["context"]["operator_context"]["proactive_fixes"] == true
    Repo.update!(Ecto.Changeset.change(configuration, participation: :mentions))
    assert {:ok, submission} = Ryker.Inspectors.submission(claim)
    assert submission["context"]["operator_context"]["proactive_fixes"] == false
  end

  test "proactive mode permits every configured writable target without a separate repository opt-in",
       %{entry: entry, options: options} do
    for repository <- ["ryker", "api"] do
      assert {:ok, policy} = TaskAccess.authorize_proactive(entry, repository, options)
      assert policy.repository_ref == repository
    end

    assert TaskAccess.authorize_proactive(entry, "unconfigured", options) ==
             {:error, {:slack_task_outside_environment, "unconfigured"}}
  end

  test "current mentions and shadow choices override any earlier proactive briefing", %{
    entry: entry,
    configuration: configuration,
    options: options
  } do
    for mode <- [:mentions, :shadow] do
      Repo.update!(Ecto.Changeset.change(configuration, participation: mode))
      refute TaskAccess.proactive?(entry)

      assert TaskAccess.authorize_proactive(entry, "ryker", options) ==
               {:error, :task_instruction_not_authorized}
    end
  end

  test "an inherited proactive installation default grants the channel mode", %{
    entry: entry,
    configuration: configuration,
    options: options
  } do
    Repo.update!(Ecto.Changeset.change(configuration, participation: nil))
    refute TaskAccess.proactive?(entry)

    assert {:ok, settings} =
             Settings.save_default_participation(:proactive, "slack:user:UOPERATOR")

    assert TaskAccess.proactive?(entry)

    assert {:ok, _policy} =
             TaskAccess.authorize_proactive(entry, "ryker", %{
               options
               | authority_configuration: TaskAccess.authority_configuration(settings)
             })
  end

  test "a channel without an environment or a stale runtime policy cannot start a fix", %{
    entry: entry,
    configuration: configuration,
    options: options
  } do
    assert TaskAccess.authorize_proactive(entry, "ryker", %{
             options
             | authority_configuration: %{}
           }) ==
             {:error, :task_instruction_not_authorized}

    Repo.update!(Ecto.Changeset.change(configuration, environment_ref: nil))

    assert TaskAccess.authorize_proactive(entry, "ryker", options) ==
             {:error, {:slack_task_policy_not_configured, "ryker"}}
  end

  test "DMs, shadow replays and another workspace cannot borrow channel permission", %{
    entry: entry,
    episode: episode
  } do
    refute TaskAccess.proactive?(%{
             entry
             | destination_conversation_ref: "slack:#{entry.source_ref}:D1"
           })

    refute TaskAccess.proactive?(%{entry | execution_mode: :shadow})
    refute TaskAccess.proactive?(%{entry | source_ref: "TOTHER"})
    refute TaskAccess.proactive?(%{episode | execution_mode: :shadow})
    assert TaskAccess.proactive?(episode)
  end

  test "leaving a channel withdraws proactive starts", %{entry: entry} do
    membership =
      Repo.fetch!(Ryker.Slack.ChannelMembership.Query.by_channel(entry.source_ref, "C1"))

    Repo.update!(Ecto.Changeset.change(membership, status: :left, left_at: Repo.now!()))
    refute TaskAccess.proactive?(entry)
  end

  test "a value without authenticated ingress cannot use the channel grant", %{options: options} do
    assert TaskAccess.authorize_proactive(%{}, "ryker", options) ==
             {:error, :task_instruction_not_authorized}
  end
end
