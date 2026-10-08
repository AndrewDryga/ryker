defmodule Ryker.ChildProcess do
  @moduledoc """
  An external program Ryker runs through a port, signalled by its exact
  process id and never by a name or a pattern. Its callers are long-lived
  processes (the transcription worker, the repository mirror), so a port they
  are done with leaves nothing in their mailbox.
  """

  @doc """
  Sends `signal` ("TERM", "KILL") to the program with process id `os_pid`;
  nothing for nil.
  """
  @spec signal(non_neg_integer() | nil, String.t()) :: :ok
  def signal(nil, _signal), do: :ok

  def signal(os_pid, signal) when is_integer(os_pid) do
    System.cmd("kill", ["-#{signal}", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end

  @doc "Closes `port`, whether or not its program already closed it, and drops what it sent."
  @spec close(port()) :: :ok
  def close(port) do
    try do
      Port.close(port)
    rescue
      # The program exited, which closed the port.
      ArgumentError -> :ok
    end

    flush(port)
  end

  @doc "Drops every message `port` left in the caller's mailbox."
  @spec flush(port()) :: :ok
  def flush(port) do
    receive do
      {^port, _message} -> flush(port)
      {:EXIT, ^port, _reason} -> flush(port)
    after
      0 -> :ok
    end
  end
end
