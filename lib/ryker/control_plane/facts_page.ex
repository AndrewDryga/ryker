defmodule Ryker.ControlPlane.FactsPage do
  @moduledoc """
  Facts (`/memory`): what people told Ryker to remember, one row each with
  where it applies and how often Ryker used it, then the saved facts that may
  be out of date or saved twice, each with the reviewed actions that settle it.

  Every action is the existing two-step one: its button opens a confirmation
  page that says what will happen, and only that page's protected POST acts.
  """
  use Phoenix.Component

  import Ryker.ControlPlane.Components, only: [action_button: 1, filter_toolbar: 1]

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{InspectionRedactor, Kit, MemoryFormat, MemoryProjection, SlackNames}

  @doc "The query keys the Facts page reads."
  def query_keys, do: MemoryProjection.query_keys()

  @doc "The Facts body for a `MemoryProjection` snapshot and the page's query."
  @spec html(map(), map()) :: iodata()
  def html(snapshot, params \\ %{}) do
    %{__changed__: nil, view: view(snapshot, params)}
    |> render()
    |> Safe.to_iodata()
  end

  def render(assigns) do
    ~H"""
    <div class="memory-view memory-facts">
      <div :if={@view.review_summary} class="memory-callout">
        <span>{@view.review_summary}</span>
        <a class="ui-button secondary" href="#review">Review</a>
      </div>
      <Kit.toolbar :if={@view.total > 0}>
        <.filter_toolbar
          id="facts-search"
          path="/memory"
          label="Search facts"
          placeholder="Search facts"
          query={@view.q}
          filtered={@view.q != ""}
        />
      </Kit.toolbar>
      <Kit.entity_list :if={@view.facts != []} label="Facts">
        <Kit.entity_row
          :for={fact <- @view.facts}
          id={fact.id}
          icon={:book}
          name={fact.name}
          text={fact.text}
          meta={fact.meta}
        >
          <:actions><.action_button path={fact.forget} label="Forget" /></:actions>
        </Kit.entity_row>
      </Kit.entity_list>
      <Kit.empty
        :if={@view.facts == [] and @view.q != ""}
        title={"No facts match “#{@view.q}”"}
        text="Try other words, or clear the search to see every fact."
      />
      <Kit.empty
        :if={@view.total == 0}
        title="No facts yet"
        text="A fact appears here after someone asks Ryker to remember something and confirms what it proposes to save."
      />
      <Kit.ask_hint
        lead="To add a fact, tell Ryker in chat or Slack:"
        example="Remember that pay-gw is the payments gateway."
        rest="It saves the fact after you confirm."
      />
      <section :if={@view.reviews != []} id="review" class="memory-section">
        <Kit.section_head
          title="Needs review"
          lede="Ryker has not used these in a while, or has the same fact saved more than once. Keep, change or forget each one."
        />
        <Kit.entity_list label="Facts that need review">
          <Kit.entity_row
            :for={review <- @view.reviews}
            id={review.id}
            name={review.name}
            state={review.state}
            text={review.text}
            meta={review.meta}
          >
            <:details :if={review.entries != []}>
              <ul class="memory-review-entries">
                <li :for={entry <- review.entries}>
                  <strong>{entry.subject}</strong>
                  <span :if={entry.value}>{entry.value}</span>
                  <MemoryFormat.facts facts={entry.meta} />
                </li>
              </ul>
            </:details>
            <:actions>
              <.action_button :for={{label, path} <- review.actions} path={path} label={label} />
            </:actions>
          </Kit.entity_row>
        </Kit.entity_list>
      </section>
    </div>
    """
  end

  @doc """
  The form that corrects one stale fact in place: what it is about and what
  Ryker should remember, each with one line of help, then Save changes and
  Cancel. Its POST is bound to the review by `token`.
  """
  @spec edit_form(map(), String.t(), String.t()) :: iodata()
  def edit_form(%{"entries" => [entry | _]}, action, token) do
    assigns = %{__changed__: nil, entry: entry, action: action, token: token}

    ~H"""
    <form class="memory-edit" method="post" action={@action}>
      <input type="hidden" name="_token" value={@token} />
      <p class="memory-edit-lede">
        Ryker has not used this fact in a while. Correct it if it changed; Ryker uses the new words from now on.
      </p>
      <div class="memory-edit-field">
        <label for="memory-edit-subject">What it is about</label>
        <p id="memory-edit-subject-help">
          A short name people use for it, such as a service or a system.
        </p>
        <input
          id="memory-edit-subject"
          name="subject"
          maxlength="120"
          required
          value={@entry["subject"]}
          aria-describedby="memory-edit-subject-help"
        />
      </div>
      <div class="memory-edit-field">
        <label for="memory-edit-value">What to remember</label>
        <p id="memory-edit-value-help">
          Ryker uses this as context in later work, never as permission.
        </p>
        <textarea
          id="memory-edit-value"
          name="value"
          maxlength="4000"
          required
          aria-describedby="memory-edit-value-help"
        >{@entry["value"]}</textarea>
      </div>
      <div class="memory-edit-actions">
        <button type="submit" class="ui-button primary">Save changes</button>
        <a class="ui-button secondary" href="/memory#review">Cancel</a>
      </div>
    </form>
    """
    |> Safe.to_iodata()
  end

  defp view(snapshot, params) do
    facts = Map.get(snapshot, :memories, [])
    reviews = Map.get(snapshot, :reviews, [])

    %{
      q: Map.get(snapshot, :q) || search_text(params["q"]),
      total: Map.get(snapshot, :memory_total, length(facts)),
      facts: Enum.map(facts, &fact/1),
      reviews: Enum.map(reviews, &review/1),
      review_summary: review_summary(reviews)
    }
  end

  defp fact(item) do
    %{
      id: "fact-" <> dom_id(item.ref),
      name: item.subject,
      text: item.value,
      meta: [
        where(item[:scope], item[:scope_ref]),
        applies_to(item[:applicability]),
        kind(item[:kind]),
        uses(item[:recall_count], nil),
        MemoryFormat.time(item[:confirmed_at], "Saved ")
      ],
      forget: "/actions/memory/#{segment(item.ref)}/forget"
    }
  end

  # A review names what it is about, why it is here and the actions that
  # settle it. One stale fact reads like a fact; facts saved twice list each
  # copy so a person can tell whether they really say the same thing.
  defp review(%{"kind" => kind, "review_ref" => ref} = review) do
    secrets = InspectionRedactor.configured_secrets()
    entries = Enum.map(review["entries"] || [], &entry(&1, secrets))
    base = %{id: "review-" <> dom_id(ref), actions: actions(kind, entries, segment(ref))}

    case {kind, entries} do
      {"stale", [entry]} ->
        Map.merge(base, %{
          name: entry.subject,
          state: {:warn, "May be out of date"},
          text: entry.value,
          meta: entry.meta,
          entries: []
        })

      {"duplicate", _entries} ->
        Map.merge(base, %{
          name: subjects(entries),
          state: {:warn, "Saved more than once"},
          text: nil,
          meta: [MemoryFormat.count(length(entries), "copy", "copies")],
          entries: entries
        })

      _other ->
        Map.merge(base, %{
          name: subjects(entries),
          state: {:warn, "Needs review"},
          text: review["reason"],
          meta: [],
          entries: entries
        })
    end
  end

  defp entry(entry, secrets) do
    %{
      subject: redact(entry["subject"], secrets) || "Untitled",
      value: redact(entry["value"], secrets),
      meta: [
        where(entry["scope"], entry["scope_ref"]),
        kind(entry["kind"]),
        uses(entry["recall_count"], entry["last_recalled_at"]),
        MemoryFormat.time(entry["confirmed_at"], "Saved ")
      ]
    }
  end

  defp actions("duplicate", _entries, ref),
    do: [
      {"Keep separate", "/actions/memory-review/#{ref}/keep"},
      {"Merge", "/actions/memory-review/#{ref}/merge"},
      {"Forget", "/actions/memory-review/#{ref}/forget"}
    ]

  # Only one stale fact can be corrected in place; the router refuses any other.
  defp actions("stale", [_entry], ref),
    do: [
      {"Keep", "/actions/memory-review/#{ref}/keep"},
      {"Edit", "/actions/memory-review/#{ref}/edit"},
      {"Forget", "/actions/memory-review/#{ref}/forget"}
    ]

  defp actions(_kind, _entries, ref),
    do: [
      {"Keep", "/actions/memory-review/#{ref}/keep"},
      {"Forget", "/actions/memory-review/#{ref}/forget"}
    ]

  defp subjects([]), do: "Saved facts"
  defp subjects([entry]), do: entry.subject

  defp subjects(entries) do
    {rest, [last]} = Enum.split(Enum.map(entries, & &1.subject), -1)
    Enum.join(rest, ", ") <> " and " <> last
  end

  # One sentence over every pending review: how many saved things it covers
  # and what may be wrong with them, in the words the rows below use.
  defp review_summary([]), do: nil

  defp review_summary(reviews) do
    entries =
      reviews
      |> Enum.flat_map(&(&1["entries"] || []))
      |> Enum.uniq_by(& &1["memory_ref"])

    count = max(length(entries), length(reviews))
    kinds = reviews |> Enum.map(& &1["kind"]) |> MapSet.new()

    noun =
      if Enum.all?(entries, &(&1["source_type"] in [nil, "memory"])),
        do: MemoryFormat.count(count, "fact", "facts"),
        else: MemoryFormat.count(count, "saved item", "saved items")

    problem =
      cond do
        MapSet.equal?(kinds, MapSet.new(["stale"])) -> "out of date"
        MapSet.equal?(kinds, MapSet.new(["duplicate"])) -> "saved more than once"
        true -> "out of date or saved more than once"
      end

    "#{noun} may be #{problem}."
  end

  defp where(scope, _ref) when scope in [:global, "global"], do: "Everywhere"
  defp where(scope, _ref) when scope in [:workspace, "workspace"], do: "Across the workspace"

  defp where(scope, ref) when scope in [:repository, "repository"] and is_binary(ref),
    do: MemoryFormat.with_ref("For ", ref)

  defp where(scope, ref) when scope in [:conversation, "conversation"] and is_binary(ref),
    do: MemoryFormat.with_ref("In ", SlackNames.destination(ref))

  defp where(_scope, _ref), do: nil

  defp applies_to(text) when is_binary(text) and text != "", do: "Applies to " <> text
  defp applies_to(_text), do: nil

  # A plain fact is what this page lists, so only the special kinds say so.
  defp kind(kind) when kind in [:alias, "alias"], do: "Another name"
  defp kind(kind) when kind in [:repository_binding, "repository_binding"], do: "Repository link"
  defp kind(kind) when kind in [:evidence_route, "evidence_route"], do: "Where to look"
  defp kind("guidance"), do: "Guidance"
  defp kind(_kind), do: nil

  defp uses(count, _last) when count in [nil, 0], do: "Not used yet"
  defp uses(1, last), do: last_use("Used once", last)
  defp uses(count, last) when is_integer(count), do: last_use("Used #{count} times", last)
  defp uses(_count, _last), do: nil

  defp last_use(words, nil), do: words

  defp last_use(words, last) do
    case MemoryFormat.time(last, ", last ") do
      {:safe, time} -> {:safe, [Plug.HTML.html_escape(words), time]}
      nil -> words
    end
  end

  defp redact(nil, _secrets), do: nil
  defp redact(text, secrets), do: InspectionRedactor.artifact(text, secrets: secrets).text

  defp search_text(value) when is_binary(value), do: String.slice(String.trim(value), 0, 200)
  defp search_text(_value), do: ""

  defp dom_id(ref), do: String.replace(to_string(ref), ~r/[^A-Za-z0-9_-]/, "-")
  defp segment(value), do: value |> to_string() |> URI.encode(&URI.char_unreserved?/1)
end
