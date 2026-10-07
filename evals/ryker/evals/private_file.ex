defmodule Ryker.Evals.PrivateFile do
  @moduledoc """
  Writes an evaluation report for its owner alone.

  A report holds the prompts the model was sent and what it answered, so it is
  owner-only before a byte of it is written, and it takes its name only once it
  is whole. Replay reports were written world-readable (2026-10-04 review).
  """

  @spec write(Path.t(), iodata()) :: :ok | {:error, File.posix()}
  def write(path, bytes) do
    temporary = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.touch(temporary),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.write(temporary, bytes, [:binary]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, _reason} = error ->
        File.rm(temporary)
        error
    end
  end
end
