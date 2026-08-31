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

  test "a duplicate join keeps one membership generation and one setup session" do
    request = membership(:joined, "event:join-1")

    assert {:ok, first} = ChannelConfigurations.observe_membership(request, @catalog)
    assert first.status == :joined
    assert first.membership.generation == 1
    assert first.session.status == :asking
    assert first.session.step == :participation
    assert first.session.initiator_ref == "U123"

    assert {:ok, duplicate} = ChannelConfigurations.observe_membership(request, @catalog)
    assert duplicate.status == :duplicate
    assert duplicate.session.id == first.session.id

    assert Repo.aggregate(ChannelMembership, :count) == 1
    assert Repo.aggregate(ConfigurationSession, :count) == 1
  end

  test "leave and re-add cancel the old draft and open one fresh generation" do
    assert {:ok, joined} =
             ChannelConfigurations.observe_membership(
               membership(:joined, "event:join-1"),
               @catalog
             )

    assert {:ok, left} =
             ChannelConfigurations.observe_membership(
               membership(:left, "event:left-1"),
               @catalog
             )

    assert left.membership.status == :left
    assert Repo.get!(ConfigurationSession, joined.session.id).status == :cancelled

    assert {:ok, rejoined} =
             ChannelConfigurations.observe_membership(
               membership(:joined, "event:join-2"),
               @catalog
             )

    assert rejoined.status == :joined
    assert rejoined.membership.generation == 2
    assert rejoined.session.id != joined.session.id
    assert rejoined.session.membership_generation == 2
  end

  test "customization keeps every choice in a draft until exact confirmation saves it" do
    session = joined_session!()
    session = bind!(session, "1000.000001", nil)

    assert {:ok, customized} =
             ChannelConfigurations.apply_action(
               control(session, :customize, nil, "event:customize")
             )

    refute Repo.get_by(ChannelConfiguration, workspace_ref: "T123", channel_ref: "C456")
    session = bind!(customized.session, "1000.000002", nil)

    assert {:ok, participation} =
             ChannelConfigurations.apply_action(
               control(session, :participation, :shadow, "event:participation")
             )

    assert participation.session.step == :repository
    session = bind!(participation.session, "1000.000003", "1000.000001")

    assert {:ok, repository} =
             ChannelConfigurations.apply_action(
               control(session, :repository, "backend", "event:repository")
             )

    assert repository.session.step == :alerts
    session = bind!(repository.session, "1000.000004", "1000.000001")

    assert {:ok, alerts} =
             ChannelConfigurations.apply_action(control(session, :alerts, :offer, "event:alerts"))

    assert alerts.session.step == :audience
    session = bind!(alerts.session, "1000.000005", "1000.000001")

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
    refute Repo.get_by(ChannelConfiguration, workspace_ref: "T123", channel_ref: "C456")
    session = bind!(audience.session, "1000.000006", "1000.000001")

    assert {:ok, saved} =
             ChannelConfigurations.apply_action(control(session, :save, nil, "event:save"))

    assert saved.status == :saved
    assert saved.session.status == :saved

    configuration =
      Repo.get_by!(ChannelConfiguration, workspace_ref: "T123", channel_ref: "C456")

    assert configuration.participation == :shadow
    assert configuration.repository_ref == "backend"
    assert configuration.alert_policy == :offer
    assert configuration.invite_user_refs == ["U456"]
    assert configuration.invite_user_group_refs == ["S123"]
    assert configuration.actor_ref == "U123"
    assert configuration.revision == 1
  end

  test "safe defaults and proactive are complete idempotent quick saves" do
    defaults = joined_session!("event:join-defaults") |> bind!("2000.000001", nil)

    assert {:ok, result} =
             ChannelConfigurations.apply_action(
               control(defaults, :safe_defaults, nil, "event:defaults")
             )

    assert result.status == :saved

    configuration = Repo.get_by!(ChannelConfiguration, channel_ref: "C456")
    assert configuration.participation == :mentions
    assert configuration.repository_ref == "infrastructure"
    assert configuration.alert_policy == :reply

    assert {:ok, duplicate} =
             ChannelConfigurations.apply_action(
               control(defaults, :safe_defaults, nil, "event:defaults")
             )

    assert duplicate.status == :duplicate
    assert Repo.aggregate(ConfigurationAction, :count) == 1
  end

  test "controls are fenced by actor channel current card revision and expiry" do
    session = joined_session!() |> bind!("3000.000001", nil)

    assert ChannelConfigurations.apply_action(%{
             control(session, :customize, nil, "event:cross-actor")
             | actor_ref: "U999"
           }) == {:error, :configuration_actor_mismatch}

    assert ChannelConfigurations.apply_action(%{
             control(session, :customize, nil, "event:cross-channel")
             | channel_ref: "C999"
           }) == {:error, :configuration_channel_mismatch}

    assert ChannelConfigurations.apply_action(%{
             control(session, :customize, nil, "event:stale-message")
             | message_ref: "old-card"
           }) == {:error, :configuration_message_mismatch}

    Repo.update_all(
      from(saved in ConfigurationSession, where: saved.id == ^session.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert ChannelConfigurations.apply_action(control(session, :customize, nil, "event:expired")) ==
             {:error, :configuration_expired}

    assert Repo.get!(ConfigurationSession, session.id).status == :expired
  end

  test "channel deletion removes saved configuration and every setup draft" do
    session = joined_session!() |> bind!("4000.000001", nil)

    assert {:ok, _saved} =
             ChannelConfigurations.apply_action(
               control(session, :safe_defaults, nil, "event:save-before-delete")
             )

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
    session = joined_session!() |> bind!("4100.000001", nil)

    assert {:ok, _saved} =
             ChannelConfigurations.apply_action(
               control(session, :safe_defaults, nil, "event:save-before-reservation")
             )

    assert {:ok, %{session: active}} =
             ChannelConfigurations.start_reconfiguration(
               %{
                 actor_ref: "U123",
                 channel_ref: "C456",
                 event_ref: "event:race-before-reservation",
                 occurred_at: @now,
                 thread_ref: nil,
                 workspace_ref: "T123"
               },
               @catalog
             )

    assert :ok = ChannelConfigurations.reserve_managed_channel("T123", "C456")

    assert Repo.get!(ConfigurationSession, session.id).status == :saved
    assert Repo.get!(ConfigurationSession, active.id).status == :cancelled
    refute Repo.get_by(ChannelConfiguration, workspace_ref: "T123", channel_ref: "C456")

    assert Repo.get_by!(ChannelMembership, workspace_ref: "T123", channel_ref: "C456").status ==
             :joined

    assert :ok = ChannelConfigurations.reserve_managed_channel("T123", "C456")
  end

  test "an addressed operator can start one idempotent reconfiguration in its current thread" do
    original = joined_session!() |> bind!("5000.000001", nil)

    assert {:ok, _saved} =
             ChannelConfigurations.apply_action(
               control(original, :safe_defaults, nil, "event:initial-save")
             )

    request = %{
      actor_ref: "U123",
      channel_ref: "C456",
      event_ref: "event:reconfigure",
      occurred_at: @now,
      thread_ref: "4999.000001",
      workspace_ref: "T123"
    }

    assert {:ok, started} = ChannelConfigurations.start_reconfiguration(request, @catalog)
    assert started.status == :started
    assert started.session.root_message_ref == "4999.000001"
    assert started.session.response_thread_ref == "4999.000001"
    assert started.session.id != original.id

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
    assert left.session == nil
    assert left.membership.joined_at == @now

    deleted_request =
      membership(:deleted, "event:delete-without-join")
      |> Map.put(:channel_ref, "C789")

    assert {:ok, deleted} = ChannelConfigurations.observe_membership(deleted_request, @catalog)
    assert deleted.status == :deleted
    assert deleted.membership.joined_at == nil

    assert {:ok, repaired} =
             ChannelConfigurations.reconcile_joined("T123", ["C456", "C789", "C999"], @catalog)

    assert Enum.map(repaired, & &1.membership.channel_ref) == ["C456", "C789", "C999"]
    assert Enum.all?(repaired, &(&1.membership.status == :joined))
    assert Enum.all?(repaired, &match?(%ConfigurationSession{}, &1.session))

    assert {:ok, unchanged} =
             ChannelConfigurations.reconcile_joined("T123", ["C456"], @catalog)

    assert hd(unchanged).status == :unchanged
  end

  test "reconfiguration, prompt binding, and action identities are exact and idempotent" do
    request = %{
      actor_ref: "U123",
      channel_ref: "C456",
      event_ref: "event:reconfigure-without-membership",
      occurred_at: @now,
      thread_ref: nil,
      workspace_ref: "T123"
    }

    assert ChannelConfigurations.start_reconfiguration(request, @catalog) ==
             {:error, :configuration_membership_not_joined}

    session = joined_session!()

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

  test "quick setup, movement, restart, cancellation, and audience choices preserve one session" do
    proactive = joined_session!("event:join-proactive") |> bind!("card:proactive", nil)

    assert {:ok, saved} =
             ChannelConfigurations.apply_action(
               control(proactive, :be_proactive, nil, "event:be-proactive")
             )

    assert saved.status == :saved
    assert Repo.get_by!(ChannelConfiguration, channel_ref: "C456").participation == :proactive

    # Use a second membership generation so every remaining transition has an active draft.
    assert {:ok, _left} =
             ChannelConfigurations.observe_membership(
               membership(:left, "event:left-after-proactive"),
               @catalog
             )

    session = joined_session!("event:rejoin-transitions") |> bind!("card:root", nil)

    assert {:ok, moved} =
             ChannelConfigurations.apply_action(
               control(session, :move_thread, nil, "event:move-thread")
             )

    assert moved.status == :moved
    assert moved.session.response_thread_ref == "card:root"
    moved = bind!(moved.session, "card:moved-thread", "card:root")

    assert {:ok, channel} =
             ChannelConfigurations.apply_action(
               control(moved, :move_channel, nil, "event:move-channel")
             )

    assert channel.session.response_thread_ref == nil
    channel = bind!(channel.session, "card:moved-channel", nil)

    assert {:ok, restarted} =
             ChannelConfigurations.apply_action(control(channel, :restart, nil, "event:restart"))

    assert restarted.status == :restarted
    assert restarted.session.step == :participation
    restarted = bind!(restarted.session, "card:restarted", nil)

    assert {:ok, customized} =
             ChannelConfigurations.apply_action(
               control(restarted, :customize, nil, "event:customize-none")
             )

    customized = bind!(customized.session, "card:participation", nil)

    assert {:ok, participation} =
             ChannelConfigurations.apply_action(
               control(customized, :participation, :mentions, "event:mentions")
             )

    participation = bind!(participation.session, "card:repository", nil)

    assert ChannelConfigurations.apply_action(
             control(participation, :repository, "not-offered", "event:not-offered")
           ) == {:error, :configuration_repository_not_offered}

    assert {:ok, repository} =
             ChannelConfigurations.apply_action(
               control(participation, :repository, "backend", "event:repository-none")
             )

    repository = bind!(repository.session, "card:alerts", nil)

    assert {:ok, alerts} =
             ChannelConfigurations.apply_action(
               control(repository, :alerts, :reply, "event:alerts-none")
             )

    alerts = bind!(alerts.session, "card:audience", nil)

    assert {:ok, audience} =
             ChannelConfigurations.apply_action(
               control(alerts, :audience, :none, "event:audience-none")
             )

    assert audience.session.status == :confirming
    audience = bind!(audience.session, "card:confirm", nil)

    assert {:ok, cancelled} =
             ChannelConfigurations.apply_action(control(audience, :cancel, nil, "event:cancel"))

    assert cancelled.status == :cancelled
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
           ) == {:error, {:invalid_channel_configuration, :default_repository}}

    assert ChannelConfigurations.observe_membership(
             membership(:joined, "event:bad-catalog-shape"),
             %{}
           ) == {:error, {:invalid_channel_configuration, :catalog}}

    assert ChannelConfigurations.reconcile_joined("T123", :invalid, @catalog) ==
             {:error, {:invalid_channel_configuration, :channel_refs}}

    assert ChannelConfigurations.reconcile_joined("T123", ["C1", "C1"], @catalog) ==
             {:error, {:invalid_channel_configuration, :channel_refs}}

    assert ChannelConfigurations.bind_prompt("bad", 0, "", :invalid) ==
             {:error, {:invalid_channel_configuration, :session_ref}}

    assert ChannelConfigurations.apply_action(%{}) ==
             {:error, {:invalid_channel_configuration, :action}}

    session = joined_session!("event:join-invalid-actions") |> bind!("card:invalid", nil)

    assert ChannelConfigurations.apply_action(%{
             control(session, :customize, nil, "event:wrong-thread")
             | thread_ref: "other-thread"
           }) == {:error, :configuration_thread_mismatch}

    assert ChannelConfigurations.apply_action(%{
             control(session, :customize, nil, "event:unknown-action")
             | action: :unknown
           }) == {:error, {:invalid_channel_configuration, :action}}

    assert ChannelConfigurations.apply_action(
             control(session, :audience, %{unexpected: true}, "event:wrong-step")
           ) == {:error, :configuration_action_mismatch}
  end

  defp joined_session!(event_ref \\ "event:join") do
    assert {:ok, result} =
             ChannelConfigurations.observe_membership(membership(:joined, event_ref), @catalog)

    result.session
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
      workspace_ref: "T123"
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
      workspace_ref: "T123"
    }
  end
end
