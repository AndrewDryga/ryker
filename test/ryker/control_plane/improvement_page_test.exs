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
    page = Pages.page(["feedback", "fix"], %{}, options())

    assert {page.status, page.title, page.back} ==
             {200, "What to fix", {"All feedback", "/feedback"}}

    # Nothing is accepted yet, so there is nothing to download.
    refute Map.has_key?(page, :action)

    document = LazyHTML.from_fragment(page.body)

    assert counts(document) == [
             {"3 to decide", nil},
             {"1 host bug", "/feedback/fix?category=host_bug&status=open"},
             {"1 prompt bug", "/feedback/fix?category=prompt_bug&status=open"}
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
             ["/timeline/" <> access.episode_id]

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
    assert Plug.Conn.get_resp_header(accepted, "location") == ["/feedback/fix"]
    assert confirm("/actions/improvement/#{staging.id}/dismiss").status == 303

    open = Pages.page(["feedback", "fix"], %{}, options())
    assert ids(LazyHTML.from_fragment(open.body)) == [waiting.id]

    # Accepted cases download from the button opposite the title.
    assert open.action =~ ~s(href="/feedback/fix/eval-cases.zip")

    decided = Pages.page(["feedback", "fix"], %{"status" => "accepted"}, options())
    document = LazyHTML.from_fragment(decided.body)
    assert ids(document) == [access.id]
    assert actions(row(document, access.id)) == ["Dismiss"]

    dismissed = Pages.page(["feedback", "fix"], %{"status" => "dismissed"}, options())
    document = LazyHTML.from_fragment(dismissed.body)
    assert ids(document) == [staging.id]
    assert actions(row(document, staging.id)) == ["Accept as eval case"]

    # A decision already made has no confirmation to open again.
    assert confirmation("/actions/improvement/#{access.id}/accept").status == 404
    assert confirmation("/actions/improvement/#{Ecto.UUID.generate()}/dismiss").status == 404

    # The download holds the accepted case.
    download =
      Plug.Test.conn(:get, "/feedback/fix/eval-cases.zip")
      |> Map.put(:host, "localhost")
      |> Router.call(router())

    assert download.status == 200
    assert Plug.Conn.get_resp_header(download, "content-type") |> hd() =~ "application/zip"
    assert {:ok, entries} = :zip.unzip(download.resp_body, [:memory])
    assert Enum.any?(entries, &String.ends_with?(to_string(elem(&1, 0)), "/scenario.json"))
  end

  # Every request Ryker could not analyze once read "The person's messages
  # were deleted or have expired", including GitHub requests whose comments
  # it simply did not read, and requests an alert started with no person in
  # them. Each says what is really missing.
  test "a request Ryker could not analyze says why, and offers only Dismiss", %{waiting: waiting} do
    for {code, why} <- [
          {"improvement_evidence_unavailable",
           "The person's messages were deleted or have expired, so there was nothing to analyze."},
          {"improvement_evidence_wordless",
           "The person's messages had no words Ryker can read, such as a file, an image or a review sent without any, so there was nothing to analyze."},
          {"improvement_evidence_automated",
           "No person asked for it: an alert, a schedule or an app's message started it, so there were no person's words to analyze."}
        ] do
      Repo.update_all(from(c in Candidate, where: c.id == ^waiting.id),
        set: [analysis: :failed, error_code: code]
      )

      document =
        Pages.page(["feedback", "fix"], %{}, options())
        |> Map.fetch!(:body)
        |> LazyHTML.from_fragment()

      row = row(document, waiting.id)
      assert text(LazyHTML.query(row, "h3 .state-word")) == "Not analyzed"
      assert row |> LazyHTML.query("h3 .state-word") |> LazyHTML.attribute("title") == [why]
      assert actions(row) == ["Dismiss"], code
      assert confirmation("/actions/improvement/#{waiting.id}/accept").status == 404
    end
  end

  # An eval case replays Slack and Chat messages; a GitHub request's
  # diagnosis is still worth reading, and its row says why it has no Accept.
  test "a GitHub request shows its diagnosis and says it cannot be kept as an eval case yet" do
    entry = Answers.github_message!(body: "@ryker why did the payments export fail on PR 42?")

    reply =
      Answers.work_reply!(
        entry,
        "It timed out.",
        "github:issue_comment:#{System.unique_integer([:positive])}",
        DateTime.utc_now()
      )

    assert {:ok, _recorded} =
             Feedback.record(%{
               kind: :reviewed,
               value: "needs_work",
               actor_ref: "control-plane:local",
               source: "control_plane",
               source_ref: "episode-review:#{Ecto.UUID.generate()}",
               occurred_at: DateTime.utc_now(),
               request: {:episode, reply.episode.id}
             })

    github = Improvement.for_request({:episode, reply.episode.id})

    Repo.update_all(from(c in Candidate, where: c.id == ^github.id),
      set: [
        analysis: :done,
        category: :model_mistake,
        step: :work,
        confidence: :medium,
        what_went_wrong: "It blamed a timeout; the export log shows a bad credential.",
        expected: "Names the failed credential from the export log.",
        analyzed_at: DateTime.utc_now()
      ]
    )

    document =
      Pages.page(["feedback", "fix"], %{}, options())
      |> Map.fetch!(:body)
      |> LazyHTML.from_fragment()

    row = row(document, github.id)
    assert text(LazyHTML.query(row, "h3 .state-word")) == "Model mistake"
    assert text(row) =~ "It blamed a timeout"
    assert text(row) =~ "Eval case GitHub requests cannot be kept as eval cases yet."
    assert actions(row) == ["Dismiss"]
    assert confirmation("/actions/improvement/#{github.id}/accept").status == 404
  end

  # The page says what the loop did in the last seven days, in words: what
  # was found and what people decided (`Ryker.Improvement.week/2`).
  test "the page says what the last seven days brought and what was decided",
       %{staging: staging, access: access} do
    old = unhappy!("COLDWEEK", 1_790_000_000, "Old question", "Old answer", diagnosis: nil)
    assert {:ok, _dismissed} = Improvement.dismiss(old.id, "control-plane:local")
    eight_days_ago = DateTime.add(DateTime.utc_now(), -8 * 86_400, :second)

    Repo.update_all(from(c in Candidate, where: c.id == ^old.id),
      set: [inserted_at: eight_days_ago, decided_at: eight_days_ago]
    )

    assert {:ok, _accepted} = Improvement.accept(access.id, "control-plane:local")
    assert {:ok, _dismissed} = Improvement.dismiss(staging.id, "control-plane:local")

    assert week(Pages.page(["feedback", "fix"], %{}, options())) ==
             "Last 7 days 3 new: 1 host bug, 1 prompt bug and 1 still to analyze. 1 accepted as an eval case and 1 dismissed."

    # A quiet week says so, rather than leaving the line out.
    Repo.update_all(Candidate, set: [inserted_at: eight_days_ago])

    Repo.update_all(from(c in Candidate, where: c.status != :open),
      set: [decided_at: eight_days_ago]
    )

    assert week(Pages.page(["feedback", "fix"], %{"status" => "accepted"}, options())) ==
             "Last 7 days Nothing new, and nothing accepted or dismissed."
  end

  test "the Feedback page says how many are to decide, accepted and dismissed, and what went wrong",
       %{access: access} do
    assert {:ok, _accepted} = Improvement.accept(access.id, "control-plane:local")

    document =
      Pages.page(["feedback"], %{}, options())
      |> Map.fetch!(:body)
      |> LazyHTML.from_fragment()

    fix = LazyHTML.query(document, "section[aria-labelledby=feedback-fix]")
    assert text(LazyHTML.query(fix, ".section-head h2")) == "What to fix"

    assert fix |> LazyHTML.query(".kit-count") |> Enum.map(&{text(&1), href(&1)}) == [
             {"2 to decide", "/feedback/fix"},
             {"1 accepted", "/feedback/fix?status=accepted"},
             {"1 prompt bug", "/feedback/fix?category=prompt_bug&status=open"}
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

  defp week(page) do
    page.body
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#improvement-week")
    |> text()
  end

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
