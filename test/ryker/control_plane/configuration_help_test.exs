defmodule Ryker.ControlPlane.ConfigurationHelpTest do
  use ExUnit.Case, async: false

  alias Ryker.ControlPlane.ConfigurationHelp
  alias Ryker.ControlPlane.ConfigurationProjection
  alias Ryker.ControlPlane.RunningSystem
  alias Ryker.Work.CodeEditingSetup

  @settings ~w(admission work control_plane coop_worker_gateway delivery publication retention state_tools event_waits schedules emisar slack github webhooks runtime.mode admission.policy admission.decision_timeout_ms work.concurrency work.poll_interval_ms retention.operational_data_seconds retention.closed_work_seconds retention.episode_history_seconds retention.audit_data_seconds retention.disposable_bytes_limit retention.reclaim_target_seconds retention.storage_high_watermark_bytes retention.storage_low_watermark_bytes retention.storage_reserve_bytes)

  test "code-change help keeps compose recovery concise and own-worker setup folded" do
    # Andrew, 2026-09-25: "Work execution" and "Custom worker fleet" named
    # nothing he recognised. The section says what it is for in plain words.
    page = html([])
    document = LazyHTML.from_document(page)
    section = LazyHTML.query(document, "#code-editing") |> text()
    assert section =~ "Tasks that change code"
    assert section =~ "Docker Compose installations set this up on their own"
    refute section =~ "Work execution"
    refute section =~ "Prepare a coding worker"
    refute section =~ "Settings → Work placement"
    commands = LazyHTML.query(document, "#code-editing details") |> text()
    assert commands =~ "If you run your own workers"
    assert commands =~ "What each kind of work may do"
    assert commands =~ "coop sessions doctor"
    assert commands =~ "coop sessions connect"
    # A Compose install is a release with no Mix; its commands run through
    # scripts/compose.sh.
    assert commands =~ "scripts/compose.sh worker-token WORKER_ID WORKSPACE_REF OPERATOR_REF"
    assert commands =~ "scripts/compose.sh doctor"
    refute commands =~ "mix ryker"
    assert commands =~ "0600"
    refute page =~ "<form"
  end

  test "setup support reflects the running adapter rather than an edited YAML file" do
    previous = Application.fetch_env(:ryker, :work)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ryker, :work, value)
        :error -> Application.delete_env(:ryker, :work)
      end
    end)

    for config <- [nil, %{}, %{api: Ryker.Coop.Client}] do
      Application.put_env(:ryker, :work, config)
      refute CodeEditingSetup.checkpoint_supported?()
      assert html([]) =~ "Tasks that change code cannot run"
    end

    Application.put_env(:ryker, :work, api: Ryker.CoopFleet.Client)
    assert CodeEditingSetup.checkpoint_supported?()
    assert html([]) =~ "Workers can save and restore the copy of the code a task works in"
    refute html([]) =~ "If you run your own workers"
  end

  test "each effective setting explains its purpose, behavior and default beside its value" do
    # The old key/value table left operators guessing what a policy or timeout did.
    rows = Enum.map(@settings, &row(&1, "configured"))
    document = html(rows) |> LazyHTML.from_document()

    # Slack, GitHub, Emisar and webhooks are listed in their own pages' words
    # instead (IntegrationStateLiveTest holds that).
    for key <- @settings -- ~w(slack github emisar webhooks) do
      setting = LazyHTML.query(document, "[data-setting='#{key}']")
      assert LazyHTML.text(LazyHTML.query(setting, ".configuration-purpose")) != "", key
      assert LazyHTML.text(LazyHTML.query(setting, ".configuration-behavior")) != "", key
      assert LazyHTML.text(LazyHTML.query(setting, ".configuration-default")) != "", key
      refute LazyHTML.text(setting) =~ "Explanation unavailable"
    end
  end

  test "each loaded setting is named and explained in plain words, its precise terms under Details" do
    # Andrew, 2026-09-25, of the Advanced page: names like "Admission",
    # "Coop worker gateway" and "Disposable workspace budget" explain nothing
    # to the person reading them. The title and the line under it use plain
    # words; the key, the value and the exact behaviour stay under Details.
    internal =
      ~w(Admission admission Coop coop co:op episode Episode payload fork workspace Workspace execution Execution horizon custody Documents)

    for key <- @settings do
      %{title: title, purpose: purpose} = ConfigurationHelp.setting(key)

      for term <- internal do
        refute title =~ term, "#{key} is titled #{title}"
        refute purpose =~ term, "#{key} is explained as #{purpose}"
      end
    end

    assert ConfigurationHelp.setting("admission").title == "Routing"
    assert ConfigurationHelp.setting("coop_worker_gateway").title == "Worker connections"

    # The Data retention page's names, so a limit reads the same in both places.
    assert ConfigurationHelp.setting("retention.operational_data_seconds").title ==
             "Prompts, replies and tool activity"
  end

  test "timing help distinguishes faster polling from faster inference and retention from defaults" do
    page =
      html([
        row("admission.decision_timeout_ms", "30000"),
        row("work.poll_interval_ms", "250"),
        row("retention.operational_data_seconds", "86400")
      ])

    assert page =~ "30 seconds"
    assert page =~ "250 milliseconds"
    assert page =~ "1 day"

    assert ConfigurationHelp.value("retention.disposable_bytes_limit", "10737418240") ==
             "10.00 GiB"

    assert ConfigurationHelp.value("retention.reclaim_target_seconds", "3600") == "1 hour"
    assert page =~ "does not make the model think faster"
    assert page =~ "Required when cleanup is set up; there is no default"
    # The evidence section must not send an operator back to a file or a
    # restart: these values are assembled from settings that apply live.
    values =
      page
      |> LazyHTML.from_document()
      |> LazyHTML.query(".configuration-values")
      |> text()

    assert values =~ "Nothing here can be changed"
    assert values =~ "without a deployment"
    refute values =~ "restart"
    refute page =~ "<form"
  end

  test "readiness availability is not described as GitHub publication authority" do
    page = html([row("publication", "enabled")])
    assert page =~ "Code reviews run whenever replies can be delivered"
    assert page =~ "Opening pull requests needs GitHub and the repository set up in Ryker"
    refute page =~ "Not configured unless publication is present"
  end

  test "policy help explains immutable pins instead of treating policy names as model names" do
    page = html([row("admission.policy", "ryker-admission-v1")])
    assert page =~ "The worker policy routing runs under"
    assert page =~ "fingerprint pins the exact version that was reviewed"
    assert page =~ "not a model name"
    assert page =~ "Change the policy&#39;s name and fingerprint together"
    assert page =~ "ryker-admission-v1"
  end

  test "the details of a loaded setting say what it does in plain words" do
    # QA re-test, 2026-09-26: "Show what is loaded" said "Configure
    # admission.policy.name and admission.policy.digest together", "v1
    # loader", "model turn" and "host-selected policy". The setting's name in
    # the file and its loaded value stay; the sentences are plain.
    internal = [
      "v1 loader",
      "v1 configuration",
      "model turn",
      "host-selected",
      "admission.policy.name",
      "digest",
      "custody",
      "adapter",
      "binding",
      "product mode",
      "component mode",
      "fleet",
      "fork",
      "horizon",
      "watermark",
      "episode",
      "Episode",
      "Coop",
      "mutual TLS",
      "YAML"
    ]

    for key <- @settings do
      %{behavior: behavior, default: default} = ConfigurationHelp.setting(key)

      for term <- internal do
        refute behavior =~ term, "#{key} behaviour says #{term}: #{behavior}"
        refute default =~ term, "#{key} default says #{term}: #{default}"
      end
    end

    document = html([row("work.concurrency", "4")]) |> LazyHTML.from_document()
    labels = document |> LazyHTML.query(".settings-row-details dt") |> Enum.map(&text/1)
    assert "Name in the settings file" in labels
    refute "Key" in labels
  end

  test "policy names are never mistaken for component presence flags" do
    for name <- ["enabled", "disabled"] do
      document = html([row("admission.policy", name)]) |> LazyHTML.from_document()
      assert LazyHTML.text(LazyHTML.query(document, ".configuration-value")) == name
      assert ConfigurationHelp.value("future.option", name) == name
    end

    assert ConfigurationHelp.value("admission", "enabled") == "Configured"
    assert ConfigurationHelp.value("admission", "disabled") == "Not configured"
  end

  test "unknown settings and grant names remain escaped without invented explanations" do
    page =
      RunningSystem.html(%{
        integrations: [],
        source: "<source>",
        rows: [row("future.<option>", "<script>alert(1)</script>")],
        grants: [%{kind: "MCP tool", name: "<tool>", source: "<source>"}]
      })

    assert page =~ "Explanation unavailable"
    assert page =~ "&lt;option&gt;"
    assert page =~ "&lt;script&gt;"
    assert page =~ "&lt;tool&gt;"
    assert page =~ "does not grant permission"
    refute page =~ "<script>"
    refute page =~ "<source>"
    refute page =~ "<tool>"
  end

  test "the current configuration projection cannot silently outgrow its explanations" do
    configured = %{
      runtime_mode: :product,
      admission: %{policy: "ryker-admission-v1", decision_timeout_ms: 30_000},
      work: %{concurrency: 4, poll_interval_ms: 250},
      retention: %{
        operational_data_seconds: 86_400,
        closed_work_seconds: 604_800,
        episode_history_seconds: 2_592_000,
        audit_data_seconds: 2_592_000,
        disposable_bytes_limit: 10_737_418_240,
        reclaim_target_seconds: 3_600,
        storage_high_watermark_bytes: 64_424_509_440,
        storage_low_watermark_bytes: 48_318_382_080,
        storage_reserve_bytes: 5_368_709_120
      }
    }

    previous =
      Map.new(configured, fn {key, _} -> {key, Application.fetch_env(:ryker, key)} end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:ryker, key, value)
        {key, :error} -> Application.delete_env(:ryker, key)
      end)
    end)

    Enum.each(configured, fn {key, value} -> Application.put_env(:ryker, key, value) end)
    snapshot = ConfigurationProjection.fetch()
    assert Enum.sort(Enum.map(snapshot.rows, & &1.key)) == Enum.sort(@settings)
    assert Enum.all?(snapshot.rows, &ConfigurationHelp.setting(&1.key).documented)
  end

  defp row(key, value), do: %{key: key, value: value, source: "/etc/ryker.yaml"}

  # Text as a reader sees it: HTML collapses the line breaks of the template.
  defp text(nodes), do: nodes |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  defp html(rows),
    do: RunningSystem.html(%{rows: rows, grants: [], source: "/etc/ryker.yaml", integrations: []})
end
