defmodule Ryker.Settings.DomainsTest do
  use Ryker.DataCase, async: false

  alias Ryker.Settings
  alias Ryker.Settings.Edit

  @actor "control-plane:local"

  setup do
    {:ok, snapshot} = Settings.initialize(@actor)
    %{snapshot: snapshot}
  end

  test "a new installation starts with the built-in token rates", %{snapshot: snapshot} do
    assert snapshot.pricing_rates
           |> Enum.map(& &1.execution_target)
           |> Enum.sort() ==
             Enum.sort(["codex:gpt-5.6-sol", "codex:gpt-5.6-terra", "codex:gpt-5.6-luna"])
  end

  test "each kind of work has its own models, and only a list the worker can run is saved",
       %{snapshot: snapshot} do
    # Each new job freezes its work kind's ordered target ladder. Reject malformed
    # settings before they can produce a job Coop cannot admit: one model and at
    # most three fallbacks.
    assert snapshot.work.routing_models == ["codex:gpt-5.6-sol/medium@default"]
    assert snapshot.work.conversation_models == ["codex:gpt-5.6-terra/medium@default"]
    assert snapshot.work.deep_models == ["codex:gpt-5.6-sol/xhigh@default"]
    assert snapshot.work.model_accounts == ["codex@default"]

    sol = "codex:gpt-5.6-sol/medium@default"

    for {models, reason} <- [
          {[], :length},
          {[
             sol,
             "codex:gpt-5.6-sol/high@default",
             "codex:gpt-5.6-sol/low@default",
             "codex:gpt-5.6-terra/low@default",
             "codex:gpt-5.6-luna/low@default"
           ], :length},
          {["/@"], :format},
          {["gpt-5.6-sol"], :format},
          {["gemini:gemini-3-pro/low@default"], :format},
          {["codex:gpt-5.6-sol/max@default"], :format},
          {["codex:gpt-5.6-sol@default"], :format},
          {["codex:gpt-5.6-sol/medium@default\n"], :format},
          {[sol, sol], :duplicate}
        ] do
      assert {:error, {:invalid_settings, [{:routing_models, ^reason}]}} =
               Settings.save_work(
                 %{routing_models: models},
                 snapshot.installation.revision,
                 @actor
               ),
             inspect(models)
    end

    assert {:error, {:invalid_settings, [{:routing_models, _cast}]}} =
             Settings.save_work(%{routing_models: sol}, snapshot.installation.revision, @actor)

    assert Settings.fetch!().work.routing_models == [sol]

    assert {:ok, saved} =
             Settings.save_work(
               %{deep_models: ["codex:gpt-5.6-terra/high@default"]},
               snapshot.installation.revision,
               @actor
             )

    assert saved.work.deep_models == ["codex:gpt-5.6-terra/high@default"]
    assert saved.work.standard_models == [sol]
  end

  # Andrew, 2026-09-26: "Can I have fallbacks between models/providers like
  # coop allows?" A fallback can change model, provider or account. Ryker records
  # the intended worker accounts here; Coop checks their actual credentials when
  # admitting a job. Reject unlisted accounts before freezing a new job ladder.
  test "an account not listed under Model accounts is refused", %{snapshot: snapshot} do
    fallback = "codex:gpt-5.6-sol/medium@personal"
    routing = ["codex:gpt-5.6-sol/medium@default", fallback]

    assert {:error, {:invalid_settings, [{:routing_models, :unknown_account}]}} =
             Settings.save_work(
               %{routing_models: routing},
               snapshot.installation.revision,
               @actor
             )

    assert {:ok, saved} =
             Settings.save_work(
               %{model_accounts: ["codex@default", "codex@personal"], routing_models: routing},
               snapshot.installation.revision,
               @actor
             )

    assert saved.work.routing_models == routing

    # Removing an account a saved model still uses is refused at the account.
    assert {:error, {:invalid_settings, [{:model_accounts, :in_use}]}} =
             Settings.save_work(
               %{model_accounts: ["codex@default"]},
               saved.installation.revision,
               @actor
             )

    for {accounts, reason} <- [
          {[], :length},
          {["default"], :format},
          {["gemini@default"], :format},
          {["codex@default", "codex@default"], :list}
        ] do
      assert {:error, {:invalid_settings, [{:model_accounts, ^reason}]}} =
               Settings.save_work(
                 %{model_accounts: accounts},
                 saved.installation.revision,
                 @actor
               ),
             inspect(accounts)
    end
  end

  # A request can move between conversation, standard and deep work, so Ryker
  # pins one set of permissions for all three, and Coop counts the accounts a
  # policy's models run on as part of that set. Different accounts on the
  # three would leave no repository able to take work at all.
  test "conversation, standard and deep work keep the same accounts in the same order",
       %{snapshot: snapshot} do
    {:ok, snapshot} =
      Settings.save_work(
        %{model_accounts: ["codex@default", "codex@personal"]},
        snapshot.installation.revision,
        @actor
      )

    ladder = fn model, effort ->
      ["codex:#{model}/#{effort}@default", "codex:#{model}/#{effort}@personal"]
    end

    assert {:error, {:invalid_settings, errors}} =
             Settings.save_work(
               %{standard_models: ladder.("gpt-5.6-sol", "medium")},
               snapshot.installation.revision,
               @actor
             )

    assert errors == [{:standard_models, :shared_accounts}]

    # The same accounts in the same order may carry different models and efforts.
    assert {:ok, saved} =
             Settings.save_work(
               %{
                 conversation_models: ladder.("gpt-5.6-terra", "low"),
                 standard_models: ladder.("gpt-5.6-sol", "medium"),
                 deep_models: ladder.("gpt-5.6-sol", "xhigh")
               },
               snapshot.installation.revision,
               @actor
             )

    assert saved.work.deep_models == ladder.("gpt-5.6-sol", "xhigh")
  end

  # A model is offered once a price covers it, so its cost can be estimated.
  # One already saved for a kind of work stays: removing its price later only
  # makes its cost show as not priced.
  test "a model no price covers is refused unless that kind of work already runs it",
       %{snapshot: snapshot} do
    {:ok, snapshot} =
      Settings.save_work(
        %{model_accounts: ["codex@default", "claude@work"]},
        snapshot.installation.revision,
        @actor
      )

    claude = ["codex:gpt-5.6-sol/medium@default", "claude:claude-opus-4-6/high@work"]

    assert {:error, {:invalid_settings, [{:routing_models, :unpriced}]}} =
             Settings.save_work(%{routing_models: claude}, snapshot.installation.revision, @actor)

    {:ok, snapshot} =
      Settings.put_pricing_rate(
        %{
          execution_target: "claude:claude-opus-4-6",
          input_usd_per_million: "5",
          cached_input_usd_per_million: "0.5",
          output_usd_per_million: "25",
          effective_from: ~D[2026-09-26],
          provenance: "https://www.anthropic.com/pricing"
        },
        snapshot.installation.revision,
        @actor
      )

    assert {:ok, saved} =
             Settings.save_work(%{routing_models: claude}, snapshot.installation.revision, @actor)

    rate = Enum.find(saved.pricing_rates, &(&1.execution_target == "claude:claude-opus-4-6"))
    {:ok, saved} = Settings.delete_pricing_rate(rate.id, saved.installation.revision, @actor)

    # Still saved for routing, at another effort too; not newly for deep work.
    assert {:ok, saved} =
             Settings.save_work(
               %{routing_models: ["claude:claude-opus-4-6/low@work"]},
               saved.installation.revision,
               @actor
             )

    assert {:error, {:invalid_settings, [{:incident_models, :unpriced}]}} =
             Settings.save_work(
               %{incident_models: ["claude:claude-opus-4-6/low@work"]},
               saved.installation.revision,
               @actor
             )
  end

  test "a new installation learns by default", %{snapshot: snapshot} do
    assert snapshot.learning.enabled
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
             Settings.put_environment(
               %{
                 ref: "platform",
                 display_name: "Platform",
                 repositories: ["ryker"],
                 parallel_goal_limit: 2
               },
               2,
               @actor
             )

    assert saved.installation.revision == 3
    assert [%{ref: "platform", parallel_goal_limit: 2}] = saved.environments

    # A stale revision from before the environment existed cannot overwrite it.
    assert {:error, {:settings_conflict, winner}} =
             Settings.put_repository(%{ref: "ryker", base_branch: "develop"}, 2, @actor)

    assert winner == saved
    assert Repo.aggregate(Edit, :count) == 3

    assert Enum.map(Repo.all(Edit), & &1.domain) |> Enum.sort() == [
             :environments,
             :installation,
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

  test "enabling Slack requires its detected identity" do
    assert {:error, {:invalid_settings, errors}} =
             Settings.save_slack(%{enabled: true}, 1, @actor)

    assert {:workspace_ref, :required_to_enable} in errors
    assert {:bot_ref, :required_to_enable} in errors
    assert {:bot_user_ref, :required_to_enable} in errors

    # Which repository a channel works in is its environment's choice now.
    assert {:error, {:invalid_settings, [{:default_repository_ref, :unknown}]}} =
             Settings.save_slack(%{default_repository_ref: "ryker"}, 1, @actor)

    {:ok, _} = Settings.put_repository(%{ref: "ryker"}, 1, @actor)

    assert {:ok, saved} =
             Settings.save_slack(
               %{
                 enabled: true,
                 workspace_ref: "T0123456789",
                 bot_ref: "A0123456789",
                 bot_user_ref: "U0123456789",
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
      Settings.put_environment(
        %{ref: "platform", display_name: "Platform", repositories: ["ryker", "coop"]},
        3,
        @actor
      )

    assert {:error, {:invalid_settings, [{:ref, :referenced}]}} =
             Settings.delete_repository("coop", 4, @actor)

    assert {:error, {:invalid_settings, [{:ref, :unknown}]}} =
             Settings.delete_repository("nothing", 4, @actor)

    assert {:ok, ^saved} = Settings.fetch()

    {:ok, saved} = Settings.delete_environment("platform", 4, @actor)
    assert saved.environments == []
    assert {:ok, saved} = Settings.delete_repository("coop", 5, @actor)
    assert Enum.map(saved.repositories, & &1.ref) == ["ryker"]
  end

  test "retired policy edit receipts stay readable without a settings registry" do
    edit = Repo.get_by!(Edit, revision: 1)
    Repo.query!("UPDATE settings_edits SET domain = 'policies' WHERE revision = 1")
    assert Repo.get!(Edit, edit.id).domain == :policies
    assert {:ok, snapshot} = Settings.fetch()
    refute Map.has_key?(snapshot, :policy_bindings)
    refute function_exported?(Settings, :put_policy_binding, 3)
  end

  test "custom webhook mappings need exact typed fields and presets take no mapping" do
    {:ok, _} = Settings.put_environment(%{ref: "ryker", display_name: "Ryker"}, 1, @actor)

    source = %{
      name: "alerts",
      adapter_kind: :mapped_json,
      auth_kind: :hmac_sha256,
      secret_name: "alerts",
      destination_transport: "slack",
      destination_conversation_ref: "slack:T0123456789:C1111111111",
      environment_ref: "ryker",
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

    assert {:error, {:invalid_settings, [{:environment_ref, :unknown_environment}]}} =
             Settings.put_webhook_source(%{source | environment_ref: "missing"}, 3, @actor)

    assert {:error, {:invalid_settings, [{:secret_name, :format}]}} =
             Settings.put_webhook_source(%{source | secret_name: "UPPERCASE"}, 3, @actor)
  end

  test "pricing rates are versioned by the revision that introduced them" do
    rate = %{
      execution_target: "codex:test-model",
      input_usd_per_million: "4",
      cached_input_usd_per_million: "0.40",
      output_usd_per_million: "20",
      effective_from: "2026-09-01",
      provenance: "https://developers.openai.com/api/docs/pricing"
    }

    assert {:ok, saved} = Settings.put_pricing_rate(rate, 1, @actor)
    saved_rate = Enum.find(saved.pricing_rates, &(&1.execution_target == "codex:test-model"))
    assert %{revision: 2, effective_from: ~D[2026-09-01]} = saved_rate
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

    custom_rates = Enum.filter(saved.pricing_rates, &(&1.execution_target == "codex:test-model"))
    assert Enum.map(custom_rates, & &1.revision) == [2, 3]
  end

  # Found in manual testing on 2026-09-26: a price saved without its provider
  # was accepted and could never match an execution, whose model is always
  # named with its provider.
  test "a price names exactly one provider and one model" do
    rate = %{
      input_usd_per_million: "3",
      cached_input_usd_per_million: "0.30",
      output_usd_per_million: "15",
      effective_from: "2026-09-26",
      provenance: "https://www.anthropic.com/pricing"
    }

    for target <- [
          "claude-haiku",
          "claude:",
          ":claude-haiku",
          "claude:claude-haiku:latest",
          "Claude:claude-haiku",
          "claude:claude haiku"
        ] do
      assert {:error, {:invalid_settings, [{:execution_target, :format}]}} =
               Settings.put_pricing_rate(Map.put(rate, :execution_target, target), 1, @actor),
             inspect(target)
    end

    assert {:ok, saved} =
             Settings.put_pricing_rate(
               Map.put(rate, :execution_target, "claude:claude-haiku-4.5"),
               1,
               @actor
             )

    assert Enum.any?(saved.pricing_rates, &(&1.execution_target == "claude:claude-haiku-4.5"))
  end

  test "every settings save is attributed to a domain the edit log can hold" do
    # A domain the writer names but the edit log's enum does not accept raises
    # on insert, which fails the very save it was recording.
    revision =
      Enum.reduce(saves(), 1, fn save, revision ->
        assert {:ok, saved} = save.(revision), "save at revision #{revision} was refused"
        saved.installation.revision
      end)

    recorded = Repo.all(Edit) |> Enum.map(& &1.domain) |> Enum.uniq() |> Enum.sort()

    assert revision == length(saves()) + 1
    assert recorded -- Edit.domains() == []

    # Retired domains remain decodable, but no current settings command writes them.
    assert Edit.domains() -- recorded == [:policies, :import]
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
          operators: ["U1111111111"]
        },
        &1,
        @actor
      ),
      &Settings.save_github(%{enabled: true, app_id: 12_345}, &1, @actor),
      &Settings.save_publication(%{enabled: true}, &1, @actor),
      &Settings.put_emisar_connection(
        %{
          ref: "production",
          display_name: "Production approvals",
          rpc_url: "https://emisar.dev/api/mcp/rpc",
          account_ref: "account-production",
          account_label: "Production",
          enabled_for_new_work: true,
          monitoring_enabled: true,
          verified_at: ~U[2026-09-19 12:00:00.000000Z]
        },
        &1,
        @actor
      ),
      &Settings.save_report(
        %{weekly_self_report_enabled: true, channel_ref: "C0123456789"},
        &1,
        @actor
      ),
      &Settings.save_learning(%{enabled: false}, &1, @actor),
      &Settings.save_work(%{workspace_ref: "ryker-local-main"}, &1, @actor),
      &Settings.put_environment(
        %{ref: "production", display_name: "Production", repositories: ["ryker"]},
        &1,
        @actor
      ),
      &Settings.put_webhook_source(
        %{
          name: "alerts",
          adapter_kind: :universal,
          auth_kind: :hmac_sha256,
          secret_name: "alerts",
          destination_transport: "slack",
          destination_conversation_ref: "slack:T0123456789:C0123456789",
          destination_thread_ref: "slack:T0123456789:C0123456789",
          environment_ref: "production"
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
