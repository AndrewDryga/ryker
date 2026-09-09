defmodule Responder.ControlPlane.CardLabTest do
  use ExUnit.Case, async: true

  alias Responder.ControlPlane.{CardLab, HTML}
  alias Responder.Emisar.RunState
  alias Responder.Slack.{Renderer, ThreadStatusProjection}
  alias Responder.State.RecordPayload

  test "waiting status specimens match the quiet production projection" do
    # The catalog must not promise a persistent activity indicator after Work
    # has yielded durable custody to a human or source-event wait.
    for phase <- [:waiting_for_input, :waiting_for_event] do
      episode = %Responder.Episodes.Episode{
        id: "preview",
        state: phase,
        execution_mode: :live,
        destination_transport: "slack",
        destination_conversation_ref: "slack:T123:C456",
        destination_thread_ref: "1787832000.000100"
      }

      [projected] = ThreadStatusProjection.targets([], [episode], "T123")
      state_id = phase |> Atom.to_string() |> String.replace("_", "-")
      assert {:ok, specimen} = CardLab.fetch("thread-status", state_id)
      assert specimen.rendered["status"] == projected.status
    end
  end

  test "working task examples expose retained legacy progress and identify simulated states" do
    # The default working task used invented parser prose, hiding the richness
    # and actual length of requests operators had already worked with.
    assert {:ok, working} = CardLab.fetch("task-card", "working")
    assert working.rendered["text"] =~ "Bump the pinned admin runner release to 0.20.0"
    assert Jason.encode!(working.rendered) =~ "Still working; implementing and validating"
    assert working.state.provenance.basis == "Retained progress"
    assert working.state.provenance.source_ref == "episode_run_9f179b957987eb77f5b860877b06c344"
    assert Jason.encode!(working.rendered) =~ "Updated 14 Aug, 05:43 UTC"

    assert {:ok, later} = CardLab.fetch("task-card", "working-validation")
    assert later.state.provenance.observed_at == "2026-08-14T05:51:23.132457Z"
    assert {:ok, goals} = CardLab.fetch("task-card", "recorded-goals")
    assert Jason.encode!(goals.rendered) =~ "3 of 3 completed"
    assert goals.state.provenance.basis == "Real goals · layout study"

    assert {:ok, waiting} = CardLab.fetch("task-card", "waiting-for-input")
    assert waiting.state.provenance.basis == "State simulation"
  end

  test "confirmation dialogs never become inline card rows and remain in native Slack payloads" do
    # The inline confirmation disclosure split the Stop/View diff/Close button
    # row and gave operators a preview that Slack itself would never render.
    {:ok, snapshot} = CardLab.fetch("task-card", "working")

    buttons =
      snapshot.rendered["blocks"]
      |> Enum.filter(&(&1["type"] == "actions"))
      |> Enum.flat_map(& &1["elements"])

    assert stop = Enum.find(buttons, &(get_in(&1, ["text", "text"]) == "Stop current run"))
    assert is_map(stop["confirm"])

    html = snapshot.rendered |> HTML.card_lab_preview(:message) |> IO.iodata_to_binary()
    refute html =~ "slack-confirm"
    refute html =~ "<summary>Confirmation</summary>"
    assert html =~ "aria-label=\"More actions\""
    refute html =~ "More · Timeline"

    assert html
           |> LazyHTML.from_document()
           |> LazyHTML.query(".slack-actions > *")
           |> LazyHTML.attribute("class") ==
             ["slack-button danger", "slack-button", "slack-button danger", "slack-overflow"]

    {:ok, payload} = CardLab.slack_message("task-card", "working")

    native_stop =
      payload["blocks"]
      |> Enum.filter(&(&1["type"] == "actions"))
      |> Enum.flat_map(& &1["elements"])
      |> Enum.find(&(get_in(&1, ["text", "text"]) == "Stop current run"))

    assert native_stop["confirm"] == stop["confirm"]
    assert native_stop["action_id"] =~ "card_lab_preview_"

    for card <- CardLab.catalog(), state <- card.states do
      preview = state.rendered |> HTML.card_lab_preview(card.surface) |> IO.iodata_to_binary()
      refute preview =~ "slack-confirm", "#{card.id}/#{state.id} renders a dialog inline"
    end
  end

  test "real Slack specimens retain production blocks with isolated test controls" do
    Enum.each(CardLab.catalog(), fn card ->
      Enum.each(card.states, fn state ->
        if card.surface == :message do
          assert {:ok, message} = CardLab.slack_message(card.id, state.id)
          assert message["text"] =~ "Card Lab"
          assert length(message["blocks"]) <= 50
          assert hd(message["blocks"])["type"] == "context"
          assert length(message["blocks"]) == length(state.rendered["blocks"]) + 1
          json = Jason.encode!(message)
          refute json =~ ~s("action_id":"responder_)
          refute json =~ "<!channel>"
          refute json =~ "<!here>"
        else
          assert CardLab.slack_message(card.id, state.id) ==
                   {:error, :card_lab_requires_native_surface}
        end
      end)
    end)
  end

  test "the catalog renders every declared Slack specimen through its production boundary" do
    catalog = CardLab.catalog()

    assert length(catalog) >= 16
    assert Enum.uniq(Enum.map(catalog, & &1.id)) == Enum.map(catalog, & &1.id)

    specimens = Enum.flat_map(catalog, & &1.states)
    assert length(specimens) >= 120

    Enum.each(catalog, fn card ->
      assert card.states != [], card.id
      assert Enum.uniq(Enum.map(card.states, & &1.id)) == Enum.map(card.states, & &1.id)

      Enum.each(card.states, fn state ->
        assert {:ok, snapshot} = CardLab.fetch(card.id, state.id)
        assert snapshot.rendered == state.rendered
        assert snapshot.rendered["type"] in ["home", "modal", "thread_status", nil]

        assert is_list(snapshot.rendered["blocks"]) or
                 snapshot.rendered["type"] == "thread_status"
      end)
    end)
  end

  test "the catalog is exhaustive for renderer state contracts" do
    coverage = CardLab.coverage()
    contract = Renderer.presentation_contract()

    assert coverage.task_statuses ==
             ~w(working waiting_for_input waiting_for_event action_required stopping reviewing ready_for_review ready_to_publish published completed cancelled)

    assert coverage.incident_statuses ==
             ~w(provisioning investigating action_required waiting_for_input waiting_for_event stopping resolved cancelled paused)

    assert coverage.setup_states ==
             ~w(welcome participation repository alerts audience confirming saved cancelled expired)

    assert coverage.emisar_statuses == RunState.statuses()
    assert MapSet.subset?(MapSet.new(RecordPayload.kinds()), MapSet.new(coverage.record_kinds))
    assert "publication_review" in coverage.record_kinds
    assert "publication_result" in coverage.record_kinds
    assert MapSet.new(coverage.record_states) == MapSet.new(contract.record_states)
    assert coverage.task_statuses == contract.task_statuses
    assert coverage.incident_statuses == contract.incident_statuses
    assert coverage.setup_statuses == contract.setup_statuses
    assert coverage.setup_steps == contract.setup_steps
    assert coverage.thread_phases == ThreadStatusProjection.phases()

    assert coverage.surfaces ==
             MapSet.new([:message, :app_home, :modal, :thread_status])
  end

  test "every transition resolves to an existing state and rejects invented transitions" do
    Enum.each(CardLab.catalog(), fn card ->
      state_ids = MapSet.new(Enum.map(card.states, & &1.id))

      Enum.each(card.states, fn state ->
        Enum.each(state.transitions, fn transition ->
          assert MapSet.member?(state_ids, transition.to),
                 "#{card.id}/#{state.id} points to missing #{transition.to}"

          assert {:ok, target} = CardLab.transition(card.id, state.id, transition.id)
          assert target.card.id == card.id
          assert target.state.id == transition.to
        end)
      end)
    end)

    assert CardLab.transition("task-card", "working", "invented") ==
             {:error, :card_lab_transition_not_found}

    assert CardLab.fetch("missing", "missing") == {:error, :card_lab_specimen_not_found}
  end
end
