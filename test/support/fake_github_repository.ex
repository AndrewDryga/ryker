defmodule Ryker.TestSupport.FakeGitHubRepository do
  @moduledoc """
  One GitHub repository as the knowledge lane sees it
  (`Ryker.RepositoryKnowledge.Remote`): a default branch head, the tree and
  files at it, what changed between commits, RYKER.md on the default branch,
  and Ryker's knowledge pull requests. It behaves like
  `Ryker.GitHub.RepositoryFiles` does against GitHub: an open proposal is
  updated, a document the default branch already says opens nothing, an
  archived repository refuses the write. It also pins, as setup does.

  Every call is recorded (`calls/0`), so a test can say what GitHub was never
  asked.
  """

  @behaviour Ryker.GitHub.Onboarding
  @behaviour Ryker.RepositoryKnowledge.Remote

  use Agent

  alias Ryker.RepositoryKnowledge.Document

  def start_link(options) do
    Agent.start_link(
      fn ->
        %{
          archived: Keyword.get(options, :archived, false),
          head: Keyword.fetch!(options, :head),
          tree: Keyword.fetch!(options, :tree),
          files: Keyword.get(options, :files, %{}),
          document: Keyword.get(options, :document),
          changes: %{},
          pull_requests: %{},
          open: nil,
          next_number: Keyword.get(options, :next_number, 84),
          errors: Keyword.get(options, :errors, %{}),
          # Runs in the caller's process as a proposal is made, as a person
          # removing the repository at that moment would.
          on_publish: Keyword.get(options, :on_publish),
          calls: []
        }
      end,
      name: __MODULE__
    )
  end

  def state, do: Agent.get(__MODULE__, & &1)
  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
  def update(fun), do: Agent.update(__MODULE__, fun)

  @doc "A push to the default branch: the new head, and the paths it changed since `base`."
  def push(base, head, paths) do
    update(fn state ->
      %{state | head: head, changes: Map.put(state.changes, {base, head}, paths)}
    end)
  end

  @doc "Someone merges Ryker's open pull request: its RYKER.md reaches the default branch."
  def merge_open(head) do
    update(fn %{open: %{number: number, document: document}} = state ->
      %{
        state
        | head: head,
          document: document,
          open: nil,
          pull_requests: Map.put(state.pull_requests, number, :merged)
      }
    end)
  end

  @impl Ryker.GitHub.Onboarding
  def pin(binding, repository), do: head(binding, repository)

  @impl Ryker.RepositoryKnowledge.Remote
  def repository(_binding, repository) do
    call({:repository, repository.github_repository}, fn state ->
      {:ok, %{archived: state.archived}}
    end)
  end

  @impl Ryker.RepositoryKnowledge.Remote
  def head(_binding, _repository), do: call(:head, &{:ok, &1.head})

  @impl Ryker.RepositoryKnowledge.Remote
  def tree(_binding, _repository, commit) do
    call({:tree, commit}, fn state ->
      {:ok, Enum.map(state.tree, fn {path, type} -> %{"path" => path, "type" => type} end)}
    end)
  end

  @impl Ryker.RepositoryKnowledge.Remote
  def read(_binding, _repository, "RYKER.md", ref) do
    call({:read, "RYKER.md", ref}, &{:ok, &1.document || :not_found})
  end

  def read(_binding, _repository, path, ref) do
    call({:read, path, ref}, &{:ok, Map.get(&1.files, path, :not_found)})
  end

  @impl Ryker.RepositoryKnowledge.Remote
  def changes(_binding, _repository, base, head) do
    call({:changes, base, head}, &{:ok, Map.get(&1.changes, {base, head}, [])})
  end

  @impl Ryker.RepositoryKnowledge.Remote
  def pull_request(_binding, _repository, number) do
    call({:pull_request, number}, &{:ok, Map.get(&1.pull_requests, number, :closed)})
  end

  @impl Ryker.RepositoryKnowledge.Remote
  def publish(_binding, repository, %{document: document, body: body}) do
    case state().on_publish do
      nil -> :ok
      during -> during.()
    end

    Agent.get_and_update(__MODULE__, fn state ->
      state = record(state, {:publish, document})

      cond do
        Map.has_key?(state.errors, :publish) ->
          {state.errors.publish, state}

        state.archived ->
          {{:error, {:github_onboarding, :archived}}, state}

        state.open ->
          open = %{state.open | document: document, body: body}

          {{:ok, result(state, :updated, open)}, %{state | open: open}}

        Document.same?(state.document, document) ->
          {{:ok, %{result(state, :unchanged, nil) | url: nil, number: nil}}, state}

        true ->
          number = state.next_number

          open = %{
            number: number,
            url: "https://github.com/#{repository.github_repository}/pull/#{number}",
            document: document,
            body: body,
            title: if(state.document, do: "Update", else: "Add") <> " Ryker repository knowledge"
          }

          {{:ok, result(state, :opened, open)},
           %{
             state
             | open: open,
               next_number: number + 1,
               pull_requests: Map.put(state.pull_requests, number, :open)
           }}
      end
    end)
  end

  defp result(state, outcome, open) do
    %{
      outcome: outcome,
      url: open && open.url,
      number: open && open.number,
      base_commit: state.head,
      base_document: state.document
    }
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
