defmodule Responder.ControlPlane.ModelRequestsTest do
  use Responder.DataCase, async: true
  import Phoenix.LiveViewTest
  alias Responder.ControlPlane.{ModelRequests, ModelRequestsHTML, RequestPage}
  alias Responder.Work.{Custody, Submission, Turn}

  test "inspection reads the frozen request and distinguishes instructions from provider-owned context" do
    {episode, turn, original} = frozen_turn!()
    assert {:ok, view} = ModelRequests.project(episode.key, %{})
    assert view.selected.id == turn.id
    instructions = Enum.find(view.selected.sections, &(&1.id == "instructions"))

    assert instructions.artifact.text ==
             "Host-authored retained instructions for this submission."

    raw = Enum.find(view.selected.sections, &(&1.id == "request"))
    assert raw.artifact.sha256 == :crypto.hash(:sha256, original) |> Base.encode16(case: :lower)
    assert view.selected.coverage =~ "Coop wrapper"
    html = view |> ModelRequestsHTML.render() |> IO.iodata_to_binary()
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>"
    refute html =~ "xoxb-recorded-credential"
    assert html =~ "source message"
    assert html =~ "Not recorded"

    for section <- view.selected.sections do
      native =
        render_component(&RequestPage.render/1,
          view: view,
          params: %{"section" => section.id},
          path: "/episodes/#{URI.encode_www_form(episode.key)}/requests"
        )

      assert native =~ section.title
      assert native =~ "attempt=#{turn.id}"
      refute native =~ "<script>"
      refute native =~ "xoxb-recorded-credential"
    end
  end

  test "a request cannot be inspected through another episode" do
    {episode, _turn, _prompt} = frozen_turn!()
    assert :not_found == ModelRequests.project(episode.key, %{"attempt" => Ecto.UUID.generate()})
    assert :not_found == ModelRequests.project(episode.key, %{"attempt" => "not-a-uuid"})
  end

  test "pruned request content is expired rather than silently reconstructed" do
    {episode, turn, _prompt} = frozen_turn!()
    import Ecto.Query

    Repo.update_all(from(t in Turn, where: t.id == ^turn.id),
      set: [submission: %{"retention" => "pruned"}, operational_pruned_at: DateTime.utc_now()]
    )

    assert {:ok, view} = ModelRequests.project(episode.key, %{})
    assert Enum.find(view.selected.sections, &(&1.id == "request")).artifact.state == :expired

    native =
      render_component(&RequestPage.render/1,
        view: view,
        params: %{"section" => "request"},
        path: "/episodes/retained/requests"
      )

    assert native =~ "This artifact has expired"
    refute native =~ "Host-authored retained instructions"
  end

  defp frozen_turn! do
    id = Ecto.UUID.generate()

    {:ok, %{episode: episode}} =
      Responder.Episodes.apply(
        Responder.Fixtures.Episodes.admit_input(%{
          episode_id: id,
          episode_key: "inspection:#{id}",
          native_input_id: "input:#{id}",
          turn_ref: "turn:#{id}"
        })
      )

    {:ok, _session} =
      Custody.pin_episode(episode.id, "policy:inspection", String.duplicate("a", 64))

    {:ok, claim} = Custody.claim_next("inspection:test", 60, :work)

    context = %{
      "inputs" => [%{"text" => "source message <script>alert('x')</script>"}],
      "responder_state_tools" => ["validate_final"],
      "api_token" => "xoxb-recorded-credential"
    }

    original =
      Jason.encode!(%{
        "instructions" => "Host-authored retained instructions for this submission.",
        "work" => context
      })

    {:ok, submission} =
      Submission.new(context, original, %{"type" => "object"}, "inspection-test")

    {:ok, turn} =
      Custody.freeze_submission(episode.id, claim.turn.turn_ref, claim.lease_ref, submission)

    {episode, turn, original}
  end
end
