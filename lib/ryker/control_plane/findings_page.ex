defmodule Ryker.ControlPlane.FindingsPage do
  @moduledoc """
  Findings (`/memory/findings`): the conclusions Ryker saved in its
  investigations, newest first, each with why it holds, the evidence behind
  it, and the way into the investigation that reached it. Ryker writes these
  itself; the page only reads them.
  """
  use Phoenix.Component

  import Ryker.ControlPlane.Components, only: [filter_toolbar: 1, pager: 1]

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{Kit, MemoryFormat}

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
          state={state(item.classification)}
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

  defp state("unexplained"), do: {:warn, "Not explained yet"}
  defp state("explained"), do: {:on, "Explained"}
  defp state("expected"), do: {:off, "Expected"}
  defp state("out_of_scope"), do: {:off, "Out of scope"}
  defp state(_classification), do: nil
end
