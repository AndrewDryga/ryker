defmodule Ryker.Settings.DomainsTest do
  use Ryker.DataCase, async: false

  alias Ryker.Settings
  alias Ryker.Settings.{Edit, PolicyBinding}

  @actor "control-plane:local"
  @digest String.duplicate("a", 64)

  setup do
    {:ok, snapshot} = Settings.initialize(@actor)
    %{snapshot: snapshot}
  end

  test "collection edits share the single revision and each records one receipt", %{
    snapshot: snapshot
  } do
    assert {:ok, saved} =
             Settings.put_repository(
               %{ref: "ryker", github_repository: "emisar/ryker"},
               snapshot.installation.revision,
               @actor
             )

    assert saved.installation.revision == 2
    assert [%{ref: "ryker", base_branch: "main"}] = saved.repositories

    assert {:ok, saved} =
             Settings.put_repository_context(
               %{ref: "platform", primary_repository_ref: "ryker", parallel_goal_limit: 2},
               2,
               @actor
             )

    assert saved.installation.revision == 3
    assert [%{ref: "platform", read_only_repository_refs: []}] = saved.contexts

    # A stale revision from before the context existed cannot overwrite it.
    assert {:error, {:settings_conflict, winner}} =
             Settings.put_repository(%{ref: "ryker", base_branch: "develop"}, 2, @actor)

    assert winner == saved
    assert Repo.aggregate(Edit, :count) == 3

    assert Enum.map(Repo.all(Edit), & &1.domain) |> Enum.sort() == [
             :installation,
             :repositories,
             :repositories
           ]
  end

  test "an identical collection save is a no-op and an unknown field is refused everywhere", %{
    snapshot: snapshot
  } do
    {:ok, saved} = Settings.put_repository(%{ref: "ryker"}, 1, @actor)

    assert {:ok, ^saved} =
             Settings.put_repository(%{ref: "ryker", base_branch: "main"}, 2, @actor)

    assert {:error, {:invalid_settings, [{:path, :unknown}]}} =
             Settings.put_repository(%{ref: "ryker", path: "/srv/x"}, 2, @actor)

    assert {:error, {:invalid_settings, [{"bot_token", :unknown}]}} =
             Settings.save_slack(%{"bot_token" => "xoxb-secret"}, 2, @actor)

    assert {:ok, ^saved} = Settings.fetch()
    assert snapshot.installation.host_ref == saved.installation.host_ref
    assert Repo.aggregate(Edit, :count) == 2
  end

  test "enabling Slack requires the verified identity and an existing default repository" do
    assert {:error, {:invalid_settings, errors}} =
             Settings.save_slack(%{enabled: true}, 1, @actor)

    assert {:workspace_ref, :required_to_enable} in errors
    assert {:default_repository_ref, :required_to_enable} in errors

    assert {:error, {:invalid_settings, [{:default_repository_ref, :unknown_repository}]}} =
             Settings.save_slack(%{default_repository_ref: "missing"}, 1, @actor)

    {:ok, _} = Settings.put_repository(%{ref: "ryker"}, 1, @actor)

    assert {:ok, saved} =
             Settings.save_slack(
               %{
                 enabled: true,
                 workspace_ref: "T0123456789",
                 bot_ref: "A0123456789",
                 bot_user_ref: "U0123456789",
                 default_repository_ref: "ryker",
                 operators: ["U1111111111"]
               },
               2,
               @actor
             )

    assert saved.slack.enabled
    assert saved.slack.operators == ["U1111111111"]
    assert saved.slack.default_participation == :mentions
    assert saved.installation.revision == 3
    assert Settings.application_status(saved) == :pending
  end

  test "a repository referenced elsewhere cannot be deleted while the reference stands" do
    {:ok, _} = Settings.put_repository(%{ref: "ryker"}, 1, @actor)
    {:ok, _} = Settings.put_repository(%{ref: "coop"}, 2, @actor)

    {:ok, saved} =
      Settings.put_repository_context(
        %{
          ref: "platform",
          primary_repository_ref: "ryker",
          read_only_repository_refs: ["coop"]
        },
        3,
        @actor
      )

    assert {:error, {:invalid_settings, [{:ref, :referenced}]}} =
             Settings.delete_repository("coop", 4, @actor)

    assert {:error, {:invalid_settings, [{:ref, :unknown}]}} =
             Settings.delete_repository("nothing", 4, @actor)

    assert {:ok, ^saved} = Settings.fetch()

    {:ok, saved} = Settings.delete_repository_context("platform", 4, @actor)
    assert saved.contexts == []
    assert {:ok, saved} = Settings.delete_repository("coop", 5, @actor)
    assert Enum.map(saved.repositories, & &1.ref) == ["ryker"]
  end

  test "policy bindings pin one policy per purpose and scope and refuse scopes that do not fit" do
    {:ok, _} = Settings.put_repository(%{ref: "ryker"}, 1, @actor)

    binding = %{
      purpose: :admission,
      scope_kind: :installation,
      scope_ref: "",
      policy_name: "ryker-admission-v1",
      policy_digest: @digest,
      verified_by: :worker,
      verified_worker_ref: "worker-1"
    }

    assert {:ok, saved} = Settings.put_policy_binding(binding, 2, @actor)
    assert [%PolicyBinding{purpose: :admission, policy_digest: @digest}] = saved.policy_bindings

    assert {:error, {:invalid_settings, [{:purpose, :already_bound}]}} =
             Settings.put_policy_binding(binding, 3, @actor)

    assert {:error, {:invalid_settings, [{:scope_kind, :scope}]}} =
             Settings.put_policy_binding(
               %{binding | scope_kind: :repository, scope_ref: "ryker"},
               3,
               @actor
             )

    assert {:error, {:invalid_settings, [{:scope_ref, :unknown_repository}]}} =
             Settings.put_policy_binding(
               %{
                 binding
                 | purpose: :conversational,
                   scope_kind: :repository,
                   scope_ref: "missing"
               },
               3,
               @actor
             )

    assert {:error, {:invalid_settings, errors}} =
             Settings.put_policy_binding(%{binding | policy_digest: "not-a-digest"}, 3, @actor)

    assert {:policy_digest, :format} in errors
    assert {:ok, ^saved} = Settings.fetch()
  end

  test "custom webhook mappings need exact typed fields and presets take no mapping" do
    {:ok, _} = Settings.put_repository(%{ref: "ryker"}, 1, @actor)

    source = %{
      name: "alerts",
      adapter_kind: :mapped_json,
      auth_kind: :hmac_sha256,
      secret_name: "ALERTS_SIGNING_KEY",
      destination_transport: "slack",
      destination_conversation_ref: "slack:T0123456789:C1111111111",
      context_ref: "ryker",
      mapping: %{"event_id" => "id", "status" => "state", "title" => "summary"}
    }

    assert {:ok, saved} = Settings.put_webhook_source(source, 2, @actor)
    assert [%{name: "alerts", enabled: true}] = saved.webhook_sources

    assert {:error, {:invalid_settings, [{:mapping, :mapping_required}]}} =
             Settings.put_webhook_source(%{source | mapping: %{"event_id" => "id"}}, 3, @actor)

    assert {:error, {:invalid_settings, [{:mapping, :mapping_fields}]}} =
             Settings.put_webhook_source(
               %{source | mapping: Map.put(source.mapping, "change.kind", "kind")},
               3,
               @actor
             )

    assert {:error, {:invalid_settings, [{:mapping, :mapping_unsupported}]}} =
             Settings.put_webhook_source(
               %{source | name: "grafana", adapter_kind: :grafana},
               3,
               @actor
             )

    assert {:error, {:invalid_settings, [{:context_ref, :unknown_context}]}} =
             Settings.put_webhook_source(%{source | context_ref: "missing"}, 3, @actor)

    assert {:error, {:invalid_settings, [{:secret_name, :format}]}} =
             Settings.put_webhook_source(%{source | secret_name: "lowercase"}, 3, @actor)
  end

  test "pricing rates are versioned by the revision that introduced them" do
    rate = %{
      execution_target: "codex:gpt-5.6-sol",
      input_usd_per_million: "4",
      cached_input_usd_per_million: "0.40",
      output_usd_per_million: "20",
      effective_from: "2026-09-01",
      provenance: "https://developers.openai.com/api/docs/pricing"
    }

    assert {:ok, saved} = Settings.put_pricing_rate(rate, 1, @actor)
    assert [%{revision: 2, effective_from: ~D[2026-09-01]} = saved_rate] = saved.pricing_rates
    assert Decimal.equal?(saved_rate.input_usd_per_million, Decimal.new("4"))

    assert {:error, {:invalid_settings, [{:effective_from, :already_bound}]}} =
             Settings.put_pricing_rate(rate, 2, @actor)

    assert {:error, {:invalid_settings, errors}} =
             Settings.put_pricing_rate(
               %{rate | effective_from: "2026-10-01", input_usd_per_million: "-1"},
               2,
               @actor
             )

    assert {:input_usd_per_million, :number} in errors

    assert {:ok, saved} =
             Settings.put_pricing_rate(
               %{rate | effective_from: "2026-10-01", input_usd_per_million: "5"},
               2,
               @actor
             )

    assert Enum.map(saved.pricing_rates, & &1.revision) == [2, 3]
  end

  test "every settings save is attributed to a domain the edit log can hold" do
    # A domain the writer names but the edit log's enum does not accept raises
    # on insert, which fails the very save it was recording.
    System.put_env("RYKER_WEBHOOK_SECRET_NAMES", "ALERTMANAGER_WEBHOOK_SECRET")
    on_exit(fn -> System.delete_env("RYKER_WEBHOOK_SECRET_NAMES") end)

    revision =
      Enum.reduce(saves(), 1, fn save, revision ->
        assert {:ok, saved} = save.(revision), "save at revision #{revision} was refused"
        saved.installation.revision
      end)

    recorded = Repo.all(Edit) |> Enum.map(& &1.domain) |> Enum.uniq() |> Enum.sort()

    assert revision == length(saves()) + 1
    assert recorded -- Edit.domains() == []

    # `:import` is recorded only by the one-time importer, which creates the
    # installation instead of saving into one.
    assert Edit.domains() -- recorded == [:import]
  end

  defp saves do
    [
      &Settings.save_retention(%{audit_data_seconds: 60 * 86_400}, &1, @actor),
      &Settings.put_repository(%{ref: "ryker"}, &1, @actor),
      &Settings.save_slack(
        %{
          enabled: true,
          workspace_ref: "T0123456789",
          bot_ref: "A0123456789",
          bot_user_ref: "U0123456789",
          default_repository_ref: "ryker",
          operators: ["U1111111111"]
        },
        &1,
        @actor
      ),
      &Settings.save_github(%{enabled: true, app_id: 12_345}, &1, @actor),
      &Settings.save_publication(%{enabled: true}, &1, @actor),
      &Settings.save_emisar(%{enabled: true}, &1, @actor),
      &Settings.save_report(
        %{weekly_self_report_enabled: true, channel_ref: "C0123456789"},
        &1,
        @actor
      ),
      &Settings.save_learning(%{enabled: true}, &1, @actor),
      &Settings.save_work(%{workspace_ref: "ryker-local-main"}, &1, @actor),
      &Settings.put_policy_binding(
        %{
          purpose: :conversational,
          scope_kind: :repository,
          scope_ref: "ryker",
          policy_name: "ryker-conversation-v1",
          policy_digest: @digest,
          verified_by: :import
        },
        &1,
        @actor
      ),
      &Settings.put_webhook_source(
        %{
          name: "alerts",
          adapter_kind: :universal,
          auth_kind: :hmac_sha256,
          secret_name: "ALERTMANAGER_WEBHOOK_SECRET",
          destination_transport: "slack",
          destination_conversation_ref: "slack:T0123456789:C0123456789",
          destination_thread_ref: "slack:T0123456789:C0123456789",
          context_ref: "ryker"
        },
        &1,
        @actor
      ),
      &Settings.put_pricing_rate(
        %{
          execution_target: "codex:gpt-5.6-sol",
          input_usd_per_million: "4",
          cached_input_usd_per_million: "0.40",
          output_usd_per_million: "20",
          effective_from: "2026-09-01",
          provenance: "https://developers.openai.com/api/docs/pricing"
        },
        &1,
        @actor
      )
    ]
  end
end
