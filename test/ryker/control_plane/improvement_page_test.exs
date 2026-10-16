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
  alias Ryker.Improvement.{AnalysisRun, Candidate}
  alias Ryker.Inspectors

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

    # The three decisions are tabs with their counts, said once
    # (approved 2026-10-15); no row of counts repeats them.
    assert tabs(document) == [
             {"To decide 3", "/feedback/fix", "page"},
             {"Accepted 0", "/feedback/fix?status=accepted", nil},
             {"Dismissed 0", "/feedback/fix?status=dismissed", nil}
           ]

    assert Enum.empty?(LazyHTML.query(document, ".kit-counts"))

    # Newest day first; within the day the surest diagnosis first, and a
    # request Ryker has not analyzed yet last.
    assert ids(document) == [access.id, staging.id, waiting.id]

    # The request and what went wrong lead, with what Ryker should have done
    # under it; the category is a suspected cause with its confidence in the
    # line under the title, and no stage tag.
    card = row(document, access.id)
    assert text(LazyHTML.query(card, ".finding-header h3")) == "Check health of our infra"

    cause = LazyHTML.query(card, ".finding-meta .finding-cause")
    assert text(cause) == "Suspected cause: Ryker's code (high confidence)"
    assert LazyHTML.attribute(cause, "title") |> hd() =~ "tool was missing"

    assert text(LazyHTML.query(card, ".finding-meta")) =~
             "Feedback: frustrated, reacted with a thumbs down"

    refute text(card) =~ "In Work"
    refute text(card) =~ "Host bug"

    assert text(LazyHTML.query(card, ".finding-explanation")) =~ "Ryker asked for access it had"

    assert text(LazyHTML.query(card, ".finding-expected")) ==
             "What Ryker should have done Checks health through the connected Emisar runners without asking for access."

    # The footer holds the way to the request and the decision.
    assert card |> LazyHTML.query(".finding-footer a.inline-link") |> LazyHTML.attribute("href") ==
             ["/timeline/" <> access.episode_id]

    assert actions(card) == ["Dismiss", "Accept as eval case"]

    assert text(LazyHTML.query(row(document, waiting.id), ".finding-cause")) ==
             "Waiting to be analyzed"
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

    assert tabs(document) == [
             {"To decide 1", "/feedback/fix", nil},
             {"Accepted 1", "/feedback/fix?status=accepted", "page"},
             {"Dismissed 1", "/feedback/fix?status=dismissed", nil}
           ]

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
      assert text(LazyHTML.query(row, ".finding-cause")) == "Not analyzed"
      assert text(LazyHTML.query(row, ".finding-note")) == why
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

    github = Inspectors.improvement_candidate({:episode, reply.episode.id})

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

    assert text(LazyHTML.query(row, ".finding-cause")) ==
             "Suspected cause: a model mistake (medium confidence)"

    assert text(row) =~ "It blamed a timeout"

    assert text(LazyHTML.query(row, ".finding-unsupported")) ==
             "GitHub requests cannot be kept as eval cases yet."

    assert actions(row) == ["Dismiss"]
    assert confirmation("/actions/improvement/#{github.id}/accept").status == 404
  end

  # A category's own link, from the Feedback page's counts, still narrows the
  # view; the page says what it shows and how to see the rest.
  test "a category view says what it narrows to, with the way back to all of them",
       %{access: access} do
    document =
      Pages.page(["feedback", "fix"], %{"category" => "host_bug"}, options())
      |> Map.fetch!(:body)
      |> LazyHTML.from_fragment()

    assert ids(document) == [access.id]
    assert text(LazyHTML.query(document, ".finding-filter")) == "1 host bug · Show all"

    assert document |> LazyHTML.query(".finding-filter a") |> LazyHTML.attribute("href") ==
             ["/feedback/fix"]

    refute text(document) =~ "Last 7 days"
  end

  # The finding's Model run says how its analysis ran, from the attempt the
  # finding came from: the model, every attempt with the way to them on the
  # request's timeline, and the raw response.
  test "a finding's Model run reads the attempt it came from and links every attempt",
       %{access: access} do
    first = analysis_run!(access, 1, :rejected)
    applied = analysis_run!(access, 2, :applied)

    card =
      Pages.page(["feedback", "fix"], %{}, options())
      |> Map.fetch!(:body)
      |> LazyHTML.from_fragment()
      |> row(access.id)

    run = LazyHTML.query(card, "details.finding-run")
    assert LazyHTML.attribute(run, "open") == []

    assert text(LazyHTML.query(run, ".run-group[aria-label='Model and attempts']")) ==
             "Model & attempts gpt-5.6-sol Medium reasoning 2 attempts View all attempts →"

    assert run |> LazyHTML.query(".run-attempts a") |> LazyHTML.attribute("href") ==
             ["/timeline/#{access.episode_id}#self-analysis-#{first.id}"]

    raw = run |> LazyHTML.query(".json-disclosure pre") |> LazyHTML.text()
    assert Jason.decode!(raw)["what_went_wrong"] == "From attempt #{applied.generation}."
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

    candidate = Inspectors.improvement_candidate(request)

    if diagnosis do
      Repo.update_all(from(c in Candidate, where: c.id == ^candidate.id),
        set: Keyword.merge(diagnosis, analysis: :done, analyzed_at: DateTime.utc_now())
      )
    end

    Repo.get!(Candidate, candidate.id)
  end

  defp time(unix), do: DateTime.from_unix!(unix * 1_000_000, :microsecond)

  defp analysis_run!(candidate, generation, status) do
    at = DateTime.add(DateTime.utc_now(), generation * 60, :second)

    Repo.insert!(%AnalysisRun{
      id: Ecto.UUID.generate(),
      candidate_id: candidate.id,
      generation: generation,
      status: status,
      policy: "ryker-learning",
      policy_digest: String.duplicate("a", 64),
      prompt: "{}",
      prompt_sha256: String.duplicate("b", 64),
      output_schema: %{},
      manifest: %{},
      started_at: at,
      producer: %{"target" => "codex:gpt-5.6-sol/medium@emisar"},
      result: Jason.encode!(%{"what_went_wrong" => "From attempt #{generation}."}),
      result_sha256: String.duplicate("c", 64),
      stop_receipt: %{"kind" => "terminal_turn"},
      remote_stopped_at: DateTime.add(at, 30, :second),
      inserted_at: at,
      updated_at: DateTime.add(at, 30, :second)
    })
  end

  defp options, do: %{projection: Projection.callbacks()}

  defp tabs(document) do
    document
    |> LazyHTML.query(".kit-tabs a")
    |> Enum.map(fn tab ->
      {text(tab), href(tab), tab |> LazyHTML.attribute("aria-current") |> List.first()}
    end)
  end

  defp ids(document) do
    document
    |> LazyHTML.query(".finding")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "improvement-", ""))
  end

  defp row(document, id), do: LazyHTML.query(document, "#improvement-#{id}")

  defp actions(row) do
    row
    |> LazyHTML.query(".finding-actions form[method=get] button")
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
