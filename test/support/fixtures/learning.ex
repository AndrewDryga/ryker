defmodule Responder.Fixtures.Learning do
  @moduledoc false
  alias Responder.Admission.Decision
  alias Responder.CanonicalJSON
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Ingress.Inbox.{Entry, EntryChangeset}
  alias Responder.Learning.FleetSession
  alias Responder.Repo
  alias Responder.State.{Learning, Observations}

  @doc "Host-contract adapter only: simulate the exact transport acknowledgment without calling a model."
  def accept(id, body, producer) do
    run =
      case Ecto.UUID.cast(id) do
        {:ok, id} -> Repo.get(Responder.State.LearningRun, id)
        _ -> nil
      end

    session_id = "host-contract-session:#{id}"
    turn_id = "host-contract-turn:#{id}"

    claim =
      if run && run.batch_id do
        batch = Repo.get!(Responder.Learning.Batch, run.batch_id)
        %{batch: batch, lease_ref: batch.lease_ref}
      end

    if run && run.status in [:prepared, :responded, :applied] && is_nil(run.pruned_at) do
      {:ok, _} = FleetSession.ensure(run)
      {:ok, _} = FleetSession.bind(run, session_id)
    end

    sha = if is_binary(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    candidate = %{
      "id" => turn_id,
      "session_id" => session_id,
      "candidate" => %{"attempt" => 1, "message" => body, "sha256" => sha}
    }

    completed = %{
      "id" => turn_id,
      "session_id" => session_id,
      "state" => "completed",
      "assistant_message" => body,
      "validation_attempt" => 1,
      "validation_candidate_sha256" => sha,
      "validation_receipt" => "host-contract-validation:#{id}"
    }

    with {:ok, _} <- Learning.record_candidate(id, candidate, producer, claim),
         {:ok, _} <- Learning.check_candidate(id, claim),
         {:ok, _} <- Learning.confirm_candidate(id, completed, claim),
         do: Learning.apply_result(id, claim)
  end

  def retained_input!(raw, policy) do
    fields = ~w(dedupe_key event_ref event_fingerprint source_kind source_ref native_input_id
      source_item_ref actor_ref revision content destination_transport destination_conversation_ref
      destination_thread_ref repository_ref)a

    {:ok, decision} =
      Decision.parse(%{
        "action" => "ignore",
        "episode_ref" => nil,
        "reaction" => nil,
        "relation" => "unrelated",
        "reason" => "Silent shadow learning test.",
        "work_class" => nil
      })

    entry =
      fields
      |> Map.new(&{&1, raw[Atom.to_string(&1)]})
      |> Map.merge(%{
        id: raw["id"],
        status: :pending,
        actor_kind: String.to_existing_atom(raw["actor_kind"]),
        event_kind: :message,
        occurred_at:
          raw["occurred_at"]
          |> NaiveDateTime.from_iso8601!()
          |> DateTime.from_naive!("Etc/UTC"),
        occurred_at_source: :source,
        execution_mode: :shadow,
        source_capabilities: %{},
        work_policy: policy.policy,
        work_policy_digest: policy.policy_digest
      })
      |> then(&struct!(Entry, &1))
      |> EntryChangeset.decide(decision, "learning-test:#{raw["id"]}", nil)
      |> Repo.insert!()

    {:ok, :ok} = Repo.transaction(fn -> Observations.receive_in_transaction(entry) end)
    entry
  end

  @doc "Rebind only replay custody identities; retain captured content and source clocks unchanged."
  def isolate_retained_input(raw, workspace \\ nil) do
    id = Ecto.UUID.generate()
    workspace = workspace || "T" <> String.replace(id, "-", "")
    ["slack", _workspace, channel] = String.split(raw["destination_conversation_ref"], ":")

    Map.merge(raw, %{
      "id" => id,
      "source_input_id" => id,
      "dedupe_key" => "fixture:#{id}:#{raw["dedupe_key"]}",
      "event_ref" => "fixture:#{id}:#{raw["event_ref"]}",
      "event_fingerprint" =>
        CanonicalJSON.digest(["isolated-fixture", id, raw["event_fingerprint"]]),
      "native_input_id" => "fixture:#{id}:#{raw["native_input_id"]}",
      "source_ref" => workspace,
      "destination_conversation_ref" => "slack:#{workspace}:#{channel}"
    })
  end

  def inputs!(options \\ []) do
    inputs =
      "testdata/learning/retained-haproxy-lifecycle.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("inputs")

    inputs =
      if Keyword.get(options, :isolate, false) do
        workspace = "T" <> String.replace(Ecto.UUID.generate(), "-", "")
        Enum.map(inputs, &isolate_retained_input(&1, workspace))
      else
        inputs
      end

    Enum.map(inputs, &persist!/1)
  end

  defp persist!(raw) do
    at = raw["occurred_at"] |> NaiveDateTime.from_iso8601!() |> DateTime.from_naive!("Etc/UTC")
    id = raw["source_input_id"]

    {:ok, %{episode: episode}} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: id,
          episode_key: "ingress-input:#{id}",
          native_input_id: raw["native_input_id"],
          revision: raw["revision"],
          occurred_at: at,
          turn_ref: "ingress-turn:#{id}",
          payload: raw["content"],
          destination: %{
            transport: raw["destination_transport"],
            conversation_ref: raw["destination_conversation_ref"],
            thread_ref: raw["destination_thread_ref"]
          }
        })
      )

    fields =
      ~w(dedupe_key event_ref event_fingerprint source_kind source_ref native_input_id source_item_ref actor_ref revision content source_capabilities destination_transport destination_conversation_ref destination_thread_ref repository_ref work_policy work_policy_digest decision_ref decision_fingerprint decision_document)a

    attrs = Map.new(fields, &{&1, raw[Atom.to_string(&1)]})

    entry =
      Repo.insert!(
        struct!(
          Entry,
          Map.merge(attrs, %{
            id: id,
            status: :decided,
            event_kind: :message,
            actor_kind: :bot,
            occurred_at: at,
            occurred_at_source: :source,
            execution_mode: :shadow,
            decision_action: :start_episode,
            episode_id: episode.id
          })
        )
      )

    {:ok, :ok} = Repo.transaction(fn -> Observations.receive_in_transaction(entry) end)
    entry
  end
end
