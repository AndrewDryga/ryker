defmodule Ryker.Work.FailureCauseTest do
  # The Failures page and a task's stages each took the cause out of an
  # explanation by hand until 2026-10-08.
  use ExUnit.Case, async: true
  alias Ryker.Work.FailureCause

  test "a failure's cause is in words, or nil when Ryker can name none" do
    assert FailureCause.cause("coop_worker_command_timeout: placement 7") ==
             "The worker did not take or finish one of this task's commands in time."

    assert FailureCause.cause("something nobody has seen") == nil
    assert FailureCause.cause(nil) == nil
  end
end
