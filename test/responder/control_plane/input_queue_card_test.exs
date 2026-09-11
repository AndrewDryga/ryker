defmodule Responder.ControlPlane.InputQueueCardTest do
  @moduledoc """
  The Input queue card: saved or not, waiting for what, handed to routing or not.

  The queue used to be invisible between Engagement and the Routing briefing,
  so "Responder never saw this message" and "Responder saved it and it is
  waiting behind an earlier message" read identically. The card reads only the
  durable custody row and the admission attempt that claimed it. Timing that
  nobody recorded is "Not recorded", never a zero-second wait.
  """
  use Responder.DataCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Responder.Admission.Attempt
  alias Responder.CanonicalJSON
  alias Responder.ControlPlane.{EpisodePage, ModelRequests, Projection, RequestPage}
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Ingress.Inbox
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Slack.Input

  @now ~U[2026-09-04 22:51:44.000000Z]

  test "the queue card follows Engagement inside Getting ready" do
    {_entry, episode} = decided!()
    html = rendered(episode)

    positions =
      for label <- ["Participation settings", "Standing rules", "Engagement", "Input queue"],
          do: :binary.match(html, "<h3>" <> label) |> elem(0)

    assert positions == Enum.sort(positions)
  end

  test "a decided input was handed to routing at its recorded claim time" do
    {entry, episode} = decided!()
    claimed_at = DateTime.add(@now, 280, :millisecond)
    attempt!(entry, claimed_at)

    card = card(rendered(episode), entry)
    assert card =~ "Handed to routing"
    assert card =~ "A routing worker picked up this input."
    assert card =~ "Queue wait"
    assert card =~ "280 ms"
    assert card =~ "Routing claim"
    assert card =~ "22:51:44.280"
    assert card =~ "Queue claims"
  end

  test "timing nobody recorded is not recorded, never a zero-second wait" do
    # The claim clears the retry fields and updated_at moves on other writes,
    # so an input whose attempt row is gone has no claim time to show.
    {entry, episode} = decided!()
    card = card(rendered(episode), entry)

    assert card =~ "Handed to routing"
    assert card =~ "Routing claim"
    assert card =~ "Not recorded"
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

    card = card(rendered(episode), entry)
    assert card =~ "Superseded"
    assert card =~ "Input remains saved"
    assert card =~ "newer revision"
    refute card =~ "Handed to routing"
  end

  test "a blocked input says automatic retries stopped and links the existing recovery" do
    {entry, _input} = pending!()

    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [status: :blocked, last_error_code: "provider_unavailable", attempt_count: 8]
    )

    html = standalone(entry)
    card = card(html, entry)
    assert card =~ "Needs attention"
    assert card =~ "Automatic retries have stopped"
    assert card =~ "Provider unavailable"
    assert card =~ "8"
    assert html =~ "href=\"/failures/admission/#{URI.encode_www_form(Inbox.ref(entry))}\""
    refute card =~ "Handed to routing"
  end

  test "a retrying input shows when it becomes eligible again, not a promised pickup" do
    {entry, _input} = pending!()
    eligible_at = DateTime.add(DateTime.utc_now(), 3_600, :second)

    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [next_attempt_at: eligible_at, last_error_code: "coop_unreachable", attempt_count: 2]
    )

    card = card(standalone(entry), entry)
    assert card =~ "Waiting to retry"
    assert card =~ "Input remains saved"
    assert card =~ "Coop unreachable"
    assert card =~ "Eligible for retry after"
    assert card =~ Calendar.strftime(eligible_at, "%H:%M:%S")
    refute card =~ "Needs attention"
  end

  test "a pending input behind an earlier pending input names that input" do
    {first, _input} = pending!(text: "Check the deployment first")
    {second, _later_input} = pending!(text: "And then this one", later: 5)

    html = standalone(second)
    card = card(html, second)
    assert card =~ "Waiting"
    assert card =~ "Waiting for an earlier input in this conversation"
    assert card =~ "Check the deployment first"
    assert card =~ "current"

    assert LazyHTML.from_document(html)
           |> LazyHTML.query(
             "#event-queue-#{second.id} a[href='/timeline/ingress-input%3A#{first.id}']"
           )
           |> Enum.count() == 1
  end

  test "a pending input with no evidenced blocker is saved and waiting for pickup" do
    {entry, _input} = pending!()

    card = card(standalone(entry), entry)
    assert card =~ "Saved; waiting for routing pickup."
    refute card =~ "All workers are busy"
    refute card =~ "earlier input"
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

    card = card(standalone(entry), entry)
    assert card =~ "Handed to routing"
    assert card =~ "current"
    refute card =~ "Saved; waiting"
  end

  test "the standalone input view carries all four preparation cards" do
    {entry, _input} = pending!()
    html = standalone(entry)

    for label <- ["Participation settings", "Standing rules", "Engagement", "Input queue"] do
      assert html =~ "<h3>" <> label
    end
  end

  defp card(html, entry) do
    LazyHTML.from_document(html)
    |> LazyHTML.query("#event-queue-#{entry.id}, #queue-#{entry.id}")
    |> LazyHTML.text()
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

    render_component(&EpisodePage.getting_ready/1, steps: view.preparation) <>
      render_component(&RequestPage.render/1,
        view: view,
        params: %{},
        path: "/timeline/ingress-input:#{entry.id}"
      )
  end

  defp attempt!(entry, at) do
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

    {Repo.get!(Entry, entry.id), input}
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
          payload: Responder.Ingress.Input.document(input),
          turn_ref: "ingress-turn:#{entry.id}"
        })
      )

    decision = %{
      "action" => "reply",
      "reason" => "A direct reply.",
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
