defmodule Responder.Slack.ChannelConfigurationsTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.Repo

  alias Responder.Slack.{
    ChannelConfiguration,
    ChannelConfigurations,
    ChannelMembership,
    ConfigurationAction,
    ConfigurationSession
  }

  @now ~U[2026-08-28 12:00:00.000000Z]
  @catalog %{
    default_repository: "infrastructure",
    repository_refs: ["backend", "infrastructure"]
  }
  @quiet %{
    proactive: %{source: :deployment, value: false},
    shadow: %{source: :deployment, value: false}
  }

  # Until 2026-09-11 a configuration row existed only after an operator clicked a
  # setup button; a channel whose 30-minute setup card expired unanswered ran on
  # implicit deployment defaults that nothing could display or explain.
  test "a joined channel is configured with defaults before anyone clicks" do
    assert {:ok, joined} =
             ChannelConfigurations.observe_membership(
               membership(:joined, "event:join-1"),
               @catalog
             )

    assert joined.status == :joined
    assert %ChannelConfiguration{} = configuration = joined.configuration
    assert configuration.participation == :mentions
    assert configuration.repository_ref == "infrastructure"
    assert configuration.alert_policy == :reply
    assert configuration.invite_user_refs == []
    assert configuration.invite_user_group_refs == []
    assert configuration.actor_ref == nil
    assert configuration.revision == 1
    assert configuration.welcome_message_ref == nil
    assert Repo.aggregate(ConfigurationSession, :count) == 0

    assert {:ok, duplicate} =
             ChannelConfigurations.observe_membership(
               membership(:joined, "event:join-1"),
               @catalog
             )

    assert duplicate.status == :duplicate
    assert duplicate.configuration.id == configuration.id
    assert duplicate.membership.generation == 1
    assert Repo.aggregate(ChannelMembership, :count) == 1
    assert Repo.aggregate(ChannelConfiguration, :count) == 1
  end

  test "leave and re-add keep the saved configuration and retire its old welcome" do
    assert {:ok, joined} =
             ChannelConfigurations.observe_membership(
               membership(:joined, "event:join-1"),
               @catalog
             )

    assert {:ok, _bound} =
             ChannelConfigurations.bind_welcome("TCE3E523134AD", "C456", "1000.000001")

    session = reconfiguration!("event:reconfigure-before-leave") |> bind!("1000.000002", nil)

    assert {:ok, left} =
             ChannelConfigurations.observe_membership(
               membership(:left, "event:left-1"),
               @catalog
             )

    assert left.membership.status == :left
    assert left.configuration == nil
    assert Repo.get!(ConfigurationSession, session.id).status == :cancelled

    assert {:ok, rejoined} =
             ChannelConfigurations.observe_membership(
               membership(:joined, "event:join-2"),
               @catalog
             )

    assert rejoined.status == :joined
    assert rejoined.membership.generation == 2
    assert rejoined.configuration.id == joined.configuration.id
    assert rejoined.configuration.welcome_message_ref == nil
    assert Repo.aggregate(ChannelConfiguration, :count) == 1
  end

  test "absence reconciliation cannot overwrite a join newer than its Slack snapshot" do
    snapshot_started_at = DateTime.utc_now()

    assert {:ok, joined} =
             ChannelConfigurations.observe_membership(
               membership(:joined, "event:join-after-snapshot"),
               @catalog
             )

    assert {:ok, 0} =
             ChannelConfigurations.reconcile_absent("TCE3E523134AD", [], snapshot_started_at)

    assert Repo.get!(ChannelMembership, joined.membership.id).status == :joined
  end

  test "customization keeps every choice in a draft until exact confirmation saves it" do
    joined!()
    assert {:ok, _bound} = ChannelConfigurations.bind_welcome("TCE3E523134AD", "C456", "welcome")
    session = reconfiguration!() |> bind!("1000.000001", "welcome")

    assert {:ok, participation} =
             ChannelConfigurations.apply_action(
               control(session, :participation, :shadow, "event:participation")
             )

    assert participation.session.step == :repository
    assert participation.session.current_message_ref == "1000.000001"
    session = participation.session

    assert {:ok, repository} =
             ChannelConfigurations.apply_action(
               control(session, :repository, "backend", "event:repository")
             )

    assert repository.session.step == :alerts
    session = repository.session

    assert {:ok, alerts} =
             ChannelConfigurations.apply_action(control(session, :alerts, :offer, "event:alerts"))

    assert alerts.session.step == :audience
    session = alerts.session

    assert {:ok, audience} =
             ChannelConfigurations.apply_action(
               control(
                 session,
                 :audience,
                 %{user_group_refs: ["S123"], user_refs: ["U456"]},
                 "event:audience"
               )
             )

    assert audience.session.status == :confirming
    untouched = Repo.get_by!(ChannelConfiguration, channel_ref: "C456")
    assert untouched.participation == :mentions
    assert untouched.revision == 1
    session = audience.session

    assert {:ok, saved} =
             ChannelConfigurations.apply_action(control(session, :save, nil, "event:save"))

    assert saved.status == :saved
    assert saved.session.status == :saved
    assert saved.session.current_message_ref == "1000.000001"

    configuration =
      Repo.get_by!(ChannelConfiguration, workspace_ref: "TCE3E523134AD", channel_ref: "C456")

    assert configuration.id == untouched.id
    assert configuration.participation == :shadow
    assert configuration.repository_ref == "backend"
    assert configuration.alert_policy == :offer
    assert configuration.invite_user_refs == ["U456"]
    assert configuration.invite_user_group_refs == ["S123"]
    assert configuration.actor_ref == "U123"
    assert configuration.revision == 2
    assert configuration.welcome_message_ref == "welcome"
  end

  # Changing participation from the welcome must not throw away the repository,
  # alert policy or invitations somebody chose in the Q&A.
  test "the welcome changes participation only, and only for its exact revision" do
    joined!()
    session = reconfiguration!() |> bind!("card", nil)

    Enum.reduce(
      [
        {:participation, :mentions},
        {:repository, "backend"},
        {:alerts, :automatic},
        {:audience, %{user_group_refs: [], user_refs: ["U456"]}},
        {:save, nil}
      ],
      session,
      fn {action, value}, session ->
        assert {:ok, %{session: session}} =
                 ChannelConfigurations.apply_action(
                   control(session, action, value, "event:#{action}")
                 )

        session
      end
    )

    configuration = Repo.get_by!(ChannelConfiguration, channel_ref: "C456")
    assert configuration.revision == 2

    assert {:ok, saved} =
             ChannelConfigurations.change_participation(
               participation_change(configuration, :proactive, "event:proactive")
             )

    assert saved.status == :saved
    assert saved.configuration.participation == :proactive
    assert saved.configuration.repository_ref == "backend"
    assert saved.configuration.alert_policy == :automatic
    assert saved.configuration.invite_user_refs == ["U456"]
    assert saved.configuration.revision == 3
    assert saved.configuration.actor_ref == "U123"

    assert ChannelConfigurations.change_participation(
             participation_change(configuration, :mentions, "event:stale")
           ) == {:error, :configuration_revision_stale}

    assert ChannelConfigurations.change_participation(%{
             participation_change(saved.configuration, :mentions, "event:foreign")
             | configuration_ref: Ecto.UUID.generate()
           }) == {:error, :configuration_not_found}

    assert {:ok, unchanged} =
             ChannelConfigurations.change_participation(
               participation_change(saved.configuration, :proactive, "event:same")
             )

    assert unchanged.status == :unchanged
    assert unchanged.configuration.revision == 3

    assert {:ok, _left} =
             ChannelConfigurations.observe_membership(membership(:left, "event:left"), @catalog)

    assert ChannelConfigurations.change_participation(
             participation_change(saved.configuration, :mentions, "event:after-leave")
           ) == {:error, :configuration_membership_not_joined}
  end

  test "controls are fenced by actor channel current card revision and expiry" do
    joined!()
    session = reconfiguration!() |> bind!("3000.000001", nil)

    assert ChannelConfigurations.apply_action(%{
             control(session, :participation, :mentions, "event:cross-actor")
             | actor_ref: "U999"
           }) == {:error, :configuration_actor_mismatch}

    assert ChannelConfigurations.apply_action(%{
             control(session, :participation, :mentions, "event:cross-channel")
             | channel_ref: "C999"
           }) == {:error, :configuration_channel_mismatch}

    assert ChannelConfigurations.apply_action(%{
             control(session, :participation, :mentions, "event:stale-message")
             | message_ref: "old-card"
           }) == {:error, :configuration_message_mismatch}

    Repo.update_all(
      from(saved in ConfigurationSession, where: saved.id == ^session.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert ChannelConfigurations.apply_action(
             control(session, :participation, :mentions, "event:expired")
           ) == {:error, :configuration_expired}

    assert Repo.get!(ConfigurationSession, session.id).status == :expired
  end

  test "channel deletion removes saved configuration and every setup draft" do
    joined!()
    _session = reconfiguration!() |> bind!("4000.000001", nil)

    assert {:ok, deleted} =
             ChannelConfigurations.observe_membership(
               membership(:deleted, "event:delete"),
               @catalog
             )

    assert deleted.membership.status == :deleted
    refute Repo.get_by(ChannelConfiguration, channel_ref: "C456")
    assert Repo.aggregate(ConfigurationSession, :count) == 0
  end

  test "reserving a managed artifact channel cancels setup and removes feed configuration" do
    joined!()
    active = reconfiguration!("event:race-before-reservation")

    assert :ok = ChannelConfigurations.reserve_managed_channel("TCE3E523134AD", "C456")

    assert Repo.get!(ConfigurationSession, active.id).status == :cancelled
    refute Repo.get_by(ChannelConfiguration, workspace_ref: "TCE3E523134AD", channel_ref: "C456")

    assert Repo.get_by!(ChannelMembership, workspace_ref: "TCE3E523134AD", channel_ref: "C456").status ==
             :joined

    assert :ok = ChannelConfigurations.reserve_managed_channel("TCE3E523134AD", "C456")
  end

  test "an addressed operator can start one idempotent reconfiguration in its current thread" do
    joined!()

    request = %{
      actor_ref: "U123",
      channel_ref: "C456",
      event_ref: "event:reconfigure",
      occurred_at: @now,
      thread_ref: "4999.000001",
      workspace_ref: "TCE3E523134AD"
    }

    assert {:ok, started} = ChannelConfigurations.start_reconfiguration(request, @catalog)
    assert started.status == :started
    assert started.session.step == :participation
    assert started.session.root_message_ref == "4999.000001"
    assert started.session.response_thread_ref == "4999.000001"
    refute Map.has_key?(started.session.draft, "customizing")

    assert {:ok, duplicate} = ChannelConfigurations.start_reconfiguration(request, @catalog)
    assert duplicate.status == :duplicate
    assert duplicate.session.id == started.session.id
  end

  test "membership reconciliation repairs unknown, left, and deleted channels without inventing duplicates" do
    assert {:ok, left} =
             ChannelConfigurations.observe_membership(
               membership(:left, "event:left-without-join"),
               @catalog
             )

    assert left.status == :left
    assert left.configuration == nil
    assert left.membership.joined_at == @now

    deleted_request =
      membership(:deleted, "event:delete-without-join")
      |> Map.put(:channel_ref, "C789")

    assert {:ok, deleted} = ChannelConfigurations.observe_membership(deleted_request, @catalog)
    assert deleted.status == :deleted
    assert deleted.membership.joined_at == nil

    assert {:ok, repaired} =
             ChannelConfigurations.reconcile_joined(
               "TCE3E523134AD",
               Enum.map(
                 ["C456", "C789", "C999"],
                 &%{channel_ref: &1, external_shared: false, private: false}
               ),
               @catalog
             )

    assert Enum.map(repaired, & &1.membership.channel_ref) == ["C456", "C789", "C999"]
    assert Enum.all?(repaired, &(&1.membership.status == :joined))
    assert Enum.all?(repaired, &(&1.status == :joined))
    assert Enum.all?(repaired, &match?(%ChannelConfiguration{revision: 1}, &1.configuration))
    assert Repo.aggregate(ConfigurationSession, :count) == 0

    assert {:ok, unchanged} =
             ChannelConfigurations.reconcile_joined(
               "TCE3E523134AD",
               [%{channel_ref: "C456", external_shared: false, private: false}],
               @catalog
             )

    assert hd(unchanged).status == :unchanged
    assert hd(unchanged).configuration.id == hd(repaired).configuration.id

    assert {:ok, [private]} =
             ChannelConfigurations.reconcile_joined(
               "TCE3E523134AD",
               [%{channel_ref: "C456", external_shared: true, private: true}],
               @catalog
             )

    assert private.status == :unchanged
    assert private.membership.private == true
    assert private.membership.external_shared == true
  end

  test "reconfiguration, prompt binding, and action identities are exact and idempotent" do
    request = %{
      actor_ref: "U123",
      channel_ref: "C456",
      event_ref: "event:reconfigure-without-membership",
      occurred_at: @now,
      thread_ref: nil,
      workspace_ref: "TCE3E523134AD"
    }

    assert ChannelConfigurations.start_reconfiguration(request, @catalog) ==
             {:error, :configuration_membership_not_joined}

    joined!()
    session = reconfiguration!()

    assert {:ok, existing} =
             ChannelConfigurations.start_reconfiguration(
               %{request | event_ref: "event:existing"},
               @catalog
             )

    assert existing.status == :existing
    assert existing.session.id == session.id

    assert ChannelConfigurations.bind_prompt(Ecto.UUID.generate(), 1, "card", nil) ==
             {:error, :configuration_session_not_found}

    assert ChannelConfigurations.bind_prompt(session.id, session.revision + 1, "card", nil) ==
             {:error, :configuration_revision_stale}

    bound = bind!(session, "card:one", nil)

    assert ChannelConfigurations.bind_prompt(bound.id, bound.revision, "card:two", nil) ==
             {:error, :configuration_prompt_already_bound}

    conflict = %{request | event_ref: session.start_event_ref, thread_ref: "different-thread"}

    assert ChannelConfigurations.start_reconfiguration(conflict, @catalog) ==
             {:error, :configuration_reconfiguration_conflict}

    assert ChannelConfigurations.fetch_session(bound.id) == {:ok, bound}

    assert ChannelConfigurations.fetch_session("not-a-uuid") ==
             {:error, :configuration_session_not_found}
  end

  test "restart, cancellation, and audience choices preserve one session and its message" do
    joined!()
    session = reconfiguration!() |> bind!("card:root", nil)

    assert {:ok, participation} =
             ChannelConfigurations.apply_action(
               control(session, :participation, :mentions, "event:mentions")
             )

    assert {:ok, restarted} =
             ChannelConfigurations.apply_action(
               control(participation.session, :restart, nil, "event:restart")
             )

    assert restarted.status == :restarted
    assert restarted.session.step == :participation
    assert restarted.session.current_message_ref == "card:root"
    assert restarted.session.draft["participation"] == nil

    assert {:ok, duplicate} =
             ChannelConfigurations.apply_action(
               control(participation.session, :restart, nil, "event:restart")
             )

    assert duplicate.status == :duplicate
    assert Repo.aggregate(ConfigurationAction, :count) == 2

    assert {:ok, participation} =
             ChannelConfigurations.apply_action(
               control(restarted.session, :participation, :mentions, "event:mentions-again")
             )

    assert ChannelConfigurations.apply_action(
             control(participation.session, :repository, "not-offered", "event:not-offered")
           ) == {:error, :configuration_repository_not_offered}

    assert {:ok, repository} =
             ChannelConfigurations.apply_action(
               control(participation.session, :repository, "backend", "event:repository-none")
             )

    assert {:ok, alerts} =
             ChannelConfigurations.apply_action(
               control(repository.session, :alerts, :reply, "event:alerts-none")
             )

    assert {:ok, audience} =
             ChannelConfigurations.apply_action(
               control(alerts.session, :audience, :none, "event:audience-none")
             )

    assert audience.session.status == :confirming

    assert {:ok, cancelled} =
             ChannelConfigurations.apply_action(
               control(audience.session, :cancel, nil, "event:cancel")
             )

    assert cancelled.status == :cancelled
    assert Repo.get_by!(ChannelConfiguration, channel_ref: "C456").revision == 1
  end

  test "the welcome binds one message per configuration" do
    assert ChannelConfigurations.bind_welcome("TCE3E523134AD", "C456", "1.000001") ==
             {:error, :configuration_not_found}

    joined!()

    assert {:ok, bound} = ChannelConfigurations.bind_welcome("TCE3E523134AD", "C456", "1.000001")
    assert bound.welcome_message_ref == "1.000001"

    assert {:ok, same} = ChannelConfigurations.bind_welcome("TCE3E523134AD", "C456", "1.000001")
    assert same.revision == bound.revision

    assert ChannelConfigurations.bind_welcome("TCE3E523134AD", "C456", "2.000002") ==
             {:error, :configuration_welcome_already_bound}
  end

  test "effective settings fold emergency overrides over the saved configuration without mutating" do
    catalog =
      Map.merge(@catalog, %{
        on_call_count: 2,
        repository_urls: %{"backend" => "https://github.com/acme/backend"}
      })

    assert {:ok, unconfigured} =
             ChannelConfigurations.effective_settings("TCE3E523134AD", "C456", catalog, @quiet)

    assert unconfigured["configuration_ref"] == nil
    assert unconfigured["revision"] == nil
    assert unconfigured["default_repository"] == "infrastructure"
    assert unconfigured["participation"] == %{"source" => "deployment", "value" => "mentions"}

    joined!()
    configuration = Repo.get_by!(ChannelConfiguration, channel_ref: "C456")

    assert {:ok, defaults} =
             ChannelConfigurations.effective_settings("TCE3E523134AD", "C456", catalog, %{
               proactive: %{source: :configuration, value: false},
               shadow: %{source: :configuration, value: false}
             })

    assert defaults == %{
             "alert_policy" => "reply",
             "configuration_ref" => configuration.id,
             "customized_by" => nil,
             "default_repository" => "infrastructure",
             "invitations" => %{"on_call_count" => 2, "user_group_refs" => [], "user_refs" => []},
             "observation" => %{"on" => false, "source" => "configuration"},
             "participation" => %{"source" => "configuration", "value" => "mentions"},
             "repositories" => [
               %{"ref" => "backend", "url" => "https://github.com/acme/backend"},
               %{"ref" => "infrastructure", "url" => nil}
             ],
             "revision" => 1
           }

    assert {:ok, overridden} =
             ChannelConfigurations.effective_settings("TCE3E523134AD", "C456", catalog, %{
               proactive: %{source: :channel, value: true},
               shadow: %{source: :configuration, value: false}
             })

    assert overridden["participation"] == %{"source" => "channel", "value" => "proactive"}

    assert {:ok, observing} =
             ChannelConfigurations.effective_settings("TCE3E523134AD", "C456", catalog, %{
               proactive: %{source: :configuration, value: true},
               shadow: %{source: :workspace, value: true}
             })

    assert observing["participation"] == %{"source" => "workspace", "value" => "shadow"}
    assert observing["observation"] == %{"on" => true, "source" => "workspace"}

    assert Repo.get_by!(ChannelConfiguration, channel_ref: "C456").revision == 1

    assert ChannelConfigurations.effective_settings("TCE3E523134AD", "C456", catalog, %{
             proactive: true
           }) == {:error, {:invalid_channel_configuration, :overrides}}

    assert ChannelConfigurations.effective_settings(
             "TCE3E523134AD",
             "C456",
             Map.put(catalog, :repository_urls, %{"backend" => "http://insecure.example"}),
             @quiet
           ) == {:error, {:invalid_channel_configuration, :repository_urls}}
  end

  test "all public configuration boundaries reject malformed source authority" do
    assert ChannelConfigurations.observe_membership(:invalid, @catalog) ==
             {:error, {:invalid_channel_configuration, :membership}}

    assert ChannelConfigurations.observe_membership(
             [actor_ref: "U", actor_ref: "U", channel_ref: "C"],
             @catalog
           ) == {:error, {:invalid_channel_configuration, :membership}}

    assert ChannelConfigurations.observe_membership(
             %{membership(:joined, "event:bad-kind") | kind: :renamed},
             @catalog
           ) == {:error, {:invalid_channel_configuration, :kind}}

    assert ChannelConfigurations.observe_membership(
             membership(:joined, "event:bad-catalog"),
             %{default_repository: "missing", repository_refs: ["backend"]}
           ) == {:error, {:invalid_channel_configuration, :catalog}}

    assert ChannelConfigurations.observe_membership(
             membership(:joined, "event:bad-catalog-shape"),
             %{}
           ) == {:error, {:invalid_channel_configuration, :catalog}}

    assert ChannelConfigurations.reconcile_joined("TCE3E523134AD", :invalid, @catalog) ==
             {:error, {:invalid_channel_configuration, :channel_refs}}

    assert ChannelConfigurations.reconcile_joined(
             "TCE3E523134AD",
             [
               %{channel_ref: "C1", private: false},
               %{channel_ref: "C1", private: false}
             ],
             @catalog
           ) ==
             {:error, {:invalid_channel_configuration, :channel_refs}}

    assert ChannelConfigurations.bind_prompt("bad", 0, "", :invalid) ==
             {:error, {:invalid_channel_configuration, :session_ref}}

    assert ChannelConfigurations.bind_welcome("", "C456", "1.000001") ==
             {:error, {:invalid_channel_configuration, :workspace_ref}}

    assert ChannelConfigurations.apply_action(%{}) ==
             {:error, {:invalid_channel_configuration, :action}}

    assert ChannelConfigurations.change_participation(%{}) ==
             {:error, {:invalid_channel_configuration, :participation_change}}

    joined!()
    configuration = Repo.get_by!(ChannelConfiguration, channel_ref: "C456")

    assert ChannelConfigurations.change_participation(%{
             participation_change(configuration, :proactive, "event:bad-participation")
             | participation: :loud
           }) == {:error, {:invalid_channel_configuration, :participation}}

    assert ChannelConfigurations.change_participation(%{
             participation_change(configuration, :proactive, "event:bad-ref")
             | configuration_ref: "not-a-uuid"
           }) == {:error, {:invalid_channel_configuration, :configuration_ref}}

    session = reconfiguration!("event:join-invalid-actions") |> bind!("card:invalid", nil)

    assert ChannelConfigurations.apply_action(%{
             control(session, :participation, :mentions, "event:wrong-thread")
             | thread_ref: "other-thread"
           }) == {:error, :configuration_thread_mismatch}

    for retired <- [:safe_defaults, :be_proactive, :customize, :move_thread, :move_channel] do
      assert ChannelConfigurations.apply_action(%{
               control(session, :participation, :mentions, "event:#{retired}")
               | action: retired
             }) == {:error, {:invalid_channel_configuration, :action}}
    end

    assert ChannelConfigurations.apply_action(
             control(session, :audience, %{unexpected: true}, "event:wrong-step")
           ) == {:error, :configuration_action_mismatch}
  end

  defp joined!(event_ref \\ "event:join") do
    assert {:ok, result} =
             ChannelConfigurations.observe_membership(membership(:joined, event_ref), @catalog)

    result
  end

  defp reconfiguration!(event_ref \\ "event:reconfigure") do
    assert {:ok, %{session: session}} =
             ChannelConfigurations.start_reconfiguration(
               %{
                 actor_ref: "U123",
                 channel_ref: "C456",
                 event_ref: event_ref,
                 occurred_at: @now,
                 thread_ref: nil,
                 workspace_ref: "TCE3E523134AD"
               },
               @catalog
             )

    session
  end

  defp bind!(session, message_ref, thread_ref) do
    assert {:ok, bound} =
             ChannelConfigurations.bind_prompt(
               session.id,
               session.revision,
               message_ref,
               thread_ref
             )

    bound
  end

  defp membership(kind, event_ref) do
    %{
      actor_ref: "U123",
      channel_ref: "C456",
      event_ref: event_ref,
      kind: kind,
      occurred_at: @now,
      workspace_ref: "TCE3E523134AD"
    }
  end

  defp control(session, action, value, event_ref) do
    %{
      action: action,
      actor_ref: "U123",
      channel_ref: "C456",
      event_ref: event_ref,
      message_ref: session.current_message_ref,
      occurred_at: @now,
      session_ref: session.id,
      source: :control,
      thread_ref: session.response_thread_ref,
      value: value,
      workspace_ref: "TCE3E523134AD"
    }
  end

  defp participation_change(configuration, participation, event_ref) do
    %{
      actor_ref: "U123",
      channel_ref: "C456",
      configuration_ref: configuration.id,
      event_ref: event_ref,
      expected_revision: configuration.revision,
      occurred_at: @now,
      participation: participation,
      workspace_ref: "TCE3E523134AD"
    }
  end
end
