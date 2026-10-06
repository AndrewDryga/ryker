defmodule Ryker.CredoChecks.TestHygieneChecksTest do
  # Fixture coverage for the ban on `Process.sleep` as synchronization in the
  # suite: a probe it must flag and compliant probes it must not.
  use ExUnit.Case, async: true
  import Ryker.CredoCheckProbe

  @test_file "test/ryker/sprockets_test.exs"

  setup_all do
    load()
  end

  describe "Ryker.Checks.TestNoProcessSleep" do
    test "flags Process.sleep and :timer.sleep in a test" do
      source = """
      defmodule Ryker.SprocketsTest do
        use Ryker.DataCase, async: true

        test "waits for the worker" do
          Process.sleep(50)
          :timer.sleep(50)
        end
      end
      """

      assert triggers(sleep(), source, @test_file) == [":timer.sleep", "Process.sleep"]
      assert [issue | _] = issues(sleep(), source, @test_file)
      assert issue.check == sleep()
      assert issue.message =~ "assert_receive"
    end

    test "allows assert_receive with an explicit timeout" do
      source = """
      defmodule Ryker.SprocketsTest do
        use Ryker.DataCase, async: true

        test "waits for the worker" do
          assert_receive {:sprocket_created, _sprocket}, 500
        end
      end
      """

      assert issues(sleep(), source, @test_file) == []
    end

    test "ignores lib sources, where a sleep is not test synchronization" do
      source = """
      defmodule Ryker.Sprockets do
        def backoff(attempt), do: Process.sleep(attempt * 100)
      end
      """

      assert issues(sleep(), source, "lib/ryker/sprockets.ex") == []
    end
  end

  defp sleep, do: check("TestNoProcessSleep")
end
