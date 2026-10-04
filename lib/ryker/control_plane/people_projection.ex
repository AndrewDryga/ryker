defmodule Ryker.ControlPlane.PeopleProjection do
  @moduledoc """
  Memory › People (`Ryker.ControlPlane.PeoplePage`): everyone Ryker learned
  something about from what they said about themselves (`Ryker.People`),
  and, for one person, what it learned and where they said it.
  """

  alias Ryker.ControlPlane.{ConsolePeople, Paths}
  alias Ryker.People
  alias Ryker.Slack.Names

  @doc "Everyone Ryker knows something about, most recently heard first."
  @spec list() :: %{people: [map()]}
  def list do
    %{
      people:
        Enum.map(People.people(), fn person ->
          %{
            person_ref: person.person_ref,
            name: name(person.person_ref, person.conversation_ref),
            facts: person.facts,
            last_said_at: person.last_said_at
          }
        end)
    }
  end

  @doc "What Ryker knows about one person, or :error when it knows nothing."
  @spec fetch(String.t()) :: {:ok, map()} | :error
  def fetch(person_ref) when is_binary(person_ref) do
    case People.facts(person_ref) do
      [] ->
        :error

      [first | _rest] = facts ->
        {:ok,
         %{
           person_ref: person_ref,
           name: name(person_ref, first.conversation_ref),
           facts: Enum.map(facts, &fact/1),
           last_said_at: facts |> Enum.map(& &1.said_at) |> Enum.max(DateTime)
         }}
    end
  end

  def fetch(_person_ref), do: :error

  @doc """
  One thing Ryker knows, to forget on its own: what was said, whose it is, and
  whether they would have anything left.
  """
  @spec fetch_fact(String.t()) :: {:ok, map()} | :error
  def fetch_fact(fact_id) when is_binary(fact_id) do
    with {:ok, id} <- Ecto.UUID.cast(fact_id),
         %{status: :kept} = fact <- People.get_fact(id) do
      {:ok,
       %{
         id: fact.id,
         text: fact.fact,
         person_ref: fact.person_ref,
         others: length(People.facts(fact.person_ref)) - 1
       }}
    else
      _unknown -> :error
    end
  end

  def fetch_fact(_fact_id), do: :error

  defp fact(fact) do
    %{
      id: fact.id,
      kind: fact.key,
      text: fact.fact,
      said_at: fact.said_at,
      where: where(fact.conversation_ref, fact.private),
      message_href: Paths.request(fact.source_input_id)
    }
  end

  # Where it was said, by the channel's name, and so where Ryker uses it: the
  # page said "Said in a channel everyone can read" under every fact.
  defp where("slack:" <> _rest = conversation_ref, private) do
    case String.split(conversation_ref, ":", parts: 3) do
      ["slack", _workspace, "D" <> _direct] ->
        "Said in a direct message, used only there"

      ["slack", workspace, channel] ->
        "Said in " <>
          Names.name(workspace, channel) <> if(private, do: ", used only there", else: "")

      _other ->
        if private, do: "Used only where it was said"
    end
  end

  defp where("control-plane:" <> _rest, _private), do: "Said in Chat"
  defp where(_conversation_ref, true), do: "Used only where it was said"
  defp where(_conversation_ref, false), do: nil

  # A person the way every page names them: "@Name" once Slack said it.
  defp name("slack:user:" <> _id = person_ref, conversation_ref) do
    case Names.workspace_from_destination(conversation_ref) do
      nil -> "Slack user"
      workspace -> Names.person(workspace, person_ref).name
    end
  end

  # Someone in Chat, by the name their sign-in gave them; the local console is "You".
  defp name("control_plane:user:" <> _id = person_ref, _conversation_ref),
    do: (ConsolePeople.person(person_ref) || %{name: "Someone"}).name

  defp name("github:user:" <> _id, _conversation_ref), do: "GitHub user"
  defp name(_person_ref, _conversation_ref), do: "Someone"
end
