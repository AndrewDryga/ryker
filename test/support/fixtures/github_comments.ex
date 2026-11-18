defmodule Ryker.Fixtures.GitHubComments do
  @moduledoc false

  def find_issue_comment(agent, _repository, _number, marker) do
    Agent.get(agent, fn state ->
      if state.marker == marker, do: {:ok, 901}, else: :not_found
    end)
  end

  def create_issue_comment(agent, _repository, _number, body) do
    [marker] = Regex.run(~r/<!-- ryker-delivery:[a-f0-9]{64} -->/, body)

    Agent.get_and_update(agent, fn state ->
      response = if state.lose_response, do: {:error, :socket_closed}, else: {:ok, 901}

      {response,
       %{state | marker: marker, body: body, creates: state.creates + 1, lose_response: false}}
    end)
  end

  def update_issue_comment(agent, _repository, 901, body) do
    Agent.update(agent, &%{&1 | body: body, updates: &1.updates + 1})
  end

  def find_pull_review(agent, repository, number, marker),
    do: find_issue_comment(agent, repository, number, marker)

  def create_pull_review(agent, repository, number, body),
    do: create_issue_comment(agent, repository, number, body)

  def update_pull_review(agent, repository, _number, id, body),
    do: update_issue_comment(agent, repository, id, body)

  def find_review_reply(_, _, _, _, _), do: {:error, :unexpected_pull_request}
  def create_review_reply(_, _, _, _, _), do: {:error, :unexpected_pull_request}
  def update_review_comment(_, _, _, _), do: {:error, :unexpected_pull_request}
  def add_issue_comment_reaction(_, _, _, _), do: {:error, :unexpected_reaction}
  def add_review_comment_reaction(_, _, _, _), do: {:error, :unexpected_reaction}
end
