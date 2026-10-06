defmodule Ryker.ControlPlane.FindingsPage do
  @moduledoc """
  Findings (`/memory/findings`): the conclusions Ryker saved in its
  investigations, newest first. Ryker writes these itself. A person can mark
  one Ryker could not explain as explained, or forget one that is wrong;
  either asks first and stops Ryker using it (`Ryker.Records.Findings`). The
  page redraws when a finding is written or changes (`subscriptions/0`).

  Andrew, 2026-09-28: the list was "REALLY heavy, too much text and nobody
  will be able to use it", with a collapsible in every row, and it needed "a
  toggle filter to see only explained, unexplained, etc". The list is one
  line a finding (its conclusion, how it stands, its scope and when) under a
  toggle of the views it has; each row opens the finding's own page
  (`?finding=`), with the whole conclusion, why, the evidence behind it, the
  investigation, and what a person can do.
  """
  use Phoenix.Component

  import Ryker.ControlPlane.Components, only: [action_button: 1, filter_toolbar: 1, pager: 1]

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{FindingsProjection, Kit, MemoryFormat, Paths}
  alias Ryker.Records
  alias Ryker.Slack.Names

  @path "/memory/findings"
  # A conclusion runs to a few hundred characters; a row shows its start.
  @row_characters 160

  @doc """
  The topics an open Findings page listens to, as the context functions that
  subscribe to them (`Ryker.ControlPlane.WorkbenchLive`): the records
  investigations write, findings among them.
  """
  def subscriptions, do: [{Records, :subscribe_records, []}]

  @doc "The query keys the Findings page reads."
  def query_keys, do: ["page", "q", "view"]

  @doc "Where one finding's page is."
  @spec path(String.t()) :: String.t()
  def path(id), do: Paths.query(@path, %{"finding" => id})

  @doc """
  The heading of one finding's page: the start of its conclusion as plain text,
  which the browser shows as the page title too, and the way back.
  """
  @spec heading(map()) :: map()
  def heading(finding),
    do: %{
      title: MemoryFormat.excerpt(finding.what, Names.workspace(), 90),
      description: nil,
      back: {"All findings", @path}
    }

  @doc "The Findings body for a `FindingsProjection.list/1` view."
  @spec html(map()) :: iodata()
  def html(view), do: %{__changed__: nil, view: view} |> render() |> Safe.to_iodata()

  @doc "One finding's page body, for a `FindingsProjection.fetch/1` finding."
  @spec finding_html(map()) :: iodata()
  def finding_html(finding),
    do: %{__changed__: nil, item: finding} |> finding() |> Safe.to_iodata()

  def render(assigns) do
    assigns =
      assigns
      |> assign(:q, Map.get(assigns.view, :q, ""))
      |> assign(:selected, Map.get(assigns.view, :view))

    ~H"""
    <div class="memory-view memory-findings">
      <Kit.counts label="Findings" items={counts(@view, @q, @selected)} />
      <Kit.toolbar :if={@view.total > 0 or @q != "" or @selected}>
        <.filter_toolbar
          id="findings-search"
          path={path_for(nil, "", nil)}
          label="Search findings"
          placeholder="Search findings"
          query={@q}
          filtered={@q != ""}
          hidden={if @selected, do: [{"view", @selected}], else: []}
          clear={if @selected, do: path_for(@selected, "", nil)}
        />
        <Kit.segmented
          :if={views(@view, @q, @selected) != []}
          label="Which findings"
          options={views(@view, @q, @selected)}
          patch
        />
      </Kit.toolbar>
      <Kit.entity_list :if={@view.items != []} label="Findings">
        <Kit.entity_row
          :for={item <- @view.items}
          id={"finding-" <> item.id}
          icon={:search}
          name={row_text(item.what)}
          href={path(item.id)}
          link_row
          state={state(item)}
          meta={[item.scope, MemoryFormat.time(item.at)]}
        />
      </Kit.entity_list>
      <Kit.empty
        :if={@view.items == [] and @q != ""}
        icon={:search}
        title={"No findings match \"#{@q}\""}
        text="Try other words, or clear the search to see every finding."
      />
      <Kit.empty
        :if={@view.items == [] and @q == "" and is_nil(@selected)}
        icon={:book}
        title="No findings yet"
        text="When Ryker investigates a problem, it saves what it concluded here, with the evidence behind it."
      />
      <Kit.empty
        :if={@view.items == [] and @q == "" and not is_nil(@selected)}
        icon={:book}
        title={"No findings are #{String.downcase(view_label(@selected))}"}
        text="Choose All to see every finding."
      />
      <.pager
        page={@view.page}
        pages={@view.pages}
        path={&path_for(@selected, @q, &1)}
        label="Finding pages"
      />
    </div>
    """
  end

  # One finding: how it stands, the whole conclusion and why, where it
  # applies, the evidence behind it, then what a person can do, forgetting
  # last.
  defp finding(assigns) do
    ~H"""
    <%!-- Inside the memory view like a topic's page: a section straight under
    the page was boxed by the secondary pages' rule, with 52px of empty space
    above Evidence (Andrew, 2026-09-28). --%>
    <div class="memory-view memory-finding-page">
      <article class="memory-topic memory-finding" id={"finding-" <> @item.id}>
        <Kit.status_line id="finding-status" state={state(@item) || unclassified()}>
          <span>{MemoryFormat.time(@item.at, "found ")}</span>
        </Kit.status_line>
        <div class="memory-topic-text">{MemoryFormat.inline(@item.what)}</div>
        <Kit.facts
          id="finding-facts"
          facts={[
            {"Why", MemoryFormat.inline(@item.reason)},
            {"Scope", @item.scope},
            {"Investigation", MemoryFormat.link("Open the investigation", @item.path)}
          ]}
        />
      </article>
      <section :if={@item.evidence != []} id="evidence" class="memory-section">
        <Kit.section_head
          title="Evidence"
          lede="What Ryker saw that this conclusion rests on."
        />
        <div class="entity-list" role="list" aria-label="Evidence">
          <MemoryFormat.row
            :for={{evidence, index} <- Enum.with_index(@item.evidence, 1)}
            id={"evidence-#{index}"}
            name={MemoryFormat.inline(evidence.text)}
            meta={[MemoryFormat.link(evidence.label, evidence.path)]}
          />
        </div>
      </section>
      <section
        :if={@item.status == :open and @item.classification == "unexplained"}
        id="mark-explained"
        class="kit-card"
        aria-label="Mark explained"
      >
        <Kit.section_head
          title="Mark explained"
          lede="When you know why it happened. Ryker then stops bringing it up as an open question."
        >
          <:actions>
            <.action_button
              path={action_path(@item.id, "mark-explained")}
              label="Mark explained"
              tone={:primary}
            />
          </:actions>
        </Kit.section_head>
      </section>
      <Kit.remove_card
        :if={@item.status == :open}
        id="forget-finding"
        title="Forget finding"
        text="Ryker stops using it: later requests no longer read it. The investigation keeps it in its history."
        path={action_path(@item.id, "forget")}
      />
    </div>
    """
  end

  # How many findings the list holds, then how many are not explained yet.
  defp counts(view, search, selected) do
    unexplained = Map.get(view, :unexplained, 0)

    [
      Kit.list_total(view.total, {"finding", "findings"}, search != "" or not is_nil(selected)),
      unexplained > 0 && is_nil(selected) &&
        %{
          value: unexplained,
          label: "not explained yet",
          tone: :warn,
          href: path_for("unexplained", search, nil)
        }
    ]
    |> Enum.filter(& &1)
  end

  # All, then each view that has a finding, in a fixed order; the chosen one
  # stays even when a search empties it.
  defp views(view, search, selected) do
    present =
      Enum.filter(
        FindingsProjection.views(),
        &(Map.get(Map.get(view, :views, %{}), &1, 0) > 0 or &1 == selected)
      )

    if present == [] do
      []
    else
      [{"All", path_for(nil, search, nil), is_nil(selected)}] ++
        Enum.map(present, &{view_label(&1), path_for(&1, search, nil), &1 == selected})
    end
  end

  defp view_label("unexplained"), do: "Not explained yet"
  defp view_label("explained"), do: "Explained"
  defp view_label("expected"), do: "Expected"
  defp view_label("out_of_scope"), do: "Out of scope"
  defp view_label("forgotten"), do: "Forgotten"

  defp path_for(view, search, page) do
    [{"view", view}, {"q", search}, {"page", page}]
    |> Enum.reject(fn {_key, value} -> value in [nil, "", 1] end)
    |> Paths.encode_query()
    |> case do
      "" -> @path
      query -> @path <> "?" <> query
    end
  end

  # Asking first, then back to this finding's page (`Ryker.ControlPlane.Router`).
  defp action_path(id, action), do: "/actions/finding/#{id}/#{action}"

  defp row_text(what), do: short(what, @row_characters)

  # The start of a conclusion, cut at a word. The limit is in characters, as
  # the cut is; counting bytes cut short multi-byte text that fitted.
  defp short(text, limit) when is_binary(text) do
    if String.length(text) > limit do
      cut = text |> String.slice(0, limit) |> String.replace(~r/\s+\S*$/u, "")
      MemoryFormat.inline(cut <> "…")
    else
      MemoryFormat.inline(text)
    end
  end

  # What a person settled comes first; otherwise how Ryker classified it. Each
  # says what it means on hover and focus.
  defp state(%{status: :dismissed}),
    do:
      {:off, "Forgotten",
       "Someone forgot this finding, so Ryker no longer uses it. The investigation keeps it in its history."}

  defp state(%{status: :answered}),
    do:
      {:on, "Marked explained",
       "Someone marked this finding explained, so Ryker no longer treats it as an open question."}

  defp state(%{classification: "unexplained"}),
    do: {:warn, "Not explained yet", "Ryker could not say why this happened yet."}

  defp state(%{classification: "explained"}),
    do: {:on, "Explained", "The evidence Ryker cites shows why it happened."}

  defp state(%{classification: "expected"}),
    do: {:off, "Expected", "Ryker's reason says why this is normal."}

  defp state(%{classification: "out_of_scope"}),
    do: {:off, "Out of scope", "Ryker's reason says why it looked no further."}

  defp state(_item), do: nil

  defp unclassified,
    do: {:off, "Not classified", "Ryker saved this without saying how it stands."}
end
