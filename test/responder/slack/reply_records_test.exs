defmodule Responder.Slack.ReplyRecordsTest do
  use Responder.DataCase, async: true
  import Ecto.Query

  alias Responder.{Episodes, Repo}
  alias Responder.Fixtures.Episodes, as: Fixtures
  alias Responder.Slack.ReplyRecords
  alias Responder.State.{Record, Records}
  alias Responder.Work.{Activity, ActivityEvent, Custody, Turn}

  @fixture Path.expand("../../../testdata/slack/terraform-source-activity.json", __DIR__)
  @reply Path.expand("../../../testdata/slack/terraform-deployment-reply.json", __DIR__)
  @github_url "https://github.com/octo/example/pull/42"

  test "source links use retained receipts from this episode, never foreign or retired activity" do
    # A bare source UUID used to be displayed despite the exact run URL already being on disk.
    first = claim!()

    payload =
      @reply |> File.read!() |> Jason.decode!() |> get_in(["records", Access.at(0), "payload"])

    {:ok, record} = Records.create(Records.token(first.turn), "plan", "evidence", payload)
    activity = @fixture |> File.read!() |> Jason.decode!()
    event = event!(first, activity)

    [projected] = ReplyRecords.documents("slack", first.episode.id, [record])
    assert projected["presentation"]["source_url"] =~ "/runs/01a085b2-310a"
    assert projected["payload"] == record.payload
    assert Repo.get!(Record, record.id).payload == payload

    second = claim!()
    {:ok, other} = Records.create(Records.token(second.turn), "plan", "evidence", payload)
    assert [plain] = ReplyRecords.documents("slack", second.episode.id, [other])
    refute plain["presentation"]

    Repo.update_all(from(a in ActivityEvent, where: a.id == ^event.id),
      set: [operational_pruned_at: DateTime.utc_now()]
    )

    [plain] = ReplyRecords.documents("slack", first.episode.id, [record])
    refute plain["presentation"]

    Repo.update_all(from(a in ActivityEvent, where: a.id == ^event.id),
      set: [operational_pruned_at: nil]
    )

    Repo.update_all(from(t in Turn, where: t.id == ^first.turn.id),
      set: [operational_pruned_at: DateTime.utc_now()]
    )

    [plain] = ReplyRecords.documents("slack", first.episode.id, [record])
    refute plain["presentation"]
  end

  test "receipt-shaped stdout from another tool is not Emisar source provenance" do
    claim = claim!()

    payload =
      @reply |> File.read!() |> Jason.decode!() |> get_in(["records", Access.at(0), "payload"])

    {:ok, record} = Records.create(Records.token(claim.turn), "plan", "evidence", payload)

    activity =
      @fixture |> File.read!() |> Jason.decode!() |> put_in(["input", "tool"], "read_file")

    event!(claim, activity)
    [plain] = ReplyRecords.documents("slack", claim.episode.id, [record])
    refute plain["presentation"]
  end

  test "a source URL is a link only while this episode's completed call still proves it" do
    # Any well-formed https URL the model typed into source_id became a clickable
    # Slack source. Nothing checked that a tool in this episode ever returned that
    # destination, so a single invented link could send an operator anywhere while
    # wearing the reply's own authority.
    claim = claim!()
    {:ok, record} = evidence!(claim, @github_url)
    event = event!(claim, github_activity())

    [linked] = ReplyRecords.documents("slack", claim.episode.id, [record])
    assert linked["presentation"] == %{"source_url" => @github_url}
    assert linked["payload"] == record.payload

    Repo.update_all(from(a in ActivityEvent, where: a.id == ^event.id),
      set: [operational_pruned_at: DateTime.utc_now()]
    )

    [plain] = ReplyRecords.documents("slack", claim.episode.id, [record])
    refute plain["presentation"]
    assert Repo.get!(Record, record.id).payload == record.payload
  end

  test "a receipt from another episode cannot support a source link" do
    first = claim!()
    event!(first, github_activity())

    second = claim!()
    {:ok, record} = evidence!(second, @github_url)

    [plain] = ReplyRecords.documents("slack", second.episode.id, [record])
    refute plain["presentation"]
  end

  test "a URL the model only wrote into a tool call is not its own receipt" do
    claim = claim!()
    {:ok, record} = evidence!(claim, @github_url)

    [plain] = ReplyRecords.documents("slack", claim.episode.id, [record])
    refute plain["presentation"]

    event!(claim, requested_activity())
    [plain] = ReplyRecords.documents("slack", claim.episode.id, [record])
    refute plain["presentation"]
  end

  test "a failed tool call is not source provenance" do
    claim = claim!()
    {:ok, record} = evidence!(claim, @github_url)
    event!(claim, %{github_activity() | "status" => "failed"})

    [plain] = ReplyRecords.documents("slack", claim.episode.id, [record])
    refute plain["presentation"]
  end

  test "reading back our own records cannot certify the source they carry" do
    # get_work_state returns each saved record, source_id included, and the prompt
    # asks for it every turn. Counting it as provenance would let a model launder
    # any URL into a receipt by writing evidence and then reading it back — the
    # whole gate, defeated without a single external observation.
    claim = claim!()
    {:ok, record} = evidence!(claim, @github_url)
    event!(claim, work_state_activity(record))

    [plain] = ReplyRecords.documents("slack", claim.episode.id, [record])
    refute plain["presentation"]
  end

  test "ingestion retains exactly the URL a completed call returned, and no sibling" do
    # tool.completed evidence is the only durable receipt a non-Emisar server
    # leaves behind, so the projection that stores it decides whether a source can
    # ever be linked. A neighbouring URL of the same shape is not a receipt.
    claim = claim!()

    {:ok, session} =
      Custody.bind_session(
        claim.episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        claim.session.generation,
        claim.session.create_generation,
        "remote:receipts"
      )

    payload = Map.merge(github_activity(), %{"kind" => "mcp", "tool_call_id" => "exec-github"})

    assert {:ok, %{inserted: 1}} =
             Activity.ingest(session.id, [
               %{
                 "id" => "event-github",
                 "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
                 "payload" => payload,
                 "sequence" => 1,
                 "session_id" => session.coop_session_id,
                 "turn_id" => claim.turn.coop_turn_id,
                 "type" => "tool.completed",
                 "version" => 1
               }
             ])

    assert [stored] = Activity.list_for_episode(claim.episode.id)

    assert get_in(stored.payload, ~w(output result structuredContent items)) == [
             hd(get_in(payload, ~w(output result structuredContent items)))
           ]

    {:ok, cited} = evidence!(claim, @github_url)
    {:ok, sibling} = evidence!(claim, @github_url <> "3", "plan.sibling")

    assert [linked, plain] = ReplyRecords.documents("slack", claim.episode.id, [cited, sibling])
    assert linked["presentation"] == %{"source_url" => @github_url}
    refute plain["presentation"]
  end

  defp evidence!(claim, source_id, operation \\ "plan") do
    # The harvested Terraform citation, rebound structurally to the source the
    # model claims: only source_id and its label change.
    payload =
      @reply
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["records", Access.at(0), "payload"])
      |> Map.merge(%{"source_id" => source_id, "source_name" => source_id})

    Records.create(Records.token(claim.turn), operation, "evidence", payload)
  end

  defp github_activity do
    # Structural composition: the exact read_github_conversation item and html_url
    # asserted in test/responder/github/client_test.exs, inside the tool.completed
    # envelope harvested in testdata/slack/terraform-source-activity.json.
    %{
      "input" => %{
        "server" => "responder-github",
        "tool" => "read_github_conversation",
        "arguments" => %{"limit" => 1, "page" => 1, "section" => "subject"}
      },
      "status" => "completed",
      "output" => %{
        "result" => %{
          "structuredContent" => %{
            "items" => [
              %{
                "kind" => "pull_request",
                "number" => 42,
                "state" => "open",
                "title" => "Make GitHub complete",
                "url" => @github_url
              }
            ]
          }
        }
      }
    }
  end

  defp work_state_activity(record) do
    # Structural composition: the record document Records.model_records/2 hands
    # get_work_state, inside the same tool.completed envelope.
    %{
      "input" => %{
        "server" => "responder-state",
        "tool" => "get_work_state",
        "arguments" => %{"limit" => 100}
      },
      "status" => "completed",
      "output" => %{
        "result" => %{
          "structuredContent" => %{
            "records" => [
              %{
                "kind" => record.kind,
                "payload" => record.payload,
                "ref" => record.ref,
                "status" => Atom.to_string(record.status)
              }
            ]
          }
        }
      }
    }
  end

  defp requested_activity do
    # Structural composition of the harvested native execute shape in
    # testdata/learning/livebook-intended-zero/evidence.json: the URL appears only
    # in the command the model wrote, never in what the call returned.
    %{
      "kind" => "execute",
      "input" => %{"command" => "curl -sS #{@github_url}", "cwd" => "/tmp/repository"},
      "title" => "curl -sS #{@github_url}",
      "status" => "completed",
      "output" => %{"exit_code" => 7, "formatted_output" => "curl: (7) Failed to connect"}
    }
  end

  defp claim! do
    id = Ecto.UUID.generate()

    {:ok, started} =
      Episodes.apply(
        Fixtures.admit_input(%{
          episode_id: id,
          episode_key: id,
          native_input_id: id,
          turn_ref: id
        })
      )

    {:ok, session} =
      Custody.pin_episode(started.episode.id, "policy:links", String.duplicate("a", 64))

    {:ok, claim} = Custody.claim_next("links:#{id}", 60, :work)
    turn = Repo.update!(Ecto.Changeset.change(claim.turn, coop_turn_id: "remote:#{id}"))

    %{
      episode: started.episode,
      lease_ref: claim.lease_ref,
      session: session,
      turn: turn
    }
  end

  defp event!(claim, payload) do
    Repo.insert!(%ActivityEvent{
      episode_id: claim.episode.id,
      session_id: claim.session.id,
      remote_event_id: Ecto.UUID.generate(),
      remote_session_id: claim.session.id,
      coop_turn_id: claim.turn.coop_turn_id,
      sequence: 1,
      kind: "tool.completed",
      version: 1,
      occurred_at: DateTime.utc_now(),
      payload: payload,
      payload_fingerprint: String.duplicate("a", 64)
    })
  end
end
