defmodule Responder.ControlPlane.CardLabTest do
  use ExUnit.Case, async: true

  alias Responder.ControlPlane.CardLab
  alias Responder.Emisar.RunState
  alias Responder.Slack.{Renderer, ThreadStatusProjection}
  alias Responder.State.RecordPayload

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
