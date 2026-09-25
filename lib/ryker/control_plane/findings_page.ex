defmodule Ryker.ControlPlane.FindingsPage do
  @moduledoc """
  Findings (`/memory/findings`): the conclusions Ryker saved in its
  investigations, newest first, each with why it holds, the evidence behind
  it, and the way into the investigation that reached it. Ryker writes these
  itself; the page only reads them.
  """
  use Phoenix.Component

  import Ryker.ControlPlane.Components, only: [pager: 1]

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{Kit, MemoryFormat}

  @doc "The query keys the Findings page reads."
  def query_keys, do: ["page"]

  @doc "The Findings body for a `FindingsProjection` page."
  @spec html(map()) :: iodata()
  def html(view), do: %{__changed__: nil, view: view} |> render() |> Safe.to_iodata()

  def render(assigns) do
    ~H"""
    <div class="memory-view memory-findings">
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
        :if={@view.items == []}
        title="No findings yet"
        text="When Ryker investigates a problem, it saves what it concluded here, with the evidence behind it."
      />
      <.pager
        page={@view.page}
        pages={@view.pages}
        path={&"/memory/findings?page=#{&1}"}
        label="Finding pages"
      />
    </div>
    """
  end

  defp state("unexplained"), do: {:warn, "Not explained yet"}
  defp state("explained"), do: {:on, "Explained"}
  defp state("expected"), do: {:off, "Expected"}
  defp state("out_of_scope"), do: {:off, "Out of scope"}
  defp state(_classification), do: nil
end
