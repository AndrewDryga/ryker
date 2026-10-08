defmodule Ryker.ChildProcessTest do
  # The repository mirror and the transcription worker each stopped their
  # programs with their own copy of these until 2026-10-08.
  use ExUnit.Case, async: true
  alias Ryker.ChildProcess

  test "a closed port leaves nothing in the caller's mailbox, closed already or not" do
    port =
      Port.open({:spawn_executable, System.find_executable("echo")}, [
        :binary,
        :exit_status,
        args: ["hello"]
      ])

    assert_receive {^port, {:exit_status, 0}}
    send(self(), {port, :late})

    assert ChildProcess.close(port) == :ok
    refute_received {^port, _message}
  end

  test "a signal reaches the program by its exact process id" do
    port =
      Port.open({:spawn_executable, System.find_executable("sleep")}, [:exit_status, args: ["30"]])

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    assert ChildProcess.signal(os_pid, "KILL") == :ok
    assert_receive {^port, {:exit_status, status}} when status != 0, 5_000
    assert ChildProcess.close(port) == :ok
  end

  test "a program with no process id is sent nothing" do
    assert ChildProcess.signal(nil, "KILL") == :ok
  end
end
