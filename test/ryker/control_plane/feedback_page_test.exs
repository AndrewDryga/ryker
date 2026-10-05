defmodule Ryker.ControlPlane.FeedbackPageTest do
  @moduledoc """
  Andrew, 2026-09-27: "let users see feedback by category in UI, do something
  about it (at very least see where users were frustrated to see what
  happened and fix the issue)". The Feedback page lists what people said
  about Ryker's answers by kind, frustrated first, and over time, each row
  opening the request where it happened; a request's Timeline lists its own.
  """
  use Ryker.DataCase, async: true

  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{
    EpisodePage,
    EpisodeProjection,
    FeedbackPage,
    Kit,
    ModelRequests,
    Pages,
    Projection
  }

  alias Ryker.Feedback
  alias Ryker.Fixtures.Answers

  @workspace "TFEEDBACKPAGE"

  setup do
    channel = "CFEEDBACKPAGE#{System.unique_integer([:positive])}"
    # Recent, so the page reads it as today; the day is read back from the
    # same clock, never assumed.
    base = DateTime.to_unix(DateTime.utc_now()) - 600

    question =
      Answers.slack_message!(
        workspace: @workspace,
        channel: channel,
        text: "Is checkout up?",
        ts: "#{base}.000100"
      )

    reply =
      Answers.work_reply!(question, "Checkout is up.", "#{base + 60}.000100", at(base + 60))

    greeting =
      Answers.slack_message!(
        workspace: @workspace,
        channel: channel,
        text: "Count to three",
        ts: "#{base + 120}.000100"
      )

    Answers.quick_reply!(greeting, "1, 2, 3.", "#{base + 125}.000100", at(base + 125))

    signal!(:sentiment, "angry", {:episode, reply.episode.id}, base + 200,
      note: "They say checkout is down for them."
    )

    signal!(:reaction_added, "-1", {:episode, reply.episode.id}, base + 210)
    signal!(:asked_again, nil, {:episode, reply.episode.id}, base + 220)
    signal!(:reaction_added, "+1", {:input, greeting.id}, base + 230)

    signal!(:reviewed, "good", {:episode, reply.episode.id}, base + 240,
      note: "Checked the status page.",
      actor: "control-plane:local",
      source: "control_plane"
    )

    signal!(:sentiment, "neutral", {:episode, reply.episode.id}, base + 250)

    day = Kit.day_label(DateTime.to_date(at(base + 200)), Date.utc_today())
    %{reply: reply, greeting: greeting, day: day}
  end

  test "feedback leads with each kind, frustrated first, and opens the request where it happened",
       %{reply: reply, greeting: greeting} do
    document = page(%{})

    # The feedback first, then what there is to fix: the unhappy request is
    # one candidate, however many negative signals it got.
    assert counts(document) == [
             {"6 pieces of feedback", nil},
             {"2 frustrated", "/feedback?category=frustrated"},
             {"1 asked again", "/feedback?category=asked_again"},
             {"1 neutral", "/feedback?category=neutral"},
             {"2 satisfied", "/feedback?category=satisfied"},
             {"1 to decide", "/feedback/fix"}
           ]

    assert document |> LazyHTML.query(".section-head h2") |> Enum.map(&text/1) ==
             ["By day", "What to fix", "Frustrated", "Asked again", "Neutral", "Satisfied"]

    # Over time is the chart alone; the table that repeated it is gone.
    assert document |> LazyHTML.query(".kit-table") |> Enum.count() == 0

    assert document |> LazyHTML.query("g.feedback-chart-day") |> LazyHTML.attribute("data-date") ==
             [Date.to_iso8601(Date.utc_today())]

    frustrated = LazyHTML.query(document, "#feedback-frustrated .entity-row")
    assert Enum.count(frustrated) == 2

    assert frustrated |> LazyHTML.query(".entity-side .state-word") |> Enum.map(&text/1) ==
             ["Frustrated", "Angry"]

    assert frustrated |> LazyHTML.query(".entity-name a") |> LazyHTML.attribute("href") ==
             List.duplicate("/timeline/" <> reply.episode.id, 2)

    assert text(frustrated) =~ "Is checkout up?"
    assert text(frustrated) =~ ~s("They say checkout is down for them.")
    assert text(frustrated) =~ "Reacted 👎"

    satisfied = LazyHTML.query(document, "#feedback-satisfied .entity-row")
    assert text(satisfied) =~ "Count to three"
    assert text(satisfied) =~ ~s("Checked the status page.")

    assert satisfied |> LazyHTML.query(".entity-name a") |> LazyHTML.attribute("href") ==
             ["/timeline/" <> reply.episode.id, "/timeline/" <> greeting.id]

    # A state says what it means when pointed at.
    assert document
           |> LazyHTML.query("#feedback-asked_again .state-word")
           |> LazyHTML.attribute("title") ==
             ["They asked the same thing again within ten minutes of Ryker's answer."]
  end

  test "one kind is a page of its own, newest first under day headings, with the way back",
       %{day: day} do
    page = Pages.page(["feedback"], %{"category" => "frustrated"}, options())

    assert {page.status, page.title, page.back} ==
             {200, "Frustrated", {"All feedback", "/feedback"}}

    assert page.description =~ "frustrated or angry"
    document = LazyHTML.from_fragment(page.body)
    assert counts(document) == [{"2 pieces of feedback", nil}]
    assert document |> LazyHTML.query(".entity-group") |> Enum.map(&text/1) == [day]

    assert document |> LazyHTML.query(".entity-side .state-word") |> Enum.map(&text/1) ==
             ["Frustrated", "Angry"]

    # A search there stays there.
    assert document
           |> LazyHTML.query("form.filter-toolbar input[type=hidden][name=category]")
           |> LazyHTML.attribute("value") == ["frustrated"]
  end

  test "a search narrows by what the feedback says and by the request it is about" do
    assert counts(page(%{"q" => "down for them"})) == [
             {"1 matching", nil},
             {"1 frustrated",
              "/feedback?" <>
                URI.encode_query(%{"category" => "frustrated", "q" => "down for them"})}
           ]

    assert page(%{"q" => "count to three"}) |> counts() |> hd() == {"1 matching", nil}

    empty = page(%{"q" => "nothing like this"})
    assert empty |> LazyHTML.query(".kit-empty-title") |> text() =~ "No feedback matches"
  end

  # Andrew, 2026-09-28: Feedback "needs toggle-buttons to see
  # positive/negative feedbacks". Negative and Positive narrow everything on
  # the page, the counts, By day and the lists, and a search keeps the choice.
  test "Negative and Positive narrow the whole page to the feedback that went that way" do
    negative = page(%{"tone" => "negative"})

    assert counts(negative) == [
             {"3 pieces of feedback", nil},
             {"2 frustrated", "/feedback?category=frustrated"},
             {"1 asked again", "/feedback?category=asked_again"},
             {"1 to decide", "/feedback/fix"}
           ]

    assert negative |> LazyHTML.query(".section-head h2") |> Enum.map(&text/1) ==
             ["By day", "What to fix", "Frustrated", "Asked again"]

    # By day is all feedback, whichever way the filters below narrow the list.
    date = Calendar.strftime(Date.utc_today(), "%d %b")

    assert negative |> LazyHTML.query("g.feedback-chart-day") |> LazyHTML.attribute("aria-label") ==
             ["#{date}: 3 negative, 1 neutral, 2 positive"]

    assert negative |> LazyHTML.query("nav.segmented a") |> Enum.map(&text/1) ==
             ["All", "Negative", "Positive"]

    assert negative |> LazyHTML.query("nav.segmented a") |> LazyHTML.attribute("href") ==
             ["/feedback", "/feedback?tone=negative", "/feedback?tone=positive"]

    assert negative |> LazyHTML.query("nav.segmented a[aria-current=page]") |> text() ==
             "Negative"

    assert negative
           |> LazyHTML.query("form.filter-toolbar input[type=hidden][name=tone]")
           |> LazyHTML.attribute("value") == ["negative"]

    # What to fix is about unhappy requests, so Positive leaves it out.
    positive = page(%{"tone" => "positive"})

    assert counts(positive) == [
             {"2 pieces of feedback", nil},
             {"2 satisfied", "/feedback?category=satisfied"}
           ]

    assert positive |> LazyHTML.query(".section-head h2") |> Enum.map(&text/1) ==
             ["By day", "Satisfied"]

    assert page(%{"tone" => "positive", "q" => "checkout"})
           |> LazyHTML.query(".kit-empty-title")
           |> text() =~ "No positive feedback matches"
  end

  # Andrew, 2026-09-28: By day "should be a graph like in usage", then "put
  # it above filters and make filters not apply to it" and drop the table.
  test "By day leads the page with a bar a day, negative at its foot, above the filters" do
    document = page(%{})
    by_day = LazyHTML.query(document, "section[aria-labelledby=feedback-by-day]")

    assert document
           |> LazyHTML.query("div.memory-feedback > *")
           |> Enum.take(2)
           |> Enum.map(&tag/1) ==
             ["section.feedback-by-day", "p.kit-counts"]

    [bar] = by_day |> LazyHTML.query("g.feedback-chart-day") |> Enum.to_list()
    date = Calendar.strftime(Date.utc_today(), "%d %b")
    assert LazyHTML.attribute(bar, "aria-label") == ["#{date}: 3 negative, 1 neutral, 2 positive"]

    rects = LazyHTML.query(bar, "rect")

    assert rects |> LazyHTML.attribute("class") ==
             [
               "feedback-bar feedback-bar-negative",
               "feedback-bar feedback-bar-neutral",
               "feedback-bar feedback-bar-positive"
             ]

    [foot | _] = Enum.to_list(rects)
    [y] = LazyHTML.attribute(foot, "y")
    [height] = LazyHTML.attribute(foot, "height")
    assert_in_delta String.to_float(y) + String.to_float(height), 190.0, 0.01
  end

  test "a request's Timeline has a Feedback chapter, and a message routing answered has its own",
       %{reply: reply, greeting: greeting} do
    {:ok, snapshot} = EpisodeProjection.fetch(reply.episode.key)
    {:ok, timeline} = ModelRequests.timeline(reply.episode.key, %{})

    document =
      render_component(&EpisodePage.render/1, snapshot: snapshot, timeline: timeline, params: %{})
      |> LazyHTML.from_fragment()

    chapter = LazyHTML.query(document, "#feedback")
    assert chapter |> LazyHTML.query("h3") |> Enum.map(&text/1) |> List.first() == "Feedback"

    # Every signal is a card here, oldest first; how a person rated the
    # request is one of them.
    assert chapter |> LazyHTML.query(".feedback-card h3") |> Enum.map(&text/1) ==
             [
               "How they felt about the answer",
               "Reacted 👎",
               "Asked the same thing again",
               "Rated: went well",
               "How they felt about the answer"
             ]

    assert chapter |> LazyHTML.query(".feedback-card .state-word") |> Enum.map(&text/1) ==
             ["Angry", "Frustrated", "Asked again", "Went well", "Neutral"]

    assert text(chapter) =~ ~s("They say checkout is down for them.")

    {:ok, view} = ModelRequests.project_input(greeting.id, %{})

    message =
      render_component(&EpisodePage.message_page/1, view: view) |> LazyHTML.from_fragment()

    assert message |> LazyHTML.query("#feedback .feedback-card h3") |> Enum.map(&text/1) ==
             ["Reacted 👍"]
  end

  test "an empty Feedback page says what would put something there" do
    document =
      %{category: nil, counts: %{}, days: [], groups: [], q: "", tone: nil, total: 0}
      |> FeedbackPage.html()
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    assert document |> LazyHTML.query(".kit-empty-title") |> text() == "No feedback yet"
    assert document |> LazyHTML.query(".kit-empty-text") |> text() =~ "react to Ryker's answers"
    assert LazyHTML.query(document, ".kit-toolbar") |> Enum.count() == 0
    assert LazyHTML.query(document, ".kit-table") |> Enum.count() == 0
  end

  defp page(params) do
    Pages.page(["feedback"], params, options())
    |> Map.fetch!(:body)
    |> LazyHTML.from_fragment()
  end

  defp options, do: %{projection: Projection.callbacks()}

  defp counts(document) do
    for count <- LazyHTML.query(document, ".kit-counts .kit-count") do
      {text(count), count |> LazyHTML.attribute("href") |> List.first()}
    end
  end

  defp signal!(kind, value, request, unix, options \\ []) do
    assert {:ok, %{status: :recorded}} =
             Feedback.record(%{
               kind: kind,
               value: value,
               note: Keyword.get(options, :note),
               actor_ref: Keyword.get(options, :actor, "UALICE"),
               source: Keyword.get(options, :source, "slack"),
               source_ref: "feedback-page:#{kind}:#{unix}",
               occurred_at: at(unix),
               request: request
             })
  end

  defp tag(node) do
    [tag] = LazyHTML.tag(node)
    [class | _] = node |> LazyHTML.attribute("class") |> hd() |> String.split()
    tag <> "." <> class
  end

  defp at(unix), do: DateTime.from_unix!(unix * 1_000_000, :microsecond)
  defp text(node), do: node |> LazyHTML.text() |> String.split() |> Enum.join(" ")
end
