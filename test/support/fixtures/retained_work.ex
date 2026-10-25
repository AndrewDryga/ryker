defmodule Ryker.Fixtures.RetainedWork do
  @moduledoc """
  Retained sessions around a harvested, pseudonymized worker plan. Dirty and
  unmerged cases are structural boolean variants of that immutable plan;
  replacements change its revision/head/digest, not a model decision.
  """
  import Ecto.Query
  alias Ryker.CanonicalJSON
  alias Ryker.Crypto
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.{Personalization, WorkSessions}
  alias Ryker.Operator
  alias Ryker.Repo
  alias Ryker.Work

  def current!(kind) when kind in [:dirty, :unmerged] do
    workspace = "TRETAINCONFIRM#{System.unique_integer([:positive])}"
    conversation = "slack:#{workspace}:C1"
    id = Repo.generate_id()

    {:ok, started} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          destination: %{
            conversation_ref: conversation,
            thread_ref: "1.000001",
            transport: "slack"
          },
          episode_id: id,
          episode_key: "retained-copy:#{id}",
          native_input_id: "retained-copy:#{id}",
          turn_ref: "turn:retained-copy:#{id}"
        })
      )

    source = %{episode: started.episode, conversation_ref: conversation}

    try do
      {:ok, _session} =
        WorkSessions.pin_episode(id, "recorded-work-policy", String.duplicate("a", 64))

      {:ok, _cancelled} =
        Episodes.apply(
          EpisodeFixtures.cancel_episode(%{
            cancel_ref: "cancel:retained-copy:#{source.episode.id}",
            episode_key: source.episode.key,
            expected_owner: %{kind: :turn, ref: source.episode.owner_ref},
            occurred_at: Repo.now!()
          })
        )

      session = Repo.fetch!(Work.Session.Query.by_episode_id(source.episode.id))

      plan =
        "testdata/retention/retained-worker-plan.json"
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("plan")

      plan = %{
        plan
        | "session_id" => "worker-session:#{session.id}",
          "operation_id" => "discard-plan:#{session.id}",
          "workspace" => %{plan["workspace"] | "dirty" => kind == :dirty, "unmerged" => true}
      }

      attributes = %{
        cleanup_status: :retained,
        closed_at: Repo.now!(),
        coop_session_id: plan["session_id"],
        discard_plan: plan,
        discard_plan_expected_revision: plan["revision"],
        discard_plan_fingerprint: CanonicalJSON.digest(plan),
        discard_plan_operation_id: plan["operation_id"],
        repository_ref: "retained-repository",
        retained_reason: if(kind == :dirty, do: "dirty", else: "unpublished_unmerged")
      }

      session = session |> Work.Session.Changeset.cleanup(attributes) |> Repo.update!()
      %{kind: kind, session: session, source: source}
    rescue
      error ->
        Personalization.cleanup!(source)
        reraise error, __STACKTRACE__
    end
  end

  def current!(_kind), do: raise(ArgumentError, "unsupported retained state")

  def replace!(%{session: %Work.Session{} = session}) do
    plan = %{
      session.discard_plan
      | "revision" => session.discard_plan["revision"] + 1,
        "operation_id" => "replacement-plan:#{session.id}",
        "workspace" => %{
          session.discard_plan["workspace"]
          | "head" => Crypto.sha256_hex("replacement retained copy"),
            "status_digest" => Crypto.sha256_hex("replacement retained status")
        }
    }

    attributes = %{
      discard_plan: plan,
      discard_plan_expected_revision: plan["revision"],
      discard_plan_fingerprint: CanonicalJSON.digest(plan),
      discard_plan_operation_id: plan["operation_id"]
    }

    session |> Work.Session.Changeset.cleanup(attributes) |> Repo.update!()
  end

  def replace!(_context), do: raise(ArgumentError, "unsupported retained state")

  def fetch!(%{session: %Work.Session{} = session}), do: Repo.get!(Work.Session, session.id)
  def fetch!(_context), do: raise(ArgumentError, "unsupported retained state")

  def cleanup!(%{session: %Work.Session{} = session, source: source}) do
    Repo.delete_all(
      from(action in Operator.RetentionAction, where: action.session_id == ^session.id)
    )

    Personalization.cleanup!(source)
  end

  def cleanup!(_context), do: raise(ArgumentError, "unsupported retained state")
end
