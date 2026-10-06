defmodule Ryker.CoopFleet.ManagedSourcesStepsTest do
  use Ryker.DataCase, async: true
  import ExUnit.CaptureLog
  alias Ryker.CoopFleet.ManagedSources
  alias Ryker.Settings

  # A task on tenant gave up on 2026-10-03 after eight tries at a repository's code, and every
  # try said only :coop_worker_source_unavailable: whether the repository, its GitHub binding,
  # its token or the fetch was missing could not be told from anything Ryker kept.
  test "a source that cannot be prepared says which step failed" do
    {:ok, _snapshot} = Settings.initialize("control-plane:local")

    log =
      capture_log(fn ->
        assert {:error, :coop_worker_source_unavailable} =
                 ManagedSources.prepare(
                   Path.join(System.tmp_dir!(), "ryker-sources-steps"),
                   "repository-never-added",
                   nil
                 )
      end)

    assert log =~ "repository source for repository-never-added unavailable at repository"
  end
end
