defmodule Ryker.Fixtures.WorkerJob do
  @moduledoc false
  import Ecto.Query
  alias Ryker.CoopFleet.{JobAuthority, JobSpec}
  alias Ryker.Repo
  alias Ryker.Work.{RepositoryContext, RepositorySource, Session}

  def pin!(%Session{worker_job_document: nil} = session) do
    job = build(session.external_ref, session.repository_ref)
    {:ok, context} = RepositoryContext.restore(session.repository_context, session.repository_ref)
    refs = if context, do: context.read_only_repositories, else: []

    job =
      Map.merge(job, %{
        "source" => source(session.repository_ref, session.repository_source),
        "mode" => if(session.repository_ref, do: "normal", else: "bare"),
        "companions" => Enum.map(refs, &%{"name" => &1, "source" => source(&1, nil)})
      })

    {:ok, digest} = JobSpec.digest(job)
    session |> Session.Changeset.pin_worker_job(job, digest) |> Repo.update!()
  end

  def pin!(%Session{} = session) do
    {:ok, session} = JobAuthority.validate(session)
    session
  end

  # Fake callbacks call this in the test/executor process, never inside an Agent.
  def for_task!(task, key \\ nil) do
    session =
      case Regex.run(~r/\Aryker:work:create:([0-9a-f-]+):g[1-9]\d*\z/, key || "") do
        [_, id] ->
          Repo.get!(Session, id)

        nil ->
          [session] = Repo.all(from(s in Session, where: s.external_ref == ^task))
          session
      end

    ^task = Session.coop_task_ref(session)
    pin!(session)
  end

  def receipt(session) do
    %{
      "external_ref" => Session.coop_task_ref(session),
      "job_ref" => session.external_ref,
      "job_digest" => session.worker_job_digest
    }
  end

  defp source(nil, _requested), do: nil

  defp source(ref, requested) do
    requested = requested || RepositorySource.default()
    source = build("fixture", ref)["source"]

    binding =
      Map.merge(source["binding"], %{"kind" => requested["kind"], "requested" => requested})

    binding =
      case requested["kind"] do
        "default" ->
          binding

        "commit" ->
          Map.merge(binding, %{"selected_ref" => nil, "selected_commit" => requested["sha"]})

        "branch" ->
          Map.put(binding, "selected_ref", RepositorySource.derived_ref(requested))

        "pull_request" ->
          Map.merge(binding, %{
            "selected_ref" => RepositorySource.derived_ref(requested),
            "pull_request_number" => requested["number"]
          })
      end

    Map.put(source, "binding", binding)
  end

  def build(job_ref \\ "job:one", repository_ref \\ "repo:one") do
    %{
      "version" => 2,
      "job_ref" => job_ref,
      "source" => %{
        "repository_ref" => repository_ref,
        "github_repository" => "example/repository",
        "github_repository_id" => 17,
        "binding" => %{
          "version" => 1,
          "kind" => "default",
          "requested" => %{"kind" => "default"},
          "remote_identity" => "origin",
          "default_ref" => "refs/heads/main",
          "default_commit" => String.duplicate("a", 40),
          "selected_ref" => "refs/heads/main",
          "selected_commit" => String.duplicate("a", 40),
          "base_commit" => String.duplicate("a", 40),
          "admitted_tree" => String.duplicate("c", 40),
          "resolved_at" => "2026-09-26T12:00:00Z"
        },
        "submodules" => []
      },
      "companions" => [],
      "targets" => ["codex:gpt-6&sol@default"],
      "mode" => "normal",
      "environment" => %{},
      "check" => %{"argv" => [], "environment" => %{}},
      "resources" => %{"cpu_millis" => 4_000, "memory_bytes" => 8_589_934_592, "pids" => 4_096},
      "repository_read_only" => false,
      "egress" => %{"mode" => "none", "rules" => [], "export_destinations" => false},
      "limits" => %{
        "max_turns" => 100,
        "max_queued_turns" => 20,
        "max_queued_bytes" => 1_048_576,
        "turn_timeout_ms" => 3_600_000,
        "warm_idle_timeout_ms" => 0,
        "max_patch_bytes" => 1_048_576
      }
    }
  end
end
