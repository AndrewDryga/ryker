defmodule Responder.ControlPlane.LazyArtifactTest do
  @moduledoc """
  Heavy bodies load when a reader opens them, and stop existing when revoked.

  Collapsing rendered HTML does not avoid preparing the body behind it. The
  Timeline sanitizes and re-encodes every retained prompt on every refresh,
  with a 2 MiB allowance per artifact and up to twenty turns, for text that is
  almost always closed. The cost lands on the page an operator opens while an
  incident is running.

  The other half is the opposite obligation: keeping a stale view is only safe
  for a transient failure. A confirmed expiry, redaction or authorization loss
  removes the content, and no reading state may bring it back.
  """
  use Responder.DataCase, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Responder.ControlPlane.{Endpoint, EpisodePage, ModelRequests, Projection}
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Work.{Custody, Submission, Turn}

  @endpoint Endpoint

  setup do
    start_supervised!(
      {Endpoint,
       [
         server: false,
         secret_key_base: String.duplicate("s", 64),
         pubsub_server: Responder.ControlPlane.PubSub,
         live_view: [signing_salt: "control-plane-test"],
         check_origin: ["//localhost:4321"],
         url: [host: "localhost", port: 4321],
         control_plane: %{
           actions: %{},
           csrf_secret: String.duplicate("s", 32),
           observability: %{},
           projection: Projection.callbacks()
         }
       ]}
    )

    :ok
  end

  test "an unopened body does not grow the loaded document" do
    small = work_with_prompt!("small", String.duplicate("a", 1_000))
    large = work_with_prompt!("large", String.duplicate("a", 200_000))

    assert bytes(small) > 0

    assert bytes(large) == bytes(small),
           "an artifact nobody opened must not reach the reader's document"

    # The card still knows what is behind the disclosure.
    assert prompt_section(large).artifact.bytes > prompt_section(small).artifact.bytes
    assert prompt_section(large).artifact.state == :collapsed
    assert prompt_section(large).artifact.text == nil
  end

  test "opening one body prepares that body and no other" do
    first = work_with_prompt!("first", String.duplicate("a", 50_000))
    second = work_with_prompt!("second", String.duplicate("b", 50_000))

    id = prompt_section(first).artifact_id
    assert is_binary(id)

    {:ok, timeline} = ModelRequests.timeline(first.episode.key, %{"disclosed" => [id]})
    opened = find_prompt(timeline)
    assert opened.artifact.state == :retained
    assert opened.artifact.text =~ "aaaa"

    other = prompt_section(second)
    assert other.artifact.state == :collapsed
    assert other.artifact.text == nil
  end

  test "an artifact identity is stable enough to reopen after a refresh" do
    work = work_with_prompt!("stable", String.duplicate("a", 20_000))
    id = prompt_section(work).artifact_id

    {:ok, again} = ModelRequests.timeline(work.episode.key, %{})
    assert find_prompt(again).artifact_id == id
  end

  test "expiry removes an opened body instead of keeping the reader's copy" do
    # Retention already pruned this prompt. The reader had it open; privacy and
    # retention win over preserving their place, and nothing may restore it.
    work = work_with_prompt!("expired", String.duplicate("a", 20_000))
    id = prompt_section(work).artifact_id

    Repo.get!(Turn, work.turn.id)
    |> Ecto.Changeset.change(operational_pruned_at: DateTime.utc_now())
    |> Repo.update!()

    {:ok, timeline} = ModelRequests.timeline(work.episode.key, %{"disclosed" => [id]})
    section = find_prompt(timeline)

    assert section.artifact.state == :expired
    assert section.artifact.text == nil

    html = rendered(work.episode, timeline)
    assert html =~ "data-revoked=\"true\""
    refute html =~ String.duplicate("a", 200)
  end

  test "the rendered collapsed disclosure carries its artifact identity" do
    work = work_with_prompt!("rendered", String.duplicate("a", 30_000))
    {:ok, timeline} = ModelRequests.timeline(work.episode.key, %{})
    html = rendered(work.episode, timeline)

    assert html =~ "data-artifact=\"#{prompt_section(work).artifact_id}\""
    refute html =~ "data-revoked"
    refute html =~ String.duplicate("a", 200)
  end

  test "a body the reader opened stays open through a refresh" do
    # Losing the prompt on the next projection refresh makes the page unusable
    # during exactly the running work it exists to explain.
    work = work_with_prompt!("live", String.duplicate("a", 30_000))
    id = prompt_section(work).artifact_id

    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, _html} = live(conn, "/timeline/" <> URI.encode_www_form(work.episode.key))

    refute render(view) =~ String.duplicate("a", 200)

    render_hook(view, "disclose", %{"artifact" => id})
    assert render(view) =~ String.duplicate("a", 200)

    render_hook(view, "refresh", %{})
    assert render(view) =~ String.duplicate("a", 200)
  end

  test "an unknown or oversized artifact reference discloses nothing" do
    work = work_with_prompt!("guarded", String.duplicate("a", 30_000))
    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, _html} = live(conn, "/timeline/" <> URI.encode_www_form(work.episode.key))

    render_hook(view, "disclose", %{"artifact" => String.duplicate("x", 512)})
    render_hook(view, "disclose", %{"artifact" => "work-unknown-request"})
    render_hook(view, "disclose", %{})

    refute render(view) =~ String.duplicate("a", 200)
  end

  defp bytes(work) do
    {:ok, timeline} = ModelRequests.timeline(work.episode.key, %{})

    timeline.items
    |> Enum.flat_map(& &1.sections)
    |> Enum.map(&byte_size(&1.artifact.text || ""))
    |> Enum.sum()
  end

  defp prompt_section(work) do
    {:ok, timeline} = ModelRequests.timeline(work.episode.key, %{})
    find_prompt(timeline)
  end

  defp find_prompt(timeline) do
    timeline.items
    |> Enum.flat_map(& &1.sections)
    |> Enum.find(&(&1.id == "request"))
  end

  defp rendered(episode, timeline) do
    {:ok, detail} = Projection.episode(episode.key)

    render_component(&EpisodePage.render/1,
      snapshot: detail,
      timeline: timeline,
      requests: nil,
      params: %{}
    )
  end

  defp work_with_prompt!(suffix, prompt) do
    episode_id = Ecto.UUID.generate()

    {:ok, _transition} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: episode_id,
          episode_key: "lazy-artifact:#{suffix}:#{episode_id}",
          native_input_id: "source:#{suffix}:#{episode_id}",
          turn_ref: "turn:#{suffix}:#{episode_id}"
        })
      )

    {:ok, _session} = Custody.pin_episode(episode_id, "lazy", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("lazy:#{suffix}", 120, :work)

    {:ok, submission} =
      Submission.new(%{"context" => "none"}, prompt, %{"type" => "object"}, "work-final-v1")

    {:ok, turn} =
      Custody.freeze_submission(episode_id, claim.turn.turn_ref, claim.lease_ref, submission)

    %{episode: claim.episode, turn: turn}
  end
end
