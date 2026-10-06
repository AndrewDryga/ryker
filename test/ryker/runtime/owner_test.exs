defmodule Ryker.Runtime.OwnerTest do
  use Ryker.DataCase, async: false
  import Ryker.TestHelpers, only: [eventually: 1, eventually: 2]
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.{Bootstrap, Credentials, Repo, Settings}
  alias Ryker.ControlPlane.Endpoint
  alias Ryker.Runtime.{Assembly, Owner}
  alias Ryker.Slack.Names

  @actor "control-plane:local"

  setup do
    # The local MCP token is deployment-injected material, not a product
    # setting; assembly refuses to run the state tools without it.
    System.put_env("RYKER_STATE_TOOLS_TOKEN", "state-tools-token-for-tests")
    on_exit(fn -> System.delete_env("RYKER_STATE_TOOLS_TOKEN") end)
    checkpoint_key = System.get_env("RYKER_CHECKPOINT_KEY")
    System.put_env("RYKER_CHECKPOINT_KEY", Base.encode64(:binary.copy(<<91>>, 32)))

    on_exit(fn ->
      if checkpoint_key,
        do: System.put_env("RYKER_CHECKPOINT_KEY", checkpoint_key),
        else: System.delete_env("RYKER_CHECKPOINT_KEY")
    end)

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

  # mac-server, 2026-10-01: a setup page reached at the address Compose published, not the
  # container's own port, rendered and never went live. Setup runs on this console, before any
  # settings exist.
  test "a console started before any settings accepts the browser at its published address",
       context do
    bootstrap = %{context.bootstrap | control_public_url: "http://127.0.0.1:14321"}
    owner = start_owner(%{context | bootstrap: bootstrap})

    assert Owner.reconcile(owner) == {:ok, :not_initialized}
    assert "//127.0.0.1:14321" in Endpoint.config(:check_origin)
  end

  # mac-server, 2026-10-01: connecting the first Emisar account also made the Default environment,
  # which the console offers Chat, and the owner restarted the whole console for it ("DRAINING 1 of
  # 1 total connection(s) for socket Ryker.ControlPlane.LiveSocket"). The page that had just
  # connected the account lost its way back to the accounts and reloaded on the empty form
  # (Andrew: "after new emisar account connected i see form again"), and open pages came back late
  # ("it took a while for them to activate themselves").
  test "a change the console can take in place leaves its open pages connected", context do
    owner = start_owner(context)
    {:ok, saved} = initialize()
    assert applied(owner, saved)
    console = console_pids(context)

    {:ok, added} =
      Settings.put_environment(
        %{ref: "staging", display_name: "Staging"},
        saved.installation.revision,
        @actor
      )

    assert applied(owner, added)
    assert Map.has_key?(Application.get_env(:ryker, :control_plane).environments, "staging")
    assert console_pids(context) == console
  end

  test "an unavailable settings database is retried, never mistaken for a fresh install",
       context do
    # Falling back to fresh setup here would generate a second installation
    # identity and re-key every lease owner the existing deployment recorded.
    owner = start_owner(context)
    {:ok, saved} = initialize()
    assert applied(owner, saved)

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

    assert applied(owner, saved)
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

    assert applied(owner, edited)
    assert {:ok, reapplied} = Settings.fetch()
    assert Settings.application_status(reapplied) == :applied
    assert Application.get_env(:ryker, :retention).audit_data_seconds == 60 * 86_400
  end

  # Nothing told the owner about a save. It reconciled once at boot and again
  # only while the database was unreachable, so every save sat "pending" until
  # the next deploy restarted the release; the settings page and docs promised
  # the opposite. Every save so far happened to be followed by a deploy, which
  # is the only reason the live revision was ever applied.
  test "a saved revision is applied by the running owner without anyone asking", context do
    owner = start_owner(context)
    assert Owner.reconcile(owner) == {:ok, :not_initialized}

    {:ok, created} = initialize()
    assert eventually(fn -> Owner.applied_revision(owner) == created.installation.revision end)

    {:ok, edited} =
      Settings.save_retention(
        %{audit_data_seconds: 60 * 86_400},
        created.installation.revision,
        @actor
      )

    assert eventually(fn -> Owner.applied_revision(owner) == edited.installation.revision end)
    assert {:ok, applied} = Settings.fetch()
    assert Settings.application_status(applied) == :applied
    assert Application.get_env(:ryker, :retention).audit_data_seconds == 60 * 86_400
  end

  # A console port held by another process made the owner log one warning,
  # record the revision as applied and never try again: the settings page said
  # "the running configuration matches" against a console nobody could open,
  # and a later reconcile answered :unchanged.
  test "a runtime that fails to start leaves its revision unapplied until it starts", context do
    {:ok, _saved} = initialize()
    port = context.bootstrap.control_plane.port
    {:ok, blocker} = :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true])

    owner = start_owner(context)

    assert {:error, {:runtime_start_failed, :control_plane, _reason}} = Owner.reconcile(owner)
    assert Owner.applied_revision(owner) == nil
    assert {:ok, failed} = Settings.fetch()
    assert Settings.application_status(failed) == {:failed, :runtime_start_failed}
    refute :control_plane in Owner.running_keys(owner)
    assert :event_waits in Owner.running_keys(owner)

    :ok = :gen_tcp.close(blocker)

    assert Owner.reconcile(owner) == {:ok, :applied}
    assert Owner.applied_revision(owner) == failed.installation.revision
    assert {:ok, applied} = Settings.fetch()
    assert Settings.application_status(applied) == :applied
    assert :control_plane in Owner.running_keys(owner)
  end

  # A runtime that crashed came back under a pid the owner never saw. The next settings change
  # stopped the pid it remembered, which no longer existed, and starting the replacement failed
  # (already started, or its port still taken): the restarted child kept its old configuration
  # until the container restarted, and the revision stayed unapplied (2026-10-04 review; for
  # retention that means pruning at a horizon the operator had already lengthened).
  test "a runtime restarted after a crash is still replaced when its settings change", context do
    owner = start_owner(context)
    {:ok, saved} = initialize()
    assert applied(owner, saved)

    crashed = retention_pid(context)
    Process.exit(crashed, :kill)
    assert eventually(fn -> retention_pid(context) not in [nil, crashed] end)
    restarted = retention_pid(context)

    # A longer audit horizon is a new retention configuration.
    {:ok, lengthened} =
      Settings.save_retention(
        %{audit_data_seconds: 60 * 86_400},
        saved.installation.revision,
        @actor
      )

    assert applied(owner, lengthened)
    assert eventually(fn -> retention_pid(context) not in [nil, restarted] end)
    assert :retention in Owner.running_keys(owner)
  end

  # Every runtime was a permanent child of one dynamic supervisor with the default restart
  # limit, so one runtime that kept crashing used it up and took every runtime down with it, the
  # console included, and nothing started them again until a person saved settings.
  test "a runtime that keeps crashing comes back on its own and takes nothing else down",
       context do
    owner = start_owner(Map.put(context, :retry_ms, 20))
    {:ok, saved} = initialize()
    assert applied(owner, saved)
    console = console_pids(context)

    # Six crashes, each of a runtime that came back: a loop that found none
    # between restarts crashed it fewer times than it said.
    Enum.reduce(1..6, nil, fn _crash, killed ->
      assert eventually(fn -> event_waits_pid(context) not in [nil, killed] end, 5_000)
      pid = event_waits_pid(context)
      kill_between_messages(pid)
      pid
    end)

    assert eventually(fn -> is_pid(event_waits_pid(context)) end, 5_000)
    assert eventually(fn -> :event_waits in Owner.running_keys(owner) end, 5_000)
    assert Process.alive?(context.supervisor)
    assert console_pids(context) == console
  end

  test "a revision that cannot be assembled is recorded failed and keeps the running one",
       context do
    owner = start_owner(context)
    {:ok, saved} = initialize()
    assert applied(owner, saved)

    # Without the deployment's own state-tools token nothing that runs work
    # can be assembled; the saved revision must stay visibly unapplied. (An
    # integration, Emisar account or webhook source Ryker cannot start no
    # longer refuses a revision: it is left out and named, see AssemblyTest.)
    {:ok, _} = Settings.save_learning(%{enabled: false}, saved.installation.revision, @actor)
    System.delete_env("RYKER_STATE_TOOLS_TOKEN")

    assert {:error, _reason} = Owner.reconcile(owner)
    assert {:ok, failed} = Settings.fetch()
    assert Settings.application_status(failed) == {:failed, :assembly_failed}
    assert failed.installation.applied_revision == saved.installation.revision
    assert Owner.applied_revision(owner) == saved.installation.revision
    assert Application.get_env(:ryker, :event_waits)
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

    slack_tokens!()

    {:ok, connected} =
      Settings.save_slack(
        %{
          bot_ref: "A0123456789",
          bot_user_ref: "U0123456789",
          enabled: true,
          operators: ["U1111111111"],
          workspace_ref: "T0123456789"
        },
        saved.installation.revision,
        @actor
      )

    assert applied(owner, connected)
    assert is_map(Application.get_env(:ryker, :slack))
    assert is_pid(Process.whereis(Names))
  end

  # On 2026-09-26 Andrew chose himself on Integrations › Slack and the list
  # read "Slack user U0BHTNFCW6S". The name cache ran beside the console only
  # while Slack was switched on, so the names Choose people had just loaded
  # had nowhere to go, and switching Slack on, like every later Slack setting,
  # restarted the console with an empty cache.
  test "the Slack name cache runs once the tokens are verified and keeps its names as people are chosen",
       context do
    owner = start_owner(context)
    {:ok, saved} = initialize()

    slack_tokens!()

    {:ok, verified} =
      Settings.save_slack(
        %{bot_ref: "A0123456789", bot_user_ref: "U0123456789", workspace_ref: "T0123456789"},
        saved.installation.revision,
        @actor
      )

    assert applied(owner, verified)
    refute Application.get_env(:ryker, :slack)
    assert :ok = Names.remember([{"T0123456789", "U1111111111", "Andrew"}])
    assert Names.name("T0123456789", "U1111111111") == "@Andrew"

    {:ok, chosen} =
      Settings.save_slack(
        %{enabled: true, operators: ["U1111111111"]},
        verified.installation.revision,
        @actor
      )

    assert applied(owner, chosen)
    assert is_map(Application.get_env(:ryker, :slack))
    assert Names.name("T0123456789", "U1111111111") == "@Andrew"

    {:ok, rechosen} =
      Settings.save_slack(
        %{operators: ["U1111111111", "U2222222222"]},
        chosen.installation.revision,
        @actor
      )

    assert applied(owner, rechosen)
    assert Names.name("T0123456789", "U1111111111") == "@Andrew"
  end

  defp start_owner(context) do
    options =
      [
        name: {:global, {Owner, System.unique_integer([:positive])}},
        supervisor: context.supervisor,
        bootstrap: context.bootstrap
      ] ++ if(retry_ms = Map.get(context, :retry_ms), do: [retry_ms: retry_ms], else: [])

    owner = start_supervised!({Owner, options})

    Sandbox.allow(Repo, self(), owner)
    owner
  end

  defp clear_published do
    Enum.each(
      Assembly.managed_keys(),
      &Application.delete_env(:ryker, &1, persistent: true)
    )
  end

  # The owner applies a save it hears about on its own; an explicit reconcile
  # after that answers :unchanged. Either way the revision must end up running.
  defp slack_tokens! do
    for kind <- [:slack_app, :slack_bot] do
      {:ok, _} = Credentials.put(kind, "primary", "xoxb-test-token-long-enough", @actor)
      {:ok, _} = Credentials.verify(kind, "primary", :verified, @actor)
    end
  end

  defp applied(owner, snapshot) do
    revision = snapshot.installation.revision
    assert Owner.reconcile(owner) in [{:ok, :applied}, {:ok, :unchanged}]
    Owner.applied_revision(owner) == revision
  end

  defp console_pids(context) do
    for {_id, pid, _type, [Ryker.ControlPlane.Endpoint]} <- runtime_children(context), do: pid
  end

  defp console_running?(context) do
    Enum.any?(runtime_children(context), fn {_id, pid, _type, _modules} -> is_pid(pid) end)
  end

  defp retention_pid(context) do
    Enum.find_value(runtime_children(context), fn
      {Ryker.Retention.Runtime, pid, _type, _modules} when is_pid(pid) -> pid
      _child -> nil
    end)
  end

  # A process killed while it holds the case's shared connection takes the connection with it
  # (DBConnection's proxy shuts down when its holder dies), and every query after that fails as
  # unowned: the owner crash-looped 7077 times and the gate went red on 2026-10-05, twice.
  # Suspended, the worker is between messages and holds nothing.
  defp kill_between_messages(pid) do
    :sys.suspend(pid)
    Process.exit(pid, :kill)
  catch
    :exit, _gone -> :ok
  end

  defp event_waits_pid(context) do
    Enum.find_value(runtime_children(context), fn
      {Ryker.Waits.EventWaitWorker, pid, _type, _modules} when is_pid(pid) -> pid
      _child -> nil
    end)
  end

  # Each runtime key runs under its own supervisor; these are the processes inside them. A key's
  # supervisor that gave up on its crashing runtime may be gone by the time it is asked.
  defp runtime_children(context) do
    for {_id, key_supervisor, :supervisor, _modules} <-
          DynamicSupervisor.which_children(context.supervisor),
        is_pid(key_supervisor),
        child <- children(key_supervisor),
        do: child
  end

  defp children(supervisor) do
    Supervisor.which_children(supervisor)
  catch
    :exit, _gone -> []
  end

  defp initialize do
    {:ok, _} = Settings.initialize(@actor)

    {:ok, saved} =
      Settings.put_repository(
        %{
          ref: "ryker",
          github_repository: "acme/ryker",
          source_commit: String.duplicate("a", 40)
        },
        1,
        @actor
      )

    {:ok, saved} =
      Settings.put_github_binding(
        %{
          name: "ryker",
          repository_ref: "ryker",
          installation_id: 1001,
          repository_id: 2001,
          ryker_actor_id: 3001
        },
        saved.installation.revision,
        @actor
      )

    {:ok, saved} =
      Settings.save_work(%{workspace_ref: "ryker-main"}, saved.installation.revision, @actor)

    Settings.put_environment(
      %{ref: "ryker", display_name: "Ryker", repositories: ["ryker"]},
      saved.installation.revision,
      @actor
    )
  end

  defp bootstrap do
    %Bootstrap{
      repo: [url: "ecto://ryker@localhost/ryker", pool_size: 2],
      control_plane: %{ip: {127, 0, 0, 1}, port: free_port()},
      worker_gateway: nil,
      github_listener: %{ip: {127, 0, 0, 1}, port: free_port()},
      github_public_url: "http://127.0.0.1:4319/v1/github",
      webhook_listener: %{ip: {127, 0, 0, 1}, port: free_port()},
      webhook_public_url: "http://127.0.0.1:4320",
      storage_root: "/tmp/ryker-owner-test",
      credential_key: :binary.copy(<<73>>, 32),
      log_level: :warning
    }
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
