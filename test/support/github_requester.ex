defmodule Ryker.TestSupport.GitHubRequester do
  @moduledoc """
  GitHub's REST API as `Ryker.GitHub.Client` meets it, answered in order from
  a list of replies held by an Agent, so a request made from any process (a
  delivery dispatcher runs its publisher in a task) gets the next reply.
  Every request is kept, with its document, for the test to read.
  """

  def start(responses), do: Agent.start_link(fn -> %{requests: [], responses: responses} end)

  def request(agent, method, path, document, headers) do
    Agent.get_and_update(agent, fn state ->
      [response | remaining] = state.responses
      request = {method, path, document, headers}
      {response, %{state | requests: state.requests ++ [request], responses: remaining}}
    end)
  end

  def requests(agent), do: Agent.get(agent, & &1.requests)
end
