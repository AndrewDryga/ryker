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

  describe "Ryker.Checks.TestContextPattern" do
    test "flags a test binding its context as a bare variable" do
      source = """
      defmodule Ryker.SprocketsTest do
        use Ryker.DataCase, async: true

        test "reads a sprocket", ctx do
          assert ctx.workspace
        end
      end
      """

      assert [issue] = issues(context_pattern(), source, @test_file)
      assert issue.check == context_pattern()
      assert issue.trigger == "ctx"
      assert issue.line_no == 4
      assert issue.message =~ "explicit `%{...}` pattern"
    end

    test "allows no context, a map pattern, a bound map pattern, and an ignored one" do
      source = """
      defmodule Ryker.SprocketsTest do
        use Ryker.DataCase, async: true

        test "needs nothing" do
          assert true
        end

        test "reads a sprocket", %{workspace: workspace} do
          assert workspace
        end

        test "reads it again", %{workspace: workspace} = context do
          assert workspace == context.workspace
        end

        test "ignores the context", _context do
          assert true
        end
      end
      """

      assert issues(context_pattern(), source, @test_file) == []
    end

    test "ignores lib sources" do
      source = """
      defmodule Ryker.Sprockets do
        def test(name, ctx), do: {name, ctx}
      end
      """

      assert issues(context_pattern(), source, "lib/ryker/sprockets.ex") == []
    end
  end

  describe "Ryker.Checks.NoApplicationPutEnv" do
    test "flags Application.put_env" do
      source = """
      defmodule Ryker.Sprockets do
        def enable, do: Application.put_env(:ryker, :feature, true)
      end
      """

      assert [issue] = issues(put_env(), source, "lib/ryker/sprockets.ex")
      assert issue.check == put_env()
      assert issue.trigger == "Application.put_env"
      assert issue.line_no == 2
      assert issue.message =~ "Ryker.Config.put_override/3"
    end

    test "flags delete_env and put_all_env, in lib and in test" do
      source = """
      defmodule Ryker.Sprockets do
        def disable, do: Application.delete_env(:ryker, :feature)
        def load(all), do: Application.put_all_env(all)
      end
      """

      expected = ["Application.delete_env", "Application.put_all_env"]
      assert triggers(put_env(), source, "lib/ryker/sprockets.ex") == expected
      assert triggers(put_env(), source, @test_file) == expected
    end

    test "allows reading app env, and ignores config files" do
      reading = """
      defmodule Ryker.Sprockets do
        def endpoint, do: Application.get_env(:ryker, :endpoint)
      end
      """

      config = """
      import Config
      config :ryker, :feature, true
      Application.put_env(:ryker, :feature, true)
      """

      assert issues(put_env(), reading, "lib/ryker/sprockets.ex") == []
      assert issues(put_env(), config, "config/runtime.exs") == []
    end
  end

  defp context_pattern, do: check("TestContextPattern")
  defp put_env, do: check("NoApplicationPutEnv")
  defp sleep, do: check("TestNoProcessSleep")
end
