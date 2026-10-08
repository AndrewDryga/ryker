defmodule Ryker.ControlPlane.PeoplePage do
  @moduledoc """
  People (`/memory/people`): what Ryker learned about people from what they
  said about themselves, such as a birthday or the name they go by
  (`Ryker.People`). Nobody approves these; this page is where they are seen
  and forgotten.

  The list is one row a person: their name, how many things Ryker knows and
  when they last said one. Each row opens the person's own page (`?person=`):
  one row for each thing Ryker knows, saying where it was said (opening that
  message) and when, with its own Forget (Andrew, 2026-09-30: "add way to
  forget individual facts"), and, last, forgetting all of it. The page
  redraws when a learning pass finishes, as that is when Ryker learns them
  (`subscriptions/0`).
  """
  use Phoenix.Component
  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{Components, Kit, MemoryFormat, Paths, ShortTime}
  alias Ryker.Learning

  @path "/memory/people"

  @doc "The topics an open People page listens to: learning passes, which learn these."
  def subscriptions, do: [{Learning, :subscribe_learning, []}]

  @doc "Where one person's page is."
  @spec path(String.t()) :: String.t()
  def path(person_ref), do: Paths.query(@path, %{"person" => person_ref})

  @doc "The heading of one person's page: their name, how much Ryker knows, and the way back."
  @spec heading(map()) :: map()
  def heading(person) do
    said = "last said " <> ShortTime.text(person.last_said_at, DateTime.utc_now())

    %{
      title: person.name,
      description: things(length(person.facts)) <> " · " <> said,
      back: {"All people", @path}
    }
  end

  # Where forgetting one thing Ryker knows about someone asks first.
  @spec forget_fact_path(String.t()) :: String.t()
  defp forget_fact_path(fact_id), do: "/actions/person-fact/#{fact_id}/forget"

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

  # One person: a row for each thing Ryker knows, in their words, where and
  # when they said it (opening that message), and a Forget of its own; then
  # forgetting all of it.
  defp person(assigns) do
    ~H"""
    <div class="memory-view memory-person-page">
      <section id="known" class="memory-section">
        <Kit.section_head
          title="What they said about themselves"
          lede="Ryker uses these only when this person is the one asking, and doesn't share them with anyone else."
        />
        <Kit.entity_list label="What they said about themselves">
          <Kit.entity_row
            :for={fact <- @person.facts}
            id={"fact-" <> fact.id}
            icon={icon(fact.kind)}
            name={fact.text}
            meta={[
              MemoryFormat.link(fact.where || "Open the message", fact.message_href),
              MemoryFormat.time(fact.said_at, "")
            ]}
          >
            <:actions>
              <Components.action_button path={forget_fact_path(fact.id)} label="Forget" />
            </:actions>
          </Kit.entity_row>
        </Kit.entity_list>
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

  # A hint of what kind of thing it is, from the kind learning named: a
  # birthday is a reminder, a name a label, how they like to be written to a
  # conversation. The words themselves say the rest.
  defp icon(kind) when is_binary(kind) do
    cond do
      String.contains?(kind, "birthday") -> :bell
      String.contains?(kind, "name") -> :tag
      String.contains?(kind, ["time-zone", "timezone", "hours"]) -> :clock
      String.contains?(kind, ["communication", "language", "writing", "reply"]) -> :chat
      true -> :smile
    end
  end

  defp icon(_kind), do: :smile

  defp things(1), do: "1 thing"
  defp things(count), do: "#{count} things"

  # Asking first, then back to all people (`Ryker.ControlPlane.Router`).
  defp action_path(person_ref), do: Paths.action("person", person_ref, "forget")
end
