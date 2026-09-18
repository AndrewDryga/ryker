defmodule Ryker.Publication.GitCommandTest do
  use ExUnit.Case, async: true

  alias Ryker.Publication.GitCommand

  test "runs Git in a bounded isolated directory" do
    directory = Path.join(System.tmp_dir!(), "ryker-git-command-#{Ecto.UUID.generate()}")
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

  test "passes the atom-keyed environment used by publication commits and GitHub auth" do
    directory = Path.join(System.tmp_dir!(), "ryker-git-command-env-#{Ecto.UUID.generate()}")
    File.mkdir!(directory)

    try do
      assert {:ok, "configured\n"} =
               GitCommand.run(
                 directory,
                 ["config", "--get", "ryker.publication"],
                 env: [
                   GIT_CONFIG_COUNT: "1",
                   GIT_CONFIG_KEY_0: "ryker.publication",
                   GIT_CONFIG_VALUE_0: "configured"
                 ]
               )
    after
      File.rm_rf(directory)
    end
  end
end
