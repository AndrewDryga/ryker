defmodule Ryker.Slack.SourceWindowTest do
  use ExUnit.Case, async: true

  alias Ryker.Slack.{SourceRef, SourceWindow}

  test "bounded long scans do not re-emit discarded distant originals when expanding nearer pages" do
    originals = originals(900)
    root = hd(originals)
    anchor = Enum.at(originals, 850)
    source = %{source(root) | kind: :thread}
    read = reader(originals, root)

    {_, found} =
      Enum.reduce(1..4, {bounds(10), []}, fn _, {document, found} ->
        assert {:ok, page} = SourceWindow.read(read, source, document, anchor, root)
        {Map.put(document, "cursor", page["cursor"]), found ++ page["messages"]}
      end)

    assert length(Enum.uniq_by(found, & &1["ts"])) == length(found)
  end

  test "a historical upper bound selects actual neighbors inside that range" do
    originals = originals(250)
    anchor = Enum.at(originals, 180)
    document = Map.put(bounds(10), "latest", Enum.at(originals, 100)["ts"])

    assert {:ok, page} =
             SourceWindow.read(reader(originals, nil), source(anchor), document, anchor, nil)

    assert page["messages"] == Enum.slice(originals, 95, 5)
    refute page["coverage"]["before"]["adjacent"]
  end

  test "the last allowed window reports its ceiling instead of returning a doomed cursor" do
    originals = originals(25)
    anchor = Enum.at(originals, 12)
    document = Map.put(bounds(10), "cursor", %{"page" => 9, "before" => nil, "after" => nil})

    assert {:ok, page} =
             SourceWindow.read(reader(originals, nil), source(anchor), document, anchor, nil)

    assert page["cursor"] == ""
    assert page["coverage"]["continuation_exhausted"]
    refute page["complete"]
    assert [before, after_read] = page["source_reads"]

    assert before["arguments"]["source_ref"] ==
             SourceRef.message("T123", "C456", Enum.at(originals, 7)["ts"])

    assert after_read["arguments"]["source_ref"] ==
             SourceRef.message("T123", "C456", Enum.at(originals, 17)["ts"])

    for read <- [before, after_read] do
      assert read["tool"] == "read_slack_source"
      assert read["arguments"]["view"] == "surrounding"
      refute read["arguments"]["cursor"]
    end
  end

  test "source continuation does not lose originals trimmed from an exhausted provider page" do
    originals = originals(25)
    anchor = Enum.at(originals, 12)
    source = source(anchor)
    read = reader(originals, nil)
    found = collect(read, source, bounds(10), anchor, [], 0)
    expected = Enum.reject(originals, &(&1 == anchor))
    assert length(found) == length(expected)
    assert MapSet.new(Enum.map(found, & &1["ts"])) == MapSet.new(Enum.map(expected, & &1["ts"]))
  end

  defp collect(_read, _source, _document, _anchor, _found, 10),
    do: flunk("unexpected continuation ceiling")

  defp collect(read, source, document, anchor, found, count) do
    assert {:ok, page} = SourceWindow.read(read, source, document, anchor, nil)
    found = found ++ page["messages"]

    if page["cursor"] == "",
      do: found,
      else:
        collect(
          read,
          source,
          Map.put(document, "cursor", page["cursor"]),
          anchor,
          found,
          count + 1
        )
  end

  test "dense channel history returns the nearest messages on both sides of the anchor" do
    originals = originals(250)
    anchor = Enum.at(originals, 100)
    source = source(anchor)
    read = reader(originals, nil)

    assert {:ok, window} = SourceWindow.read(read, source, bounds(10), anchor, nil)

    assert Enum.map(window["messages"], & &1["ts"]) ==
             Enum.map(Enum.slice(originals, 95, 5) ++ Enum.slice(originals, 101, 5), & &1["ts"])

    assert window["coverage"]["before"]["adjacent"]
    assert window["coverage"]["after"]["adjacent"]
    refute window["complete"]
    assert window["coverage"]["provider_pages"] <= 4
  end

  test "a deep thread has nearby replies without repeating its root or exact anchor" do
    originals = originals(250)
    root = hd(originals)
    anchor = Enum.at(originals, 180)
    source = %{source(root) | kind: :thread} |> Map.put(:anchor_message_ref, anchor["ts"])

    assert {:ok, window} =
             SourceWindow.read(reader(originals, root), source, bounds(10), anchor, root)

    assert Enum.map(window["messages"], & &1["ts"]) ==
             Enum.map(Enum.slice(originals, 175, 5) ++ Enum.slice(originals, 181, 5), & &1["ts"])

    assert window["coverage"]["before"]["adjacent"]
    assert window["coverage"]["after"]["adjacent"]
  end

  test "a very long thread stops scanning and gives a bounded continuation instead of false neighbors" do
    originals = originals(900)
    root = hd(originals)
    anchor = Enum.at(originals, 850)
    source = %{source(root) | kind: :thread} |> Map.put(:anchor_message_ref, anchor["ts"])
    read = reader(originals, root)

    assert {:ok, first} = SourceWindow.read(read, source, bounds(10), anchor, root)
    refute first["coverage"]["before"]["adjacent"]
    assert first["coverage"]["provider_pages"] == 4
    assert is_map(first["cursor"])

    assert {:ok, second} =
             SourceWindow.read(
               read,
               source,
               Map.put(bounds(10), "cursor", first["cursor"]),
               anchor,
               root
             )

    refute second["coverage"]["before"]["adjacent"]

    assert {:ok, third} =
             SourceWindow.read(
               read,
               source,
               Map.put(bounds(10), "cursor", second["cursor"]),
               anchor,
               root
             )

    assert third["coverage"]["before"]["adjacent"]

    assert Enum.map(third["messages"], & &1["ts"]) ==
             Enum.map(Enum.slice(originals, 845, 5) ++ Enum.slice(originals, 861, 5), & &1["ts"])
  end

  test "a missing provider cursor never implies a complete limited history" do
    [anchor, later | _] = originals(3)
    read = fn _ -> {:ok, %{"messages" => [later], "cursor" => "", "has_more" => true}} end
    assert {:ok, window} = SourceWindow.read(read, source(anchor), bounds(10), anchor, nil)
    refute window["complete"]
    refute window["coverage"]["after"]["adjacent"]
  end

  defp reader(originals, root) do
    fn document ->
      send(self(), {:page, document})
      offset = if document["cursor"], do: String.to_integer(document["cursor"]), else: 0

      rows =
        Enum.filter(originals, fn row ->
          (is_nil(document["oldest"]) or row["ts"] > document["oldest"]) and
            (is_nil(document["latest"]) or row["ts"] < document["latest"])
        end)

      rows = if root, do: rows, else: Enum.reverse(rows)
      page = Enum.slice(rows, offset, document["limit"])

      cursor =
        if offset + length(page) < length(rows), do: to_string(offset + length(page)), else: ""

      page = if root, do: Enum.uniq_by([root | page], & &1["ts"]), else: page
      {:ok, %{"messages" => page, "cursor" => cursor}}
    end
  end

  defp originals(count) do
    # Synthetic cardinality only; production wording is exercised by the
    # harvested readiness thread in CapabilityToolsTest.
    for n <- 1..count, do: %{"ts" => "#{1_789_000_000 + n}.000001", "text" => "row #{n}"}
  end

  defp source(anchor),
    do: %{kind: :message, message_ref: anchor["ts"], workspace_ref: "T123", channel_ref: "C456"}

  defp bounds(limit), do: %{"cursor" => nil, "oldest" => nil, "latest" => nil, "limit" => limit}
end
