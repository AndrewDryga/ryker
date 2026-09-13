defmodule Ryker.ControlPlane.ChannelsPageTest do
  @moduledoc """
  The Channels list inside the shared Configuration shell: one toolbar, a
  quiet count and one comparison table whose rows keep the raw Slack
  identifiers reachable while reading as names and words.
  """
  use ExUnit.Case, async: true

  alias Ryker.ControlPlane.{HTML, Pages}

  @channel %{
    channel_ref: "C456",
    custom_instructions: true,
    episodes: 2,
    incident_room: false,
    last_at: ~U[2026-08-28 12:00:00Z],
    membership: :joined,
    participation: :mentions,
    private: false,
    repository_ref: "ryker",
    workspace_ref: "T123"
  }

  test "the channels page is one toolbar, one quiet count and one comparison table in that order" do
    # Before 2026-09-13 the body opened with a "Slack conversation roster"
    # heading under the shell's "Channels" and an eight-column table-wrap that
    # scrolled sideways on a phone with the channel name scrolling away first.
    document = render([@channel, %{@channel | channel_ref: "C789", membership: :left}])

    assert outline(document, "div.channels-page > *") == [
             "form.filter-toolbar",
             "p.result-count",
             "table.data-table"
           ]

    assert LazyHTML.query(document, "p.result-count") |> LazyHTML.text() == "2 channels"
    assert Enum.empty?(LazyHTML.query(document, "h1, h2, .page-description, .table-wrap"))

    assert LazyHTML.query(document, "thead th") |> LazyHTML.text() ==
             "ChannelMembershipParticipationInstructionsRepositoryEpisodesLast activity"

    labels =
      LazyHTML.query(document, "tbody tr:first-child td") |> LazyHTML.attribute("data-label")

    assert labels == [
             "Channel",
             "Membership",
             "Participation",
             "Instructions",
             "Repository",
             "Episodes",
             "Last activity"
           ]

    assert Enum.count(LazyHTML.query(document, "tbody tr > td:first-child.row-identity")) == 2
  end

  test "a channel row links to its detail, keeps the raw workspace and channel ids reachable, and reads as words" do
    # The old row printed the raw atoms "joined" and "mentions", an ISO-8601
    # last activity, and hid the identifiers in title attributes that neither
    # keyboard nor touch can reach.
    document = render([@channel])
    row = LazyHTML.query(document, "tbody tr")

    identity = LazyHTML.query(row, "td.row-identity")
    assert LazyHTML.query(identity, "a[href='/channels/T123/C456']") |> LazyHTML.text() =~ "C456"
    secondary = LazyHTML.query(identity, ".row-secondary") |> LazyHTML.text()
    assert secondary =~ "T123"
    assert secondary =~ "shared channel"

    membership = LazyHTML.query(row, "td[data-label='Membership'] .ui-status")
    assert LazyHTML.text(membership) == "Joined"
    assert LazyHTML.attribute(membership, "class") == ["ui-status status-active"]
    assert LazyHTML.query(row, "td[data-label='Participation']") |> LazyHTML.text() == "Mentions"

    assert LazyHTML.query(row, "td[data-label='Instructions']") |> LazyHTML.text() ==
             "Global + channel"

    assert LazyHTML.query(row, "td[data-label='Repository']") |> LazyHTML.text() == "ryker"
    assert LazyHTML.query(row, "td[data-label='Episodes']") |> LazyHTML.text() == "2"

    last = LazyHTML.query(row, "td[data-label='Last activity'] time")
    assert LazyHTML.text(last) == "28 Aug, 12:00 UTC"
    assert LazyHTML.attribute(last, "datetime") == ["2026-08-28T12:00:00Z"]
  end

  test "unrecorded membership, participation, repository and activity say so instead of showing blanks" do
    document =
      render([
        %{
          @channel
          | channel_ref: "DABC",
            custom_instructions: false,
            episodes: 0,
            last_at: nil,
            membership: nil,
            participation: nil,
            repository_ref: nil
        }
      ])

    row = LazyHTML.query(document, "tbody tr")
    assert LazyHTML.query(row, "td[data-label='Membership']") |> LazyHTML.text() =~ "Not recorded"

    assert LazyHTML.query(row, "td[data-label='Participation']") |> LazyHTML.text() ==
             "Not configured"

    assert LazyHTML.query(row, "td[data-label='Instructions']") |> LazyHTML.text() ==
             "Global only"

    assert LazyHTML.query(row, "td[data-label='Repository']") |> LazyHTML.text() == "None"

    assert LazyHTML.query(row, "td[data-label='Last activity']") |> LazyHTML.text() ==
             "No activity recorded"

    assert LazyHTML.query(row, "td.row-identity .row-secondary") |> LazyHTML.text() =~
             "direct message"

    incident = render([%{@channel | incident_room: true}])

    assert LazyHTML.query(incident, "td.row-identity .row-secondary") |> LazyHTML.text() =~
             "incident room"
  end

  test "an empty channels list tells a filtered miss from an installation with no known channels" do
    filtered = render([], %{"q" => "absent"})
    assert LazyHTML.query(filtered, "p.empty-state") |> LazyHTML.text() =~ "No channels match"
    assert Enum.empty?(LazyHTML.query(filtered, "p.result-count, table"))

    bare = render([])
    text = LazyHTML.query(bare, "p.empty-state") |> LazyHTML.text()
    assert text =~ "No channels yet"
    assert text =~ "configuration, membership, incident custody or recorded work"
    refute text =~ "durable records"
  end

  test "the route keeps the shell's title and description and carries the search into the toolbar" do
    page =
      Pages.page(["channels"], %{"q" => "infra"}, %{
        projection: %{channels: fn _params -> [@channel] end}
      })

    assert page.title == "Channels"
    assert page.description =~ "Slack channels Ryker knows about"
    document = LazyHTML.from_fragment(page.body)

    assert LazyHTML.query(document, "form.filter-toolbar input[name=q]")
           |> LazyHTML.attribute("value") == ["infra"]

    assert Enum.empty?(LazyHTML.query(document, "form.filter-toolbar select"))
  end

  defp render(items, params \\ %{}) do
    items |> HTML.channels(params) |> IO.iodata_to_binary() |> LazyHTML.from_fragment()
  end

  # "tag.first-class" for each matched element, in document order.
  defp outline(document, selector) do
    nodes = LazyHTML.query(document, selector)

    nodes
    |> LazyHTML.tag()
    |> Enum.zip(LazyHTML.attributes(nodes))
    |> Enum.map(fn {tag, attributes} ->
      case List.keyfind(attributes, "class", 0) do
        {"class", class} -> tag <> "." <> hd(String.split(class))
        nil -> tag
      end
    end)
  end
end
