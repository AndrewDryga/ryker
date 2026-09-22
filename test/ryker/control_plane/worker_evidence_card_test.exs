defmodule Ryker.ControlPlane.WorkerEvidenceCardTest do
  use Ryker.DataCase, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2, rendered_to_string: 1]

  alias Ryker.ControlPlane.{EpisodePage, Projection, WorkerEvidenceCard}
  alias Ryker.CoopFleet.SessionEvidence
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Repo
  alias Ryker.Work.Custody

  @authority_digest String.duplicate("d", 64)
  @policy_digest String.duplicate("b", 64)
  @filtered Path.expand("../../../testdata/protocol/coop-session-evidence-v1.json", __DIR__)
  @open Path.expand("../../../testdata/protocol/coop-session-evidence-open-v1.json", __DIR__)

  defp fixture(path, overrides \\ %{}) do
    path |> File.read!() |> Jason.decode!() |> deep_merge(overrides)
  end

  defp deep_merge(%{} = base, %{} = overrides) do
    Map.merge(base, overrides, fn
      _key, %{} = left, %{} = right -> deep_merge(left, right)
      _key, _left, right -> right
    end)
  end

  defp session!(suffix) do
    command =
      EpisodeFixtures.admit_input(%{
        episode_id: Ecto.UUID.generate(),
        episode_key: "evidence-card:#{suffix}:#{Ecto.UUID.generate()}",
        native_input_id: "source:#{suffix}:#{Ecto.UUID.generate()}",
        occurred_at: DateTime.utc_now(),
        turn_ref: "turn:#{suffix}:#{Ecto.UUID.generate()}"
      })

    {:ok, _transition} = Episodes.apply(command)

    {:ok, session} =
      Custody.pin_episode(
        command.episode_id,
        "work-read-only",
        @policy_digest,
        @authority_digest,
        "ryker"
      )

    {:ok, bound} =
      session
      |> Ecto.Changeset.change(coop_session_id: "remote_01j9zq3f8m0c7e6kq9y2s4x1nt")
      |> Repo.update()

    bound
  end

  defp episode_key(session),
    do: Repo.get!(Ryker.Episodes.Episode, session.episode_id).key

  defp html(episode_id) do
    %{episode_id: episode_id, __changed__: nil}
    |> WorkerEvidenceCard.render()
    |> rendered_to_string()
  end

  test "a filtered capture renders access, network and task without naming a withheld destination" do
    session = session!("render")

    {:ok, _stored} =
      SessionEvidence.record(session.id, fixture(@filtered),
        worker_id: "worker-a",
        placement_generation: 1
      )

    rendered = html(session.episode_id)
    document = LazyHTML.from_fragment(rendered)

    assert rendered =~ "Network access"
    assert rendered =~ "Filtered"
    assert LazyHTML.text(document) =~ "Withheld by this session's policy"
    assert rendered =~ "Enforcer reported ok"

    assert rendered =~ "Destination withheld"
    # A literal <template> element hides its contents in a browser; the cards
    # have to be ordinary elements the reader can actually see.
    refute rendered =~ "<template"
    assert rendered =~ "Coop task"
    assert rendered =~ "Fix API timeout"
    assert rendered =~ "Checklist 3/4 recorded"
    assert LazyHTML.query(document, ".event-facts") |> Enum.empty?()

    assert Enum.all?(LazyHTML.query(document, ".case-event-details"), fn detail ->
             Enum.any?(
               LazyHTML.attribute(detail, "class"),
               &String.contains?(&1, "ui-disclosure")
             )
           end)

    # The projection withholds the names, and so does the page.
    refute rendered =~ "blocked.example"
    refute rendered =~ "api.example.com"
  end

  test "opening Network shows what the numbers can and cannot be trusted for" do
    # A refusal list on its own invites an operator to read the counters beside
    # it as measurements. Opening the card has to say which layers reported,
    # which metrics are exact, what the collector lost and what the session
    # receipt still claims -- a degraded collector and a lower-bound count are
    # the difference between "nothing happened" and "we did not see it".
    session = session!("network-detail")

    {:ok, _stored} =
      SessionEvidence.record(session.id, fixture(@filtered),
        worker_id: "worker-a",
        placement_generation: 1
      )

    rendered = html(session.episode_id)

    # Health is per layer, never one blanket status.
    assert rendered =~ "enforcer ok"
    assert rendered =~ "collector degraded (socket_sample_lag)"

    # The collector's own alert about why a number may be wrong.
    assert rendered =~ "collector_health"
    assert rendered =~ "1 more alerts were omitted"

    # Coverage is per metric, and the run this observation belongs to is named
    # with its epoch rather than borrowed from whatever turn is on screen. Its
    # opaque identity uses the shared exact-copy treatment.
    assert rendered =~ "All 9 measurements exact"
    assert rendered =~ ~s(data-copy-value="run-7f3a")

    assert fact_value(rendered, ".network-summary .ui-disclosure-body", "Gateway epoch") ==
             "epoch-1"

    assert rendered =~ "proxy-streams-and-sampled-tcp-sockets"

    # The session receipt: final and complete are independent words.
    assert rendered =~ "Session receipt"
    assert rendered =~ "Provisional · partial"
    assert rendered =~ "still open"

    # The receipt's own coverage and loss, not the newest run's: nine
    # lower-bound metrics and an unattributed loss is why it says partial.
    assert rendered =~ "proxy_bytes lower-bound"
    assert rendered =~ "unattributed loss — totals are lower bounds"
    assert rendered =~ "counter_overflow"
  end

  test "a filtered session that has not run still shows its provisional receipt" do
    # The export reports no_run with a provisional receipt precisely so "nothing
    # has run yet" is distinguishable from a session that ran and saw nothing.
    # A card that hid the disclosure because the observation was empty would put
    # that silence straight back.
    session = session!("no-run-receipt")

    quiet =
      fixture(@filtered, %{
        "network" => %{
          "observation" => fixture(@open)["network"]["observation"] |> Map.put("status", "no_run")
        }
      })

    {:ok, _stored} =
      SessionEvidence.record(session.id, quiet, worker_id: "worker-a", placement_generation: 1)

    rendered = html(session.episode_id)

    assert rendered =~ "has not run under its captured policy yet"
    assert rendered =~ "Session receipt"
    assert rendered =~ "Provisional · partial"
    refute rendered =~ "0 B"
  end

  test "an unmeasured counter is never rendered as zero traffic" do
    session = session!("unknown-counters")

    blank =
      fixture(@filtered)
      |> put_in(~w(network observation counters sent_bytes), nil)
      |> put_in(~w(network observation counters received_bytes), nil)

    {:ok, _stored} =
      SessionEvidence.record(session.id, blank, worker_id: "worker-a", placement_generation: 1)

    rendered = html(session.episode_id)

    assert rendered =~ "Not recorded"
    refute rendered =~ "0 B"
  end

  test "refusals nobody counted are not reported as no refusals" do
    # The refusal line reads two counters. When neither was measured and the
    # export carried no denial rows either, there is nothing to report -- and
    # "None" there is the same lie as a 0 B traffic reading, on the one number
    # an operator uses to decide whether a policy did anything at all.
    session = session!("uncounted-refusals")

    uncounted =
      fixture(@filtered)
      |> put_in(~w(network observation counters denied_tls_connections), nil)
      |> put_in(~w(network observation counters denied_dns_queries), nil)
      |> put_in(~w(network observation denials), [])

    {:ok, _stored} =
      SessionEvidence.record(session.id, uncounted,
        worker_id: "worker-a",
        placement_generation: 1
      )

    rendered = html(session.episode_id)

    assert fact_value(rendered, ".network-summary", "Refusals") == "Not recorded"
    refute rendered =~ ~r|<dt>Refusals</dt><dd>None|
  end

  test "a measured zero refusal count says none rather than not recorded" do
    session = session!("zero-refusals")

    none =
      fixture(@filtered)
      |> put_in(~w(network observation counters denied_tls_connections), "0")
      |> put_in(~w(network observation denials), [])

    {:ok, _stored} =
      SessionEvidence.record(session.id, none, worker_id: "worker-a", placement_generation: 1)

    assert fact_value(html(session.episode_id), ".network-summary", "Refusals") == "None"
  end

  test "an open unbound capture renders no empty worker evidence" do
    session = session!("open-render")

    {:ok, _stored} =
      SessionEvidence.record(
        session.id,
        fixture(@open, %{"session_id" => "remote_01j9zq3f8m0c7e6kq9y2s4x1nt"}),
        worker_id: "worker-a",
        placement_generation: 1
      )

    rendered = html(session.episode_id)

    assert String.trim(rendered) == ""
  end

  test "an open capture with a bound task renders only the task" do
    session = session!("open-bound-task")

    capture =
      fixture(@open, %{
        "session_id" => "remote_01j9zq3f8m0c7e6kq9y2s4x1nt",
        "task" => fixture(@filtered)["task"]
      })

    {:ok, _stored} =
      SessionEvidence.record(session.id, capture,
        worker_id: "worker-a",
        placement_generation: 1
      )

    rendered = html(session.episode_id)

    assert rendered =~ "Worker evidence"
    assert rendered =~ "Coop task"
    assert rendered =~ "Fix API timeout"
    refute rendered =~ "nothing to enforce or observe"
    refute rendered =~ "<h3>Network access</h3>"
    refute rendered =~ "<h3>Network</h3>"
  end

  test "an episode with no capture renders no evidence section at all" do
    session = session!("no-capture")
    assert html(session.episode_id) |> String.trim() == ""
  end

  test "the episode page shows the capture for the episode it is rendering" do
    # The card reads the page snapshot, and the snapshot's episode map is the
    # only thing on the page that says which episode is on screen. A hook bound
    # to a key the projection never sets renders nothing -- on every episode,
    # forever -- and a component test that hands the card its own episode id
    # cannot see that: the card works and the page still shows nothing.
    session = session!("page")

    {:ok, _stored} =
      SessionEvidence.record(session.id, fixture(@filtered),
        worker_id: "worker-a",
        placement_generation: 1
      )

    {:ok, snapshot} = Projection.episode(episode_key(session))

    html =
      render_component(&EpisodePage.render/1,
        snapshot: snapshot,
        timeline: %{items: [], truncated: false},
        requests: nil,
        params: %{}
      )

    assert html =~ "Worker evidence"
    assert html =~ "Network access"
    assert html =~ "Coop task"
  end

  test "a projection carrying no episode id renders nothing instead of failing the page" do
    # Several callers pass a snapshot whose episode is a reference only. A card
    # with nothing to show must not be the reason a page cannot render.
    assert html(nil) |> String.trim() == ""
  end

  defp fact_value(rendered, scope, label) do
    rendered
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{scope} > .ui-facts > div")
    |> Enum.find(&(LazyHTML.query(&1, "dt") |> LazyHTML.text() |> String.trim() == label))
    |> LazyHTML.query("dd")
    |> LazyHTML.text()
    |> String.trim()
  end
end
