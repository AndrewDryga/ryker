defmodule Ryker.ControlPlane.ContextSearch do
  @moduledoc """
  How Ryker gathered earlier work and memory for one routing call, in plain words.

  This is Ryker's own preparation, not part of the prompt, so it is a card of
  its own before the routing briefing. The briefing shows exactly what the
  model was sent; this card says where Ryker looked, how each of its
  searches looked (the words, links and IDs it used), what each found, and
  what it found but left out.
  """
  alias Ryker.ControlPlane.Paths
  alias Ryker.InspectionRedactor
  alias Ryker.Slack
  alias Ryker.Text
  alias Ryker.Wording

  @lanes [
    {"thread", "Same thread"},
    {"identity", "Same links or IDs"},
    {"text", "Similar wording"},
    {"meaning", "Similar meaning"},
    {"recent_active", "Work still in progress"}
  ]

  @doc "The card's content for a frozen routing snapshot, or nil when it kept no search record."
  @spec present(map() | nil) :: map() | nil
  def present(%{"routing_receipt" => %{} = receipt} = snapshot) do
    omitted = length(List.wrap(snapshot["knowledge_omissions"]))
    titles = frozen_titles(snapshot)

    %{
      summary:
        if(is_nil(selection_items(receipt)), do: found(receipt["examined"], receipt["offered"])),
      where: where(receipt),
      methods: methods(receipt, titles),
      facts:
        Enum.reject(
          [
            selection_fact(receipt),
            {"Knowledge", knowledge(snapshot)},
            {"Memory", memory(omitted)}
          ],
          &is_nil(elem(&1, 1))
        ),
      record:
        Jason.encode!(
          Map.take(snapshot, ["routing_receipt", "knowledge_omissions"]),
          pretty: true
        ),
      record_label: "Search record"
    }
  end

  def present(_snapshot), do: nil

  # Only the same frozen briefing can supply source prose. Today's digest can
  # contain another scope's text, including for a match never offered at all.
  defp frozen_titles(snapshot) do
    for %{"episode_id" => id, "digest" => %{"title" => title}} <-
          List.wrap(snapshot["candidates"]),
        is_binary(id) and is_binary(title),
        into: %{},
        do: {id, InspectionRedactor.artifact(title, max_bytes: 240).text}
  end

  # V9, 2026-09-28: the briefing said "Learned topics: None" and nothing about
  # what was searched. Routing is sent up to eight learned topics that share
  # words, links or IDs with the message, from this conversation and public
  # channels Ryker is in, and the newest notes, this conversation's first
  # (`Ryker.Admission.context/3`).
  defp knowledge(snapshot) do
    topics = length(List.wrap(snapshot["conversation_knowledge"]))
    notes = length(List.wrap(snapshot["conversation_observations"]))

    matched =
      case topics do
        0 -> "No learned topic shares words, links or IDs with the message"
        1 -> "1 learned topic shares words, links or IDs with the message"
        count -> "#{count} learned topics share words, links or IDs with the message"
      end

    recent =
      case notes do
        0 -> "no notes"
        1 -> "the 1 newest note"
        count -> "the #{count} newest notes"
      end

    "#{matched}; #{recent} came with it."
  end

  defp found(0, _offered), do: "Nothing found"
  defp found(found, found) when is_integer(found), do: "#{found} found, all offered"

  defp found(found, offered) when is_integer(found) and is_integer(offered),
    do: "#{found} found, #{offered} offered"

  defp found(_found, _offered), do: nil

  defp where(%{"scope" => scope} = receipt) do
    [place(scope, receipt), window(receipt["history_since"])]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp where(_receipt), do: nil

  defp place("conversation", _receipt), do: "This conversation"

  defp place("workspace_public", receipt) do
    names = receipt |> Map.get("conversation_refs", []) |> Enum.map(&Slack.Names.destination/1)
    count = receipt["eligible_conversations"] || length(names)

    listed =
      case names do
        [] -> "#{count} conversations"
        names -> listed(names, count)
      end

    capped = if receipt["scope_truncated"] == true, do: " (capped)", else: ""
    "Public channels Ryker is in: " <> listed <> capped
  end

  defp place(other, _receipt), do: Wording.label(other)

  defp listed(names, count) do
    shown = Enum.take(names, 4)
    rest = count - length(shown)
    Enum.join(shown, ", ") <> if(rest > 0, do: " and #{rest} more", else: "")
  end

  # Finished work only within the history window; work still in progress
  # always counts, however long ago it started.
  defp window(since) when is_binary(since) do
    case DateTime.from_iso8601(since) do
      {:ok, at, _offset} ->
        "work finished since #{Calendar.strftime(at, "%-d %b")}, and all work still in progress"

      _invalid ->
        nil
    end
  end

  defp window(_since), do: nil

  defp methods(%{"lanes" => %{} = lanes} = receipt, titles) do
    selection = selection_items(receipt)
    # Search by meaning is listed where it was set up, running or not.
    for {lane, name} <- method_lanes(receipt, selection) do
      facts = lanes[lane] || %{}

      results =
        for item <- selection || [],
            lane in List.wrap(item["lanes"]),
            do: search_result(item, titles)

      %{
        key: lane,
        name: name,
        used: used(lane, receipt),
        note: note(lane, receipt),
        found: facts["returned"] || length(results),
        ineligible: scope_exclusions(receipt)[lane],
        offered: if(is_list(selection), do: Enum.count(results, & &1.offered)),
        results: results,
        recorded: is_list(selection),
        limit: facts["saturated"] == true
      }
    end
  end

  defp methods(_receipt, _titles), do: []

  defp scope_exclusions(%{
         "selection" => %{"version" => 1, "items" => items, "ineligible" => %{} = counts}
       })
       when is_list(items), do: counts

  defp scope_exclusions(_historical), do: %{}

  defp method_lanes(receipt, selection) do
    lanes =
      Enum.reject(@lanes, fn {lane, _name} ->
        lane == "meaning" and not is_map(receipt["meaning"])
      end)

    if Enum.any?(selection || [], &("source_owner" in List.wrap(&1["lanes"]))),
      do: [{"source_owner", "Existing request for this source message"} | lanes],
      else: lanes
  end

  defp selection_items(%{"selection" => %{"version" => 1, "items" => items}}) when is_list(items),
    do: Enum.filter(items, &is_map/1)

  defp selection_items(_receipt), do: nil

  defp search_result(item, titles) do
    available = item["reason"] != "source_unavailable"
    id = item["episode_id"]
    title = if available, do: Map.get(titles, id)

    %{
      title: title || match_label(id),
      href: if(is_binary(title) and Ecto.UUID.cast(id) == {:ok, id}, do: Paths.request(id)),
      offered: item["offered"] == true,
      reason: selection_reason(item["reason"])
    }
  end

  defp match_label(id) when is_binary(id), do: "Request " <> String.slice(id, -8, 8)
  defp match_label(_id), do: "Earlier request"

  defp selection_reason("weak_match"), do: "Not closely enough related to this message."

  defp selection_reason("option_limit"),
    do: "Not selected within the routing-option limit and reserved places."

  defp selection_reason("pool_limit"),
    do: "Left out when the combined search pool reached its limit."

  defp selection_reason("source_unavailable"), do: "Its source was not available to this request."
  defp selection_reason("source_owner"), do: "Already owns this source message."
  defp selection_reason("supported_non_local"), do: "A supported match outside this thread."
  defp selection_reason("ranked"), do: "Selected by the recorded ranking."
  defp selection_reason(_reason), do: "Selection reason was not recorded."

  defp selection_fact(%{
         "selection" => %{"version" => 1, "limit" => limit, "reserved" => reserved}
       })
       when is_integer(limit) and is_integer(reserved) do
    {"Routing options",
     "Up to #{limit} options; #{Wording.count(reserved, "place")} reserved for supported matches outside this thread."}
  end

  defp selection_fact(receipt), do: {"Result", result(receipt)}

  defp used("text", %{"words" => words}) when is_list(words), do: words

  defp used("identity", %{"identifiers" => identifiers}) when is_list(identifiers),
    do: Enum.map(identifiers, &Text.shorten(&1, 60))

  defp used(_lane, _receipt), do: []

  # Why a search had nothing to look with, or what it left out, when that is
  # recorded. Words in more than a quarter of the searchable work say little
  # about which one a message is about, and are left out
  # (`Ryker.Admission.CandidateSearch`).
  defp note("thread", %{"in_thread" => false}), do: "the message was not in a thread"
  defp note("identity", %{"identifiers" => []}), do: "no links or IDs in the message"

  defp note("text", %{"words" => [], "common_words" => [_ | _] = common}),
    do: "only words too common to tell work apart: " <> Enum.join(common, ", ")

  defp note("text", %{"words" => []}), do: "no words in it say what it is about"

  defp note("text", %{"common_words" => [_ | _] = common}),
    do: "left out as too common: " <> Enum.join(common, ", ")

  defp note("meaning", %{"meaning" => %{"unavailable" => reason}}),
    do: reason <> ", so this search did not run"

  defp note("meaning", %{"meaning" => %{"model" => model}}),
    do: "compared by #{model} in any language"

  defp note(_lane, _receipt), do: nil

  defp result(%{"examined" => 0}),
    do: "Nothing found, so routing had no earlier work to consider."

  # What it found is the routing briefing's Related history (Andrew,
  # 2026-09-28: "why not to call card Search for Related history? so it's
  # obvious").
  defp result(%{"examined" => found, "offered" => found}) when is_integer(found),
    do: "#{found} found, all offered to routing as Related history."

  defp result(%{"offered" => offered, "examined" => examined} = receipt)
       when is_integer(offered) and is_integer(examined) and examined > offered do
    "#{examined} found, #{offered} offered to routing as Related history · " <>
      "#{examined - offered} left out" <>
      cutoff(receipt["cutoff_reason"])
  end

  defp result(_receipt), do: nil

  defp cutoff(reason) when is_binary(reason) and reason != "" do
    text = if String.contains?(reason, " "), do: reason, else: String.replace(reason, "_", " ")
    " (" <> String.downcase(text) <> ")"
  end

  defp cutoff(_reason), do: ""

  defp memory(0), do: nil
  defp memory(1), do: "1 learned topic left out to fit"
  defp memory(count), do: "#{count} learned topics left out to fit"
end
