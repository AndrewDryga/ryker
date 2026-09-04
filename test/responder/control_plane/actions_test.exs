defmodule Responder.ControlPlane.ActionsTest do
  use Responder.DataCase, async: true

  alias Responder.ControlPlane.Actions

  test "local retention callbacks fail closed while preserving audited action identity" do
    callbacks = Actions.callbacks()

    assert callbacks.send_lab_message.(Ecto.UUID.generate(), "hello", []) ==
             {:error, :conversation_lab_not_configured}

    assert callbacks.rearm_retention.("missing-session") ==
             {:error, :operator_failure_not_found}

    assert callbacks.discard_retention.("missing-session") ==
             {:error, :retention_session_not_found}
  end
end
