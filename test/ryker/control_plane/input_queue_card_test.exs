defmodule Ryker.ControlPlane.InputQueueCardTest do
  @moduledoc """
  The Input queue card: saved or not, waiting for what, handed to routing or not.

  The queue used to be invisible between Participation and the Routing briefing,
  so "Ryker never saw this message" and "Ryker saved it and it is
  waiting behind an earlier message" read identically. The card reads only the
  durable custody row and the admission attempt that claimed it. Timing that
  nobody recorded is "Not recorded", never a zero-second wait.
  """
  use Ryker.DataCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Ryker.Admission.Attempt
  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{EpisodePage, ModelRequests, Projection}
  alias Ryker.ControlPlane.EpisodeTrace.Preparation
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Ingress.InputCustodyTransition
  alias Ryker.Slack.Input

  @now ~U[2026-09-04 22:51:44.000000Z]

  test "the queue card follows Participation inside Getting ready" do
    {_entry, episode} = decided!()
    html = rendered(episode)

    positions =
      for label <- ["Participation", "Input queue"],
          do: :binary.match(html, label) |> elem(0)

    assert positions == Enum.sort(positions)
  end

  test "the ordinary path reads received, participation, queue, then routing" do
    {entry, episode} = decided!()
    attempt!(entry, DateTime.add(entry.inserted_at, 290, :millisecond))
    html = rendered(episode)

    positions =
      for id <- [
            "story-message-#{entry.id}",
            "event-participation-#{entry.id}",
            "event-queue-#{entry.id}",
            "admission-#{entry.id}-1"
          ],
          do: :binary.match(html, ~s(id="#{id}")) |> elem(0)

    assert positions == Enum.sort(positions)
  end

  test "a later retry starts a new queue run without changing the sealed first run" do
    {entry, _input} = pending!()
    claimed_at = DateTime.add(entry.inserted_at, 290, :millisecond)

    :ok =
      Inbox.record_transition_in_transaction(entry, :claimed,
        occurred_at: claimed_at,
        attempt: 1,
        owner_ref: "routing:first"
      )

    [first_run] = queue_steps(entry)

    :ok =
      Inbox.record_transition_in_transaction(entry, :retry_scheduled,
        occurred_at: DateTime.add(claimed_at, 2, :second),
        attempt: 1,
        eligible_at: DateTime.add(claimed_at, 62, :second),
        error_code: "coop_unreachable"
      )

    [sealed, retry] = queue_steps(entry)
    assert sealed == first_run
    assert Enum.map(sealed.queue.events, & &1.label) == ["Saved", "Picked up"]
    assert retry.queue.qualifier == "Retry 1"
    assert Enum.map(retry.queue.events, & &1.label) == ["Retry scheduled", "Current"]
  end

  test "a transport timeout reattaches the same routing attempt instead of inventing a retry" do
    {entry, _input} = pending!()
    claimed_at = DateTime.add(entry.inserted_at, 290, :millisecond)

    :ok =
      Inbox.record_transition_in_transaction(entry, :claimed,
        occurred_at: claimed_at,
        attempt: 1,
        owner_ref: "routing:first"
      )

    :ok =
      Inbox.record_transition_in_transaction(entry, :retry_scheduled,
        occurred_at: DateTime.add(claimed_at, 1, :second),
        attempt: 1,
        eligible_at: DateTime.add(claimed_at, 2, :second),
        error_code: "coop_timeout"
      )

    [_sealed, reattached] = queue_steps(entry)
    assert reattached.queue.qualifier == "Reattached to attempt 1"
    refute reattached.queue.qualifier =~ "Retry"
  end

  test "a decided input was handed to routing at its recorded claim time" do
    {entry, episode} = decided!()
    claimed_at = DateTime.add(@now, 280, :millisecond)
    attempt!(entry, claimed_at)

    card = card(rendered(episode), entry)
    assert card =~ "Picked up"
    assert card =~ "A routing worker claimed the input."
    assert card =~ "280 ms"
    assert card =~ "22:51:44.280"
    document = rendered(episode) |> LazyHTML.from_document()

    assert LazyHTML.query(document, "#event-queue-#{entry.id} .case-card-heading-meta")
           |> LazyHTML.text() =~ "280 ms"

    assert Enum.empty?(LazyHTML.query(document, "#event-queue-#{entry.id} .queue-span"))
    refute card =~ "Input ID"
    refute card =~ "Technical details"
  end

  test "a missing pickup transition is not reconstructed from terminal state" do
    {entry, episode} = decided!()
    card = card(rendered(episode), entry)

    assert card =~ "Saved"
    refute card =~ "Picked up"
    refute card =~ "0 ms"
  end

  test "a superseded input keeps its save facts and says a newer revision won" do
    {entry, episode} = decided!()

    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [
        status: :superseded,
        last_error_code: "stale_input_revision",
        last_error_detail: "%{latest: 2, submitted: 1}"
      ]
    )

    transition!(entry, :superseded, DateTime.add(entry.inserted_at, 3, :second), attempt: 0)

    card = card(rendered(episode), entry)
    assert card =~ "Superseded"
    assert card =~ "newer revision"
    refute card =~ "Picked up"
  end

  test "a blocked input says automatic retries stopped and links the existing recovery" do
    {entry, _input} = pending!()

    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [status: :blocked, last_error_code: "provider_unavailable", attempt_count: 8]
    )

    transition!(entry, :blocked, DateTime.add(entry.inserted_at, 8, :second),
      attempt: 8,
      error_code: "provider_unavailable"
    )

    html = standalone(entry)
    card = card(html, entry)
    assert card =~ "Automatic retries stopped"
    assert card =~ "Provider unavailable"
    assert card =~ "8 attempts"
    assert html =~ "href=\"/failures/admission/#{URI.encode_www_form(Inbox.ref(entry))}\""
    refute card =~ "Picked up"
  end

  test "a retrying input shows when it becomes eligible again, not a promised pickup" do
    {entry, _input} = pending!()
    eligible_at = DateTime.add(DateTime.utc_now(), 3_600, :second)

    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [next_attempt_at: eligible_at, last_error_code: "coop_unreachable", attempt_count: 2]
    )

    transition!(entry, :retry_scheduled, DateTime.add(entry.inserted_at, 2, :second),
      attempt: 2,
      eligible_at: eligible_at,
      error_code: "coop_unreachable"
    )

    card = card(standalone(entry), entry)
    assert card =~ "Retry scheduled"
    assert card =~ "Coop unreachable"
    assert card =~ "Eligible to retry at"
    assert card =~ Calendar.strftime(eligible_at, "%H:%M:%S")
    refute card =~ "Automatic retries stopped"
  end

  test "a pending input behind an earlier pending input names that input" do
    {first, _input} = pending!(text: "Check the deployment first")
    {second, _later_input} = pending!(text: "And then this one", later: 5)

    html = standalone(second)
    card = card(html, second)
    assert card =~ "Waiting for an earlier input"
    assert card =~ "This conversation already had an earlier message waiting to be routed."
    assert card =~ "Check the deployment first"
    assert card =~ "Current"

    assert LazyHTML.from_document(html)
           |> LazyHTML.query(
             "#event-queue-#{second.id} a[href='/timeline/ingress-input%3A#{first.id}']"
           )
           |> Enum.count() == 1
  end

  test "a sealed predecessor reason does not change when the earlier input is later pruned" do
    {first, _input} = pending!(text: "Check the deployment first")
    {second, _later_input} = pending!(text: "And then this one", later: 5)

    transition!(second, :claimed, DateTime.add(second.inserted_at, 1, :second),
      attempt: 1,
      owner_ref: "routing:stable-prefix"
    )

    before = card(standalone(second), second)

    Repo.update_all(from(saved in Entry, where: saved.id == ^first.id),
      set: [content: %{}, operational_pruned_at: DateTime.utc_now()]
    )

    assert card(standalone(second), second) == before
    assert before =~ "Check the deployment first"
  end

  test "a pending input with no evidenced blocker is saved and waiting for pickup" do
    {entry, _input} = pending!()

    card = card(standalone(entry), entry)
    assert card =~ "The input entered the routing queue."
    assert card =~ "Waiting for a routing worker to pick it up."
    refute card =~ "All workers are busy"
    refute card =~ "earlier input"
  end

  test "an older input without ledger evidence says its queue history is unavailable" do
    {entry, _input} = pending!()

    Repo.delete_all(
      from(transition in InputCustodyTransition, where: transition.input_id == ^entry.id)
    )

    card = card(standalone(entry), entry)
    assert card =~ "Queue history unavailable"
    assert card =~ "Detailed queue transitions were not recorded for this older input."
    refute card =~ "The input entered the routing queue."
  end

  test "an input a routing worker currently holds says so as current state" do
    {entry, _input} = pending!()

    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [
        lease_ref: "ingress-lease:test",
        lease_owner: "admission-1",
        lease_expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
        attempt_count: 1
      ]
    )

    transition!(entry, :claimed, DateTime.add(entry.inserted_at, 1, :second),
      attempt: 1,
      owner_ref: "admission-1"
    )

    card = card(standalone(entry), entry)
    assert card =~ "Picked up"
    refute card =~ "Current"
    refute card =~ "Waiting for a routing worker"
  end

  test "the standalone input view carries both preparation cards" do
    {entry, _input} = pending!()
    html = standalone(entry)

    for label <- ["Participation", "Input queue"] do
      assert html =~ label
    end
  end

  defp card(html, entry) do
    LazyHTML.from_document(html)
    |> LazyHTML.query("#event-queue-#{entry.id}, #queue-#{entry.id}")
    |> LazyHTML.text()
  end

  defp queue_steps(entry) do
    entry
    |> List.wrap()
    |> Preparation.steps()
    |> Enum.filter(&(&1.stage == "Input queue"))
  end

  defp rendered(episode) do
    {:ok, detail} = Projection.episode(episode.key)
    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})

    render_component(&EpisodePage.render/1,
      snapshot: detail,
      timeline: timeline,
      requests: nil,
      params: %{}
    )
  end

  defp standalone(entry) do
    {:ok, view} = ModelRequests.project_input(entry.id, %{})

    render_component(&EpisodePage.getting_ready/1,
      steps: view.preparation,
      requests: view.timeline
    )
  end

  defp attempt!(entry, at) do
    transition!(entry, :claimed, at, attempt: 1, owner_ref: "routing:test")

    Repo.insert!(%Attempt{
      input_id: entry.id,
      generation: 1,
      policy: "admission",
      policy_digest: String.duplicate("b", 64),
      phase: "context_prepared",
      milestones: %{"context_prepared" => DateTime.to_iso8601(at)},
      inserted_at: at,
      updated_at: at
    })
  end

  defp pending!(options \\ []) do
    occurred_at = DateTime.add(@now, Keyword.get(options, :later, 0), :second)

    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: "U123"},
        channel_ref: "C456",
        content: %{"text" => Keyword.get(options, :text, "Terraform plan: 2 to add")},
        event_kind: :message,
        event_ref: "Ev-queue-#{Ecto.UUID.generate()}",
        message_ref: "#{1_788_562_304 + System.unique_integer([:positive])}.000100",
        occurred_at: occurred_at,
        revision: 1,
        thread_ref: nil,
        workspace_ref: "TC9F5B40D364C"
      })

    {:ok, %{entry: entry}} = Inbox.record(input)

    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [inserted_at: occurred_at]
    )

    Repo.update_all(
      from(transition in InputCustodyTransition, where: transition.input_id == ^entry.id),
      set: [occurred_at: occurred_at]
    )

    {Repo.get!(Entry, entry.id), input}
  end

  defp transition!(entry, kind, at, options) do
    :ok =
      Inbox.record_transition_in_transaction(
        entry,
        kind,
        Keyword.put(options, :occurred_at, at)
      )
  end

  defp decided! do
    {entry, input} = pending!()

    {:ok, %{episode: episode}} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          actor_ref: "slack:user:U123",
          destination: %{
            conversation_ref: "slack:TC9F5B40D364C:C456",
            thread_ref: entry.source_item_ref,
            transport: "slack"
          },
          episode_id: entry.id,
          episode_key: "ingress-input:#{entry.id}",
          native_input_id: entry.native_input_id,
          occurred_at: @now,
          payload: Ryker.Ingress.Input.document(input),
          turn_ref: "ingress-turn:#{entry.id}"
        })
      )

    decision = %{
      "action" => "reply",
      "reason" => "A direct reply.",
      "repository_source" => nil,
      "work_class" => "conversational"
    }

    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [
        decision_action: :reply,
        decision_document: decision,
        decision_fingerprint: CanonicalJSON.digest(decision),
        decision_ref: "decision:#{entry.id}",
        episode_id: episode.id,
        inserted_at: @now,
        status: :decided
      ]
    )

    {Repo.get!(Entry, entry.id), episode}
  end
end
