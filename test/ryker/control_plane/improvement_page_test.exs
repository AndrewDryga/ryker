defmodule Ryker.ControlPlane.ImprovementPageTest do
  @moduledoc """
  Andrew, 2026-09-27: "do something about it (at very least see where users
  were frustrated to see what happened and fix the issue). Ideally, we need
  evals building based on sentiment and self-analysis without much of
  manual human reviews." Memory › Feedback › What to fix lists the requests
  people were unhappy with, each with Ryker's own diagnosis, and a person
  only accepts or dismisses them.
  """
  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ryker.ControlPlane.{Actions, Pages, Projection, Router}
  alias Ryker.Feedback
  alias Ryker.Fixtures.Answers
  alias Ryker.Improvement
  alias Ryker.Improvement.Candidate

  @workspace "TIMPROVEPAGE"

  setup do
    # One day, whatever the clock says, so the day headings never split them.
    base = Date.utc_today() |> DateTime.new!(~T[08:00:00]) |> DateTime.to_unix()
    channel = "CIMPROVEPAGE#{System.unique_integer([:positive])}"

    staging =
      unhappy!(
        channel,
        base,
        "Is the staging database healthy?",
        "The production database is healthy.",
        diagnosis: [
          category: :prompt_bug,
          step: :work,
          confidence: :medium,
          what_went_wrong: "They asked about staging and Ryker answered about production.",
          expected: "Checks the staging database, not production, and says which checks it ran."
        ]
      )

    access =
      unhappy!(
        channel,
        base + 600,
        "Check health of our infra",
        "Can you give me Google Cloud access?",
        diagnosis: [
          category: :host_bug,
          step: :work,
          confidence: :high,
          what_went_wrong: "Ryker asked for access it had: no Emisar tool reached the Work turn.",
          expected:
            "Checks health through the connected Emisar runners without asking for access."
        ]
      )

    waiting = unhappy!(channel, base + 1_200, "Count to three", "1, 2, 4.", diagnosis: nil)

    %{staging: staging, access: access, waiting: waiting}
  end

  test "lists each request with its diagnosis, surest first within a day, each opening its Timeline",
       %{staging: staging, access: access, waiting: waiting} do
    page = Pages.page(["memory", "feedback", "fix"], %{}, options())

    assert {page.status, page.title, page.back} ==
             {200, "What to fix", {"All feedback", "/memory/feedback"}}

    # Nothing is accepted yet, so there is nothing to download.
    refute Map.has_key?(page, :action)

    document = LazyHTML.from_fragment(page.body)

    assert counts(document) == [
             {"3 to decide", nil},
             {"1 host bug", "/memory/feedback/fix?category=host_bug&status=open"},
             {"1 prompt bug", "/memory/feedback/fix?category=prompt_bug&status=open"}
           ]

    assert document |> LazyHTML.query(".segmented a") |> Enum.map(&text/1) ==
             ["To decide", "Accepted", "Dismissed"]

    # Newest day first; within the day the surest diagnosis first, and a
    # request Ryker has not analyzed yet last.
    assert ids(document) == [access.id, staging.id, waiting.id]

    row = row(document, access.id)
    assert text(LazyHTML.query(row, "h3 .state-word")) == "Host bug"

    assert LazyHTML.attribute(LazyHTML.query(row, "h3 .state-word"), "title") |> hd() =~
             "tool was missing"

    assert text(row) =~ "Ryker asked for access it had"
    assert text(row) =~ "Ryker should have"
    assert text(row) =~ "Checks health through the connected Emisar runners"
    assert text(row) =~ "In Work"
    assert text(row) =~ "High confidence"
    assert text(row) =~ "Frustrated, reacted with a thumbs down"

    assert row |> LazyHTML.query(".entity-name a") |> LazyHTML.attribute("href") ==
             ["/timeline/" <> URI.encode_www_form(access.request_ref)]

    assert actions(row) == ["Accept as eval case", "Dismiss"]

    assert text(LazyHTML.query(row(document, waiting.id), "h3 .state-word")) == "Waiting"
  end

  test "accepting and dismissing each ask first, and move the request between views",
       %{staging: staging, access: access, waiting: waiting} do
    question = confirmation("/actions/improvement/#{access.id}/accept")
    assert question.status == 200
    assert question.resp_body =~ "Accept this as an eval case?"
    assert question.resp_body =~ "download them as an eval case"

    assert {:ok, %{title: "Accept this as an eval case?", tone: :primary}} =
             Router.question("/actions/improvement/#{access.id}/accept", router())

    accepted = confirm("/actions/improvement/#{access.id}/accept")
    assert accepted.status == 303
    assert Plug.Conn.get_resp_header(accepted, "location") == ["/memory/feedback/fix"]
    assert confirm("/actions/improvement/#{staging.id}/dismiss").status == 303

    open = Pages.page(["memory", "feedback", "fix"], %{}, options())
    assert ids(LazyHTML.from_fragment(open.body)) == [waiting.id]

    # Accepted cases download from the button opposite the title.
    assert open.action =~ ~s(href="/memory/feedback/fix/eval-cases.zip")

    decided = Pages.page(["memory", "feedback", "fix"], %{"status" => "accepted"}, options())
    document = LazyHTML.from_fragment(decided.body)
    assert ids(document) == [access.id]
    assert actions(row(document, access.id)) == ["Dismiss"]

    dismissed = Pages.page(["memory", "feedback", "fix"], %{"status" => "dismissed"}, options())
    document = LazyHTML.from_fragment(dismissed.body)
    assert ids(document) == [staging.id]
    assert actions(row(document, staging.id)) == ["Accept as eval case"]

    # A decision already made has no confirmation to open again.
    assert confirmation("/actions/improvement/#{access.id}/accept").status == 404
    assert confirmation("/actions/improvement/#{Ecto.UUID.generate()}/dismiss").status == 404

    # The download holds the accepted case.
    download =
      Plug.Test.conn(:get, "/memory/feedback/fix/eval-cases.zip")
      |> Map.put(:host, "localhost")
      |> Router.call(router())

    assert download.status == 200
    assert Plug.Conn.get_resp_header(download, "content-type") |> hd() =~ "application/zip"
    assert {:ok, entries} = :zip.unzip(download.resp_body, [:memory])
    assert Enum.any?(entries, &String.ends_with?(to_string(elem(&1, 0)), "/scenario.json"))
  end

  test "a request whose words are gone says so, and offers only Dismiss", %{waiting: waiting} do
    Repo.update_all(from(c in Candidate, where: c.id == ^waiting.id),
      set: [analysis: :failed, error_code: "improvement_evidence_unavailable"]
    )

    document =
      Pages.page(["memory", "feedback", "fix"], %{}, options())
      |> Map.fetch!(:body)
      |> LazyHTML.from_fragment()

    row = row(document, waiting.id)
    assert text(LazyHTML.query(row, "h3 .state-word")) == "Not analyzed"

    assert row |> LazyHTML.query("h3 .state-word") |> LazyHTML.attribute("title") ==
             [
               "The person's messages were deleted or have expired, so there was nothing to analyze."
             ]

    assert actions(row) == ["Dismiss"]
    assert confirmation("/actions/improvement/#{waiting.id}/accept").status == 404
  end

  test "the Feedback page says how many are to decide, accepted and dismissed, and what went wrong",
       %{access: access} do
    assert {:ok, _accepted} = Improvement.accept(access.id, "control-plane:local")

    document =
      Pages.page(["memory", "feedback"], %{}, options())
      |> Map.fetch!(:body)
      |> LazyHTML.from_fragment()

    fix = LazyHTML.query(document, "section[aria-labelledby=feedback-fix]")
    assert text(LazyHTML.query(fix, ".section-head h2")) == "What to fix"

    assert fix |> LazyHTML.query(".kit-count") |> Enum.map(&{text(&1), href(&1)}) == [
             {"2 to decide", "/memory/feedback/fix"},
             {"1 accepted", "/memory/feedback/fix?status=accepted"},
             {"1 prompt bug", "/memory/feedback/fix?category=prompt_bug&status=open"}
           ]
  end

  # One request with its Work reply, a thumbs down and an angry reply, and,
  # unless `diagnosis` is nil, the diagnosis Ryker's analysis gave it.
  defp unhappy!(channel, at, question, answer, diagnosis: diagnosis) do
    message =
      Answers.slack_message!(
        workspace: @workspace,
        channel: channel,
        text: question,
        ts: "#{at}.000100"
      )

    reply = Answers.work_reply!(message, answer, "#{at + 60}.000100", time(at + 60))
    request = {:episode, reply.episode.id}

    for {kind, value, event} <- [{:reaction_added, "-1", "down"}, {:sentiment, "angry", "angry"}] do
      assert {:ok, _recorded} =
               Feedback.record(%{
                 kind: kind,
                 value: value,
                 actor_ref: "UALICE",
                 source: "slack",
                 source_ref: "slack-event:#{event}-#{at}",
                 occurred_at: time(at + 120),
                 request: request
               })
    end

    candidate = Improvement.for_request(request)

    if diagnosis do
      Repo.update_all(from(c in Candidate, where: c.id == ^candidate.id),
        set: Keyword.merge(diagnosis, analysis: :done, analyzed_at: DateTime.utc_now())
      )
    end

    Repo.get!(Candidate, candidate.id)
  end

  defp time(unix), do: DateTime.from_unix!(unix * 1_000_000, :microsecond)

  defp options, do: %{projection: Projection.callbacks()}

  defp counts(document),
    do: Enum.map(LazyHTML.query(document, ".kit-count"), &{text(&1), href(&1)})

  defp ids(document) do
    document
    |> LazyHTML.query(".entity-row")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "improvement-", ""))
  end

  defp row(document, id), do: LazyHTML.query(document, "#improvement-#{id}")

  defp actions(row) do
    row
    |> LazyHTML.query(".entity-actions form[method=get] button")
    |> Enum.map(&text/1)
  end

  defp confirmation(path) do
    Plug.Test.conn(:get, path)
    |> Map.put(:host, "localhost")
    |> Router.call(router())
  end

  defp confirm(path) do
    page = confirmation(path)
    assert page.status == 200, page.resp_body
    [_, token] = Regex.run(~r/name="_token" value="([^"]+)"/, page.resp_body)

    Plug.Test.conn(:post, path, URI.encode_query(%{"_token" => token}))
    |> Map.put(:host, "localhost")
    |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
    |> Router.call(router())
  end

  defp router do
    Router.init(%{
      csrf_secret: String.duplicate("s", 32),
      actions: Actions.callbacks(),
      observability: %{},
      projection: Projection.callbacks()
    })
  end

  defp href(node), do: node |> LazyHTML.attribute("href") |> List.first()

  defp text(node), do: node |> LazyHTML.text() |> String.split() |> Enum.join(" ")
end
