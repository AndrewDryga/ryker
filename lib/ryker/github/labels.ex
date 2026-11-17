defmodule Ryker.GitHub.Labels do
  @moduledoc "The two standard PR labels: a person's review request and Ryker's current activity."
  alias Ryker.GitHub.{CommentActivity, PullRequestActivity}
  alias Ryker.Repo

  def active_pulls(name, binding) do
    threads =
      Repo.all(CommentActivity.Query.pending_threads(name, binding.repository_id)) ++
        Repo.all(CommentActivity.Query.active_threads(name, binding.repository_id))

    requested = Enum.flat_map(threads, &pull_number(&1, name))
    owned = Repo.all(PullRequestActivity.Query.active_publications(binding.repository_full_name))
    MapSet.new(requested ++ owned)
  end

  defp pull_number(thread, name) do
    case String.split(thread || "", ":") do
      ["github", ^name, "pull", number | _rest] ->
        case Integer.parse(number) do
          {number, ""} when number > 0 -> [number]
          _invalid -> []
        end

      _other ->
        []
    end
  end

  def definitions do
    [
      %{
        name: "ryker:review",
        color: "D4E8DF",
        description:
          "Ask Ryker to review this PR. Removed after acceptance; add again for another review."
      },
      %{
        name: "ryker:working",
        color: "36E6A5",
        description:
          "Ryker is handling work on this PR. Managed automatically; adding it does not start work."
      }
    ]
  end

  def review_request?("pull_request", %{
        "action" => "labeled",
        "label" => %{"name" => "ryker:review"},
        "pull_request" => %{"state" => "open"},
        "sender" => %{"type" => "User"}
      }),
      do: true

  def review_request?(_event, _payload), do: false
end
