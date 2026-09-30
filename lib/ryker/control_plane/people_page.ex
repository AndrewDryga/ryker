defmodule Ryker.ControlPlane.PeoplePage do
  @moduledoc """
  People (`/memory/people`): what Ryker learned about people from what they
  said about themselves, such as a birthday or the name they go by
  (`Ryker.People`). Nobody approves these; this page is where they are seen
  and forgotten.

  The list is one row a person: their name, how many things Ryker knows and
  when they last said one. Each row opens the person's own page (`?person=`)
  with what Ryker knows, each opening the message it came from, and, last,
  forgetting all of it. The page redraws when a learning pass finishes, as
  that is when Ryker learns them (`subscriptions/0`).
  """
  use Phoenix.Component

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{Kit, MemoryFormat}
  alias Ryker.Learning

  @path "/memory/people"

  @doc "The topics an open People page listens to: learning passes, which learn these."
  def subscriptions, do: [{Learning, :subscribe_learning, []}]

  @doc "Where one person's page is."
  @spec path(String.t()) :: String.t()
  def path(person_ref), do: @path <> "?" <> URI.encode_query(%{"person" => person_ref})

  @doc "The heading of one person's page: their name, and the way back."
  @spec heading(map()) :: map()
  def heading(person), do: %{title: person.name, description: nil, back: {"All people", @path}}

  @doc "The People body for a `PeopleProjection.list/0` view."
  @spec html(map()) :: iodata()
  def html(view), do: %{__changed__: nil, view: view} |> render() |> Safe.to_iodata()

  @doc "One person's page body, for a `PeopleProjection.fetch/1` person."
  @spec person_html(map()) :: iodata()
  def person_html(person),
    do: %{__changed__: nil, person: person} |> person() |> Safe.to_iodata()

  def render(assigns) do
    ~H"""
    <div class="memory-view memory-people">
      <Kit.counts
        :if={@view.people != []}
        label="People"
        items={[Kit.list_total(length(@view.people), {"person", "people"}, false)]}
      />
      <Kit.entity_list :if={@view.people != []} label="People">
        <Kit.entity_row
          :for={person <- @view.people}
          id={"person-" <> Integer.to_string(:erlang.phash2(person.person_ref))}
          icon={:smile}
          name={person.name}
          href={path(person.person_ref)}
          link_row
          navigate
          meta={[things(person.facts), MemoryFormat.time(person.last_said_at, "last said ")]}
        />
      </Kit.entity_list>
      <Kit.empty
        :if={@view.people == []}
        icon={:smile}
        title="Nobody yet"
        text="When someone mentions something about themselves, such as their birthday or the name they go by, Ryker keeps it here and uses it to be considerate to them."
      />
    </div>
    """
  end

  # One person: what Ryker knows, each opening the message it came from,
  # then forgetting all of it.
  defp person(assigns) do
    ~H"""
    <div class="memory-view memory-person-page">
      <section id="known" class="memory-section">
        <Kit.section_head
          title="What they said about themselves"
          lede="Ryker uses these only when this person is the one asking, and never shares them with anyone else."
        />
        <div class="entity-list" role="list" aria-label="What they said about themselves">
          <MemoryFormat.row
            :for={fact <- @person.facts}
            id={"fact-" <> fact.id}
            name={fact.text}
            meta={[
              MemoryFormat.link("Open the message", fact.message_href),
              fact.where,
              MemoryFormat.time(fact.said_at, "said ")
            ]}
          />
        </div>
      </section>
      <Kit.remove_card
        id="forget-person"
        title="Forget this person"
        text="Ryker stops using everything it learned about them, and nothing they said before brings it back. What they say about themselves later is learned again."
        path={action_path(@person.person_ref)}
      />
    </div>
    """
  end

  defp things(1), do: "1 thing"
  defp things(count), do: "#{count} things"

  # Asking first, then back to all people (`Ryker.ControlPlane.Router`).
  defp action_path(person_ref),
    do: "/actions/person/#{URI.encode(person_ref, &URI.char_unreserved?/1)}/forget"
end
