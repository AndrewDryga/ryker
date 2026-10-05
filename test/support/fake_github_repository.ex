defmodule Ryker.TestSupport.FakeGitHubRepository do
  @moduledoc """
  One GitHub repository as the knowledge lane reads it
  (`Ryker.RepositoryKnowledge.Remote`): a default branch head, the tree and
  files at it, and what changed between commits. A file given as
  `:unreadable` is one Ryker cannot read. `errors` fails a call of that kind.
  It also pins, as setup does.

  Every call is recorded (`calls/0`), so a test can say what GitHub was never
  asked.
  """

  @behaviour Ryker.GitHub.Onboarding
  @behaviour Ryker.RepositoryKnowledge.Remote

  use Agent

  def start_link(options) do
    Agent.start_link(
      fn ->
        %{
          head: Keyword.fetch!(options, :head),
          tree: Keyword.fetch!(options, :tree),
          files: Keyword.get(options, :files, %{}),
          changes: %{},
          errors: Keyword.get(options, :errors, %{}),
          calls: []
        }
      end,
      name: __MODULE__
    )
  end

  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
  def update(fun), do: Agent.update(__MODULE__, fun)

  @doc "A push to the default branch: the new head, and the paths it changed since `base`."
  def push(base, head, paths) do
    update(fn state ->
      %{state | head: head, changes: Map.put(state.changes, {base, head}, paths)}
    end)
  end

  @impl Ryker.GitHub.Onboarding
  def pin(binding, repository), do: head(binding, repository)

  @impl Ryker.RepositoryKnowledge.Remote
  def head(_binding, _repository), do: call(:head, &{:ok, &1.head})

  @impl Ryker.RepositoryKnowledge.Remote
  def tree(_binding, _repository, commit) do
    call({:tree, commit}, fn state ->
      {:ok, Enum.map(state.tree, fn {path, type} -> %{"path" => path, "type" => type} end)}
    end)
  end

  @impl Ryker.RepositoryKnowledge.Remote
  def read(_binding, _repository, path, ref) do
    call({:read, path, ref}, &readable(Map.get(&1.files, path, :not_found)))
  end

  # A file given as `:unreadable` is one Ryker cannot read (too large, not
  # text, not a file), as `Ryker.GitHub.RepositoryFiles` reports it.
  defp readable(:unreadable), do: {:error, :source_unavailable}
  defp readable(file), do: {:ok, file}

  @impl Ryker.RepositoryKnowledge.Remote
  def changes(_binding, _repository, base, head) do
    call({:changes, base, head}, &{:ok, Map.get(&1.changes, {base, head}, [])})
  end

  defp call(name, answer) do
    Agent.get_and_update(__MODULE__, fn state ->
      state = record(state, name)

      case Map.fetch(state.errors, call_kind(name)) do
        {:ok, error} -> {error, state}
        :error -> {answer.(state), state}
      end
    end)
  end

  defp call_kind(name) when is_tuple(name), do: elem(name, 0)
  defp call_kind(name), do: name

  defp record(state, call), do: %{state | calls: [call | state.calls]}
end
