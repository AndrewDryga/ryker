defmodule Ryker.ControlPlane.CasesPage do
  @moduledoc """
  Cases (`/memory/cases`): what Ryker kept of finished work, newest first. When
  a request's history is cleaned up, Ryker keeps a short case of it: the
  problem, the cause it found, what it checked and how it ended, and a later
  request about the same problem reads it (`Ryker.Memories.Cases`). The list is
  one line a case; each row opens the case's own page (`?case=`), whose last
  card forgets it after asking first. Nobody could delete a kept case before
  this page (2026-10-04 review).
  """
  use Phoenix.Component
  import Ryker.ControlPlane.Components, only: [filter_toolbar: 1, pager: 1]
  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{Kit, MemoryFormat, Paths}
  alias Ryker.Memories
  alias Ryker.Slack

  @path "/memory/cases"
  # A problem runs to a few hundred characters; a row shows its start.
  @row_characters 160

  @doc """
  The topics an open Cases page listens to, as the context functions that
  subscribe to them (`Ryker.ControlPlane.WorkbenchLive`): a case kept or
  forgotten is announced as a memory change.
  """
  def subscriptions, do: [{Memories, :subscribe_memories, []}]

  @doc "The query keys the Cases page reads."
  def query_keys, do: ["page", "q"]

  @doc "Where one case's page is, by the id of the work it was kept from."
  @spec path(String.t()) :: String.t()
  def path(id), do: Paths.query(@path, %{"case" => id})

  @doc "The heading of one case's page: the start of its problem, and the way back."
  @spec heading(map()) :: map()
  def heading(item),
    do: %{
      title: MemoryFormat.excerpt(item.problem, Slack.workspace(), 90),
      description: nil,
      back: {"All cases", @path}
    }

  @doc "The Cases body for a `CasesProjection.list/1` view."
  @spec html(map()) :: iodata()
  def html(view), do: %{__changed__: nil, view: view} |> render() |> Safe.to_iodata()

  @doc "One case's page body, for a `CasesProjection.fetch/1` case."
  @spec case_html(map()) :: iodata()
  def case_html(item), do: %{__changed__: nil, item: item} |> case_page() |> Safe.to_iodata()

  def render(assigns) do
    assigns = assign(assigns, :q, Map.get(assigns.view, :q, ""))

    ~H"""
    <div class="memory-view memory-cases">
      <Kit.counts
        label="Cases"
        items={[Kit.list_total(@view.total, {"case", "cases"}, @q != "")]}
      />
      <Kit.toolbar :if={@view.total > 0 or @q != ""}>
        <.filter_toolbar
          id="cases-search"
          path={path_for("", nil)}
          label="Search cases"
          placeholder="Search cases"
          query={@q}
          filtered={@q != ""}
        />
      </Kit.toolbar>
      <Kit.entity_list :if={@view.items != []} label="Cases">
        <Kit.entity_row
          :for={item <- @view.items}
          id={"case-" <> item.id}
          icon={:book}
          name={row_text(item.problem)}
          href={path(item.id)}
          link_row
          meta={meta(item)}
        />
      </Kit.entity_list>
      <Kit.empty
        :if={@view.items == [] and @q != ""}
        icon={:search}
        title={"No cases match \"#{@q}\""}
        text="Try other words, or clear the search to see every case."
      />
      <Kit.empty
        :if={@view.items == [] and @q == ""}
        icon={:book}
        title="No cases yet"
        text="When a finished request's history is cleaned up, Ryker keeps its problem, the cause it found and how it ended. Later requests about the same problem read it."
      />
      <.pager page={@view.page} pages={@view.pages} path={&path_for(@q, &1)} label="Case pages" />
    </div>
    """
  end

  # One case: when it ended, the problem, the cause and how it ended, what
  # Ryker checked and the links it kept, then forgetting it, last.
  defp case_page(assigns) do
    ~H"""
    <div class="memory-view memory-case-page">
      <article class="memory-topic memory-case" id={"case-" <> @item.id}>
        <Kit.status_line id="case-status" state={state(@item)}>
          <span>{MemoryFormat.time(@item.at, "ended ")}</span>
        </Kit.status_line>
        <div class="memory-topic-text">{MemoryFormat.inline(@item.problem)}</div>
        <Kit.facts :if={not @item.forgotten?} id="case-facts" facts={facts(@item)} />
      </article>
      <section :if={@item.checked != []} id="case-checked" class="memory-section">
        <Kit.section_head title="What Ryker checked" lede="The sources the work read and cited." />
        <div class="entity-list" role="list" aria-label="What Ryker checked">
          <MemoryFormat.row
            :for={{checked, index} <- Enum.with_index(@item.checked, 1)}
            id={"case-checked-#{index}"}
            name={MemoryFormat.inline(checked)}
          />
        </div>
      </section>
      <section :if={@item.links != []} id="case-links" class="memory-section">
        <Kit.section_head title="Links" lede="Where the work and its sources were." />
        <div class="entity-list" role="list" aria-label="Links">
          <MemoryFormat.row
            :for={{link, index} <- Enum.with_index(@item.links, 1)}
            id={"case-link-#{index}"}
            name={MemoryFormat.link(link, link)}
          />
        </div>
      </section>
      <Kit.remove_card
        :if={not @item.forgotten?}
        id="forget-case"
        title="Forget case"
        text="Ryker erases its words, and later requests no longer read it. That it was kept stays, marked forgotten."
        path={Paths.action("case", @item.ref, "forget")}
      />
    </div>
    """
  end

  defp facts(item) do
    [
      {"Cause", if(item.cause, do: MemoryFormat.inline(item.cause), else: "Not found")},
      {"How it ended", if(item.outcome, do: MemoryFormat.inline(item.outcome), else: "Not said")},
      {"Where", item.where},
      item.repository && {"Repository", item.repository}
    ]
    |> Enum.filter(& &1)
  end

  defp meta(item),
    do: Enum.filter([item.where, item.shadow? && "Shadow mode", MemoryFormat.time(item.at)], & &1)

  defp state(%{forgotten?: true}),
    do: {:off, "Forgotten", "Someone forgot this case. Its words are erased."}

  defp state(%{shadow?: true}),
    do: {:off, "Shadow mode", "Only requests in shadow mode read this case."}

  defp state(_item), do: {:on, "Kept", "Later requests about the same problem read this case."}

  defp path_for(search, page) do
    [{"q", search}, {"page", page}]
    |> Enum.reject(fn {_key, value} -> value in [nil, "", 1] end)
    |> Paths.encode_query()
    |> case do
      "" -> @path
      query -> @path <> "?" <> query
    end
  end

  defp row_text(problem), do: short(problem, @row_characters)

  # The start of a problem, cut at a word. The limit is in characters, as the
  # cut is.
  defp short(text, limit) when is_binary(text) do
    if String.length(text) > limit do
      cut = text |> String.slice(0, limit) |> String.replace(~r/\s+\S*$/u, "")
      MemoryFormat.inline(cut <> "…")
    else
      MemoryFormat.inline(text)
    end
  end
end
