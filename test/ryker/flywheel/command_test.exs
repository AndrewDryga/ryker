defmodule Ryker.Flywheel.CommandTest do
  use Ryker.DataCase, async: false
  import ExUnit.CaptureIO
  alias Ryker.Flywheel

  test "the Mix command reads JSON and reports supported sources without starting workers" do
    path =
      Path.join(System.tmp_dir!(), "flywheel-request-#{System.unique_integer([:positive])}.json")

    File.write!(path, Jason.encode!(%{"action" => "catalog"}))
    on_exit(fn -> File.rm(path) end)
    output = capture_io(fn -> Mix.Tasks.Ryker.Flywheel.run([path]) end)
    assert {:ok, result} = Jason.decode(output)
    assert "feedback" in result["local"]
    assert "sentry" in result["external"]
  end

  test "invalid identifiers and malformed operator inputs are refused as values" do
    for request <- [
          nil,
          [],
          %{},
          %{"action" => "resume", "run_id" => "bad"},
          %{"action" => "start", "until" => "no date"},
          %{"action" => "heartbeat", "run_id" => "bad", "lease_ref" => "bad"}
        ] do
      assert {:error, _reason} = Flywheel.execute(request)
    end
  end

  test "the command fails on malformed JSON instead of issuing an operation" do
    assert_raise Mix.Error, ~r/flywheel failed/, fn ->
      capture_io("not-json", fn -> Mix.Tasks.Ryker.Flywheel.run(["-"]) end)
    end
  end
end
