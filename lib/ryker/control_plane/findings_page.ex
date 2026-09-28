defmodule Ryker.ControlPlane.FindingsPage do
  @moduledoc """
  Findings (`/memory/findings`): the conclusions Ryker saved in its
  investigations, newest first, each with why it holds, the evidence behind
  it, and the way into the investigation that reached it. Ryker writes these
  itself. A person can mark one Ryker could not explain as explained, or
  forget one that is wrong; either asks first and stops Ryker using it
  (`Ryker.Records.Findings`). The page redraws when a finding is written or
  changes (`subscriptions/0`).
  """
  use Phoenix.Component

  import Ryker.ControlPlane.Components, only: [action_button: 1, filter_toolbar: 1, pager: 1]

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{Kit, MemoryFormat}
  alias Ryker.Records

  @doc """
  The topics an open Findings page listens to, as the context functions that
  subscribe to them (`Ryker.ControlPlane.WorkbenchLive`): the records
  investigations write, findings among them.
  """
  def subscriptions, do: [{Records, :subscribe_records, []}]

  @doc "The query keys the Findings page reads."
  def query_keys, do: ["page", "q"]

  @doc "The Findings body for a `FindingsProjection` page."
  @spec html(map()) :: iodata()
  def html(view), do: %{__changed__: nil, view: view} |> render() |> Safe.to_iodata()

  def render(assigns) do
    assigns = assign(assigns, :q, Map.get(assigns.view, :q, ""))

    ~H"""
    <div class="memory-view memory-findings">
      <Kit.counts label="Findings" items={counts(@view, @q)} />
      <Kit.toolbar :if={@view.total > 0 or @q != ""}>
        <.filter_toolbar
          id="findings-search"
          path="/memory/findings"
          label="Search findings"
          placeholder="Search findings"
          query={@q}
          filtered={@q != ""}
        />
      </Kit.toolbar>
      <Kit.entity_list :if={@view.items != []} label="Findings">
        <Kit.entity_row
          :for={item <- @view.items}
          id={"finding-" <> item.id}
          icon={:search}
          name={MemoryFormat.inline(item.what)}
          state={state(item)}
          text={MemoryFormat.inline(item.reason)}
          meta={[
            item.scope,
            MemoryFormat.time(item.at),
            MemoryFormat.link("Open investigation", item.path)
          ]}
        >
          <:details :if={item.evidence != []}>
            <details class="memory-details memory-evidence">
              <summary>
                {MemoryFormat.count(length(item.evidence), "piece of evidence", "pieces of evidence")}
              </summary>
              <ul>
                <li :for={evidence <- item.evidence}>
                  <span>{MemoryFormat.inline(evidence.text)}</span>
                  <a :if={evidence.path} href={evidence.path}>{evidence.label}</a>
                </li>
              </ul>
            </details>
          </:details>
          <:actions :if={item[:status] == :open}>
            <.action_button
              :if={item.classification == "unexplained"}
              path={action_path(item.id, "mark-explained")}
              label="Mark explained"
            />
            <.action_button path={action_path(item.id, "forget")} label="Forget" />
          </:actions>
        </Kit.entity_row>
      </Kit.entity_list>
      <Kit.empty
        :if={@view.items == [] and @q != ""}
        icon={:search}
        title={"No findings match “#{@q}”"}
        text="Try other words, or clear the search to see every finding."
      />
      <Kit.empty
        :if={@view.items == [] and @q == ""}
        icon={:book}
        title="No findings yet"
        text="When Ryker investigates a problem, it saves what it concluded here, with the evidence behind it."
      />
      <.pager
        page={@view.page}
        pages={@view.pages}
        path={&page_path(@q, &1)}
        label="Finding pages"
      />
    </div>
    """
  end

  # How many findings the list holds, then how many are not explained yet.
  defp counts(view, q) do
    unexplained = Map.get(view, :unexplained, 0)

    [
      Kit.list_total(view.total, {"finding", "findings"}, q != ""),
      unexplained > 0 &&
        %{value: unexplained, label: "not explained yet", tone: :warn}
    ]
    |> Enum.filter(& &1)
  end

  defp page_path("", page), do: "/memory/findings?page=#{page}"

  defp page_path(q, page),
    do: "/memory/findings?" <> URI.encode_query(%{"q" => q, "page" => page})

  defp action_path(id, action), do: "/actions/finding/#{id}/#{action}"

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
end
