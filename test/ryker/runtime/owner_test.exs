defmodule Ryker.Runtime.OwnerTest do
  use Ryker.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.{Bootstrap, Repo, Settings}
  alias Ryker.Runtime.{Assembly, Owner}

  @actor "control-plane:local"
  @digest String.duplicate("a", 64)

  setup do
    # The local MCP token is deployment-injected material, not a product
    # setting; assembly refuses to run the state tools without it.
    System.put_env("RYKER_STATE_TOOLS_TOKEN", "state-tools-token-for-tests")
    on_exit(fn -> System.delete_env("RYKER_STATE_TOOLS_TOKEN") end)

    # The product topology places Work on the enrolled fleet; the isolated test
    # topology has no Work lane to assemble at all.
    execution = Application.get_env(:ryker, :execution)
    Application.put_env(:ryker, :execution, :fleet)
    on_exit(fn -> Application.put_env(:ryker, :execution, execution) end)

    # The applied configuration is global process state; each case starts from
    # nothing so "published" means this owner published it.
    clear_published()
    on_exit(&clear_published/0)

    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    %{supervisor: supervisor, bootstrap: bootstrap()}
  end

  test "a database with no settings starts a reachable console and nothing else", context do
    owner = start_owner(context)

    assert Owner.reconcile(owner) == {:ok, :not_initialized}
    assert Owner.applied_revision(owner) == nil
    assert console_running?(context)
    assert Application.get_env(:ryker, :work) == nil
    assert Application.get_env(:ryker, :slack) == nil
  end

  test "an unavailable settings database is retried, never mistaken for a fresh install",
       context do
    # Falling back to fresh setup here would generate a second installation
    # identity and re-key every lease owner the existing deployment recorded.
    owner = start_owner(context)
    {:ok, saved} = initialize()
    assert Owner.reconcile(owner) == {:ok, :applied}
    assert Owner.applied_revision(owner) == saved.installation.revision

    Repo.query!("ALTER TABLE installation_settings RENAME TO unavailable_installation_settings")

    assert Owner.reconcile(owner) == {:error, :settings_unavailable}
    assert Owner.applied_revision(owner) == saved.installation.revision
    assert console_running?(context)

    assert %{rows: [[1]]} =
             Repo.query!("SELECT count(*) FROM unavailable_installation_settings")
  end

  test "applying is idempotent and records exactly the revision it applied", context do
    owner = start_owner(context)
    {:ok, saved} = initialize()

    assert Owner.reconcile(owner) == {:ok, :applied}
    assert {:ok, applied} = Settings.fetch()
    assert Settings.application_status(applied) == :applied
    assert applied.installation.applied_revision == saved.installation.revision

    assert Owner.reconcile(owner) == {:ok, :unchanged}
    assert {:ok, ^applied} = Settings.fetch()

    {:ok, edited} =
      Settings.save_retention(
        %{audit_data_seconds: 60 * 86_400},
        applied.installation.revision,
        @actor
      )

    assert Settings.application_status(edited) == :pending

    assert Owner.reconcile(owner) == {:ok, :applied}
    assert {:ok, reapplied} = Settings.fetch()
    assert Settings.application_status(reapplied) == :applied
    assert Application.get_env(:ryker, :retention).audit_data_seconds == 60 * 86_400
  end

  test "a revision that cannot be assembled is recorded failed and keeps the running one",
       context do
    owner = start_owner(context)
    {:ok, saved} = initialize()
    assert Owner.reconcile(owner) == {:ok, :applied}

    # A webhook source naming a credential the deployment never registered
    # cannot be assembled; the saved revision must stay visibly unapplied.
    {:ok, _} =
      Settings.put_webhook_source(
        %{
          name: "alerts",
          adapter_kind: :universal,
          auth_kind: :hmac_sha256,
          secret_name: "UNREGISTERED_SIGNING_KEY",
          destination_transport: "control_plane",
          destination_conversation_ref: "control-plane:lab:missing",
          context_ref: "ryker"
        },
        saved.installation.revision,
        @actor
      )

    assert {:error, _reason} = Owner.reconcile(owner)
    assert {:ok, failed} = Settings.fetch()
    assert Settings.application_status(failed) == {:failed, :assembly_failed}
    assert failed.installation.applied_revision == saved.installation.revision
    assert Owner.applied_revision(owner) == saved.installation.revision
    assert Application.get_env(:ryker, :webhooks) == nil
  end

  # Production ran for weeks with every Slack user, channel and workspace in the
  # control plane rendering as a kind — "Slack user", "Slack channel" — because
  # the name cache reads `Application.get_env(:ryker, :slack)` in `init` and
  # the children were started one line before that configuration was published.
  # It declined with `:ignore`, which is permanent: nothing restarts a runtime
  # whose own configuration never changed again.
  test "a child reads the configuration it is being started for", context do
    owner = start_owner(context)
    {:ok, saved} = initialize()

    {:ok, saved} =
      Settings.put_policy_binding(
        %{
          policy_digest: @digest,
          policy_name: "ryker-incident-v1",
          purpose: :incident,
          scope_kind: :installation,
          scope_ref: "",
          verified_by: :import
        },
        saved.installation.revision,
        @actor
      )

    {:ok, _} =
      Settings.save_slack(
        %{
          bot_ref: "A0123456789",
          bot_user_ref: "U0123456789",
          default_repository_ref: "ryker",
          enabled: true,
          operators: ["U1111111111"],
          workspace_ref: "T0123456789"
        },
        saved.installation.revision,
        @actor
      )

    assert Owner.reconcile(owner) == {:ok, :applied}
    assert is_map(Application.get_env(:ryker, :slack))
    assert is_pid(Process.whereis(Ryker.ControlPlane.SlackNames))
  end

  # The Card Lab delivery worker polled card_lab_posts every second beside the
  # console. It was retired on 2026-09-13 with its page; a worker that outlived
  # the page would be a Slack send path with nothing left to queue for it and
  # no way for an operator to see what it was draining.
  test "the retired Card Lab worker does not start beside the control plane", context do
    owner = start_owner(context)
    {:ok, _saved} = initialize()

    assert Owner.reconcile(owner) == {:ok, :applied}

    companions =
      DynamicSupervisor.which_children(context.supervisor)
      |> Enum.flat_map(fn {_id, _pid, _type, modules} -> List.wrap(modules) end)

    assert Ryker.ControlPlane.Updates in companions
    refute Ryker.ControlPlane.CardLabWorker in companions
    refute Enum.any?(companions, &(&1 |> inspect() |> String.contains?("CardLab")))
  end

  defp start_owner(context) do
    owner =
      start_supervised!(
        {Owner,
         [
           name: :"owner-#{System.unique_integer([:positive])}",
           supervisor: context.supervisor,
           bootstrap: context.bootstrap
         ]}
      )

    Sandbox.allow(Repo, self(), owner)
    owner
  end

  defp clear_published do
    Enum.each(
      Assembly.managed_keys(),
      &Application.delete_env(:ryker, &1, persistent: true)
    )
  end

  defp console_running?(context) do
    DynamicSupervisor.which_children(context.supervisor)
    |> Enum.any?(fn {_id, pid, _type, _modules} -> is_pid(pid) end)
  end

  defp initialize do
    {:ok, _} = Settings.initialize(@actor)
    {:ok, _} = Settings.put_repository(%{ref: "ryker"}, 1, @actor)

    {:ok, saved} =
      Settings.put_policy_binding(
        %{
          purpose: :conversational,
          scope_kind: :repository,
          scope_ref: "ryker",
          policy_name: "ryker-conversation-v1",
          policy_digest: @digest,
          verified_by: :import
        },
        2,
        @actor
      )

    {:ok, saved} =
      Settings.save_work(%{workspace_ref: "ryker-main"}, saved.installation.revision, @actor)

    {:ok, saved} =
      Settings.put_policy_binding(
        %{
          purpose: :contributor,
          scope_kind: :repository,
          scope_ref: "ryker",
          policy_name: "ryker-contributor-v1",
          policy_digest: String.duplicate("b", 64),
          verified_by: :import
        },
        saved.installation.revision,
        @actor
      )

    {:ok, saved}
  end

  defp bootstrap do
    %Bootstrap{
      repo: [url: "ecto://ryker@localhost/ryker", pool_size: 2],
      control_plane: %{ip: {127, 0, 0, 1}, port: free_port()},
      state_tools: %{ip: {127, 0, 0, 1}, port: free_port()},
      worker_gateway: nil,
      github_listener: %{ip: {127, 0, 0, 1}, port: free_port()},
      webhook_listener: %{ip: {127, 0, 0, 1}, port: free_port()},
      storage_root: "/tmp/ryker-owner-test",
      github_api_url: "https://api.github.com",
      github_app_id: nil,
      emisar_rpc_url: "https://emisar.dev/api/mcp/rpc",
      log_level: :warning,
      webhook_secret_names: []
    }
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
