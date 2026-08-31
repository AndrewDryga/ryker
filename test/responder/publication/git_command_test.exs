defmodule Responder.Publication.GitCommandTest do
  use ExUnit.Case, async: true

  alias Responder.Publication.GitCommand

  test "runs Git in a bounded isolated directory" do
    directory = Path.join(System.tmp_dir!(), "responder-git-command-#{Ecto.UUID.generate()}")
    File.mkdir!(directory)

    try do
      assert {:ok, ""} = GitCommand.run(directory, ["init", "--quiet"])

      assert {:ok, output} =
               GitCommand.run(directory, ["rev-parse", "--is-inside-work-tree"])

      assert String.trim(output) == "true"

      assert GitCommand.run(directory, []) ==
               {:error, {:invalid_publication_git_command, :arguments}}

      assert {:error, {:publication_git_command_failed, status, output}} =
               GitCommand.run(directory, ["rev-parse", "--verify", "missing-ref"])

      assert status > 0
      assert output =~ "fatal"

      assert GitCommand.run(
               directory,
               ["-c", "alias.pause=!sleep 1", "pause"],
               timeout_ms: 10
             ) == {:error, {:publication_git_command_failed, :timeout}}

      assert GitCommand.run(directory, ["status"], env: [{:TOKEN, <<0>>}]) ==
               {:error, {:invalid_publication_git_command, :arguments}}

      assert GitCommand.run("relative/path", ["status"]) ==
               {:error, {:invalid_publication_git_command, :arguments}}
    after
      File.rm_rf(directory)
    end
  end
end
