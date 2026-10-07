defmodule Ryker.ControlPlane.PageRead do
  @moduledoc """
  One read of a console page (`Ryker.ControlPlane.WorkbenchLive`), with what
  its parts share read once: the configured secrets its artifacts redact
  (`Ryker.InspectionRedactor.with_configured_secrets/1`), the settings view,
  and the names of the people and repositories it shows (`memo/2`).

  Every part asked again: the shell, the page and its header each read the
  settings view, about 40 queries with every saved credential twice and a
  GitHub key decrypted into a signer; each list read every repository's name;
  and a page named each person with a query a row (2026-10-04 review).
  Nothing a page read shows changes these within the read.
  """
  alias Ryker.InspectionRedactor

  @scope {__MODULE__, :memos}

  @doc "Runs `fun` as one page read."
  @spec run((-> result)) :: result when result: term()
  def run(fun) do
    case Process.get(@scope) do
      nil ->
        # A page read's memo of what its parts share; it ends with the read.
        # credo:disable-for-next-line Ryker.Checks.NoProcessDictionary
        Process.put(@scope, %{})

        try do
          InspectionRedactor.with_configured_secrets(fun)
        after
          Process.delete(@scope)
        end

      _open ->
        fun.()
    end
  end

  @doc """
  What `read` returns, read once within a page read under `key`, and every
  time outside one.
  """
  @spec memo(term(), (-> value)) :: value when value: term()
  def memo(key, read) do
    with %{} = memos <- Process.get(@scope),
         {:ok, value} <- Map.fetch(memos, key) do
      value
    else
      nil ->
        read.()

      :error ->
        value = read.()
        # A read can memo others of its own, so the scope is read again.
        # credo:disable-for-next-line Ryker.Checks.NoProcessDictionary
        Process.put(@scope, Map.put(Process.get(@scope), key, value))
        value
    end
  end
end
