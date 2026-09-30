defmodule Ryker.ControlPlane.PeopleProjection do
  @moduledoc """
  Memory › People (`Ryker.ControlPlane.PeoplePage`): everyone Ryker learned
  something about from what they said about themselves (`Ryker.People`),
  and, for one person, what it learned and where they said it.
  """

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
           facts: Enum.map(facts, &fact/1)
         }}
    end
  end

  def fetch(_person_ref), do: :error

  defp fact(fact) do
    %{
      id: fact.id,
      text: fact.fact,
      said_at: fact.said_at,
      where: where(fact.conversation_ref, fact.private),
      message_href: "/timeline/" <> URI.encode_www_form("ingress-input:#{fact.source_input_id}")
    }
  end

  # Where it was said, and so where Ryker uses it.
  defp where("slack:" <> _rest = conversation_ref, true) do
    case channel(conversation_ref) do
      "D" <> _direct -> "Said in a direct message, used only there"
      _channel -> "Said in a private channel, used only there"
    end
  end

  defp where("slack:" <> _rest, false), do: "Said in a channel everyone can read"
  defp where("control-plane:" <> _rest, _private), do: "Said in Chat"
  defp where(_conversation_ref, true), do: "Used only where it was said"
  defp where(_conversation_ref, false), do: nil

  defp channel(conversation_ref) do
    case String.split(conversation_ref, ":", parts: 3) do
      ["slack", _workspace, channel] -> channel
      _other -> nil
    end
  end

  # A person the way every page names them: "@Name" once Slack said it.
  defp name("slack:user:" <> _id = person_ref, conversation_ref) do
    case Names.workspace_from_destination(conversation_ref) do
      nil -> "Slack user"
      workspace -> Names.person(workspace, person_ref).name
    end
  end

  defp name("control_plane:user:" <> _id, _conversation_ref), do: "You"
  defp name("github:user:" <> _id, _conversation_ref), do: "GitHub user"
  defp name(_person_ref, _conversation_ref), do: "Someone"
end
