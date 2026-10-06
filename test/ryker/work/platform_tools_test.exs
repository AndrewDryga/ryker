defmodule Ryker.Work.PlatformToolsTest do
  use ExUnit.Case, async: true
  alias Ryker.TestSupport.FakeWorkCoopAPI
  alias Ryker.Work.{Executor, PlatformTools, Runtime}

  # The Work runtime refused tool lists the executor and the briefing took, each checking the
  # list its own way (2026-10-04 review). They read it in one place now.
  test "the runtime and the executor refuse the same tool lists" do
    for tools <- [
          ["list runners"],
          ["list_runners", "list_runners"],
          [%{"name" => ""}],
          [42],
          List.duplicate("list_runners", 257)
        ] do
      assert PlatformTools.names(tools) == :error

      assert_raise ArgumentError, fn ->
        Runtime.options!(
          api: FakeWorkCoopAPI,
          client: self(),
          platform_tools: tools,
          worker_ref: "ryker-work:tools"
        )
      end

      assert Executor.check_options(api: FakeWorkCoopAPI, client: self(), platform_tools: tools) ==
               {:error, {:invalid_work_executor, :platform_tools}}
    end

    assert PlatformTools.names(["list_runners", %{"name" => "get_run"}]) ==
             {:ok, ["list_runners", "get_run"]}

    assert PlatformTools.names(nil) == {:ok, []}
  end
end
