defmodule Ryker.ControlPlane.ConsolePeople do
  @moduledoc """
  The people Tailscale Serve or Cloudflare Access named
  (`Ryker.ControlPlane.Viewer`), by login, with the name it last gave each, so
  the console names a person on everything they sent or changed. Chat called
  everyone "You" while Serve said who they were (Andrew, 2026-10-04: "now when
  we have tailscale auth why not to properly track user everywhere?"). A person
  is remembered when their page connects (`seen/1`). Access names a person by
  their email alone.

  `person/1` names whoever is behind any reference the console records for a
  person, where `<via>` is `tailscale` or `cloudflare`:

  - a Chat message's author, `<via>:<login>`;
  - the person a turn is for, or a Chat reaction's,
    `control_plane:user:<via>:<login>` (events recorded before 2026-10-06
    spell a reaction's `control-plane:user:`);
  - a change made on a page, `control-plane:<via>:<login>`.

  The console reached any other way names nobody: its references are the same
  with `local-operator` (or `control-plane:local`) in place of the person, and
  a page calls it "You", as before.
  """
  use Ecto.Schema

  import Ecto.Query

  alias Ryker.ControlPlane.{Actor, PageRead}
  alias Ryker.Repo

  @primary_key {:login, :string, autogenerate: false}
  schema "control_plane_people" do
    field(:name, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @local %{name: "You", href: nil}

  @doc """
  Remembers the name a sign-in gives `viewer`'s login; nothing is written while
  it is the same. A Cloudflare email or a Tailscale login can stand in for a
  name and run to 200 bytes; the first 120 characters are kept.
  """
  @spec seen(Ryker.ControlPlane.Viewer.t() | nil) :: :ok
  def seen(%{login: login, name: name}) do
    now = DateTime.utc_now()
    name = Ryker.Text.characters(name, 120)

    Repo.insert_all(
      __MODULE__,
      [%{login: login, name: name, inserted_at: now, updated_at: now}],
      conflict_target: :login,
      on_conflict:
        from(person in __MODULE__,
          where: person.name != ^name,
          update: [set: [name: ^name, updated_at: ^now]]
        )
    )

    :ok
  end

  def seen(nil), do: :ok

  @doc """
  Whose `ref` is: `{:person, login}` for someone Tailscale or Cloudflare
  named, `:local` for the console reached any other way, or nil for a
  reference that is not a console person's.
  """
  @spec identity(term()) :: {:person, String.t()} | :local | nil
  def identity("control_plane:user:" <> ref), do: identity(ref)
  def identity("control-plane:user:" <> ref), do: identity(ref)
  def identity(local) when local in ["local-operator", "control-plane:local"], do: :local

  def identity(ref) do
    case Actor.login(ref) do
      nil -> nil
      login -> {:person, login}
    end
  end

  @doc """
  A console person the way every page names one: the name their sign-in gave
  them, their login before it gave one, or "You" for the local console; nil
  for a reference that is not a console person's.
  """
  @spec person(term()) :: %{name: String.t(), href: nil} | nil
  def person(ref) do
    case identity(ref) do
      {:person, login} -> %{name: Map.get(every_name(), login, login), href: nil}
      :local -> @local
      nil -> nil
    end
  end

  # Everyone's name, read once within a page read (`PageRead`): a page named
  # each person it showed with a query a row (2026-10-04 review). The people
  # are the few who sign in to the console.
  defp every_name do
    PageRead.memo({__MODULE__, :names}, fn ->
      Repo.all(from(person in __MODULE__, select: {person.login, person.name})) |> Map.new()
    end)
  end

  @doc "The name of each login a sign-in named, in one read."
  @spec names([String.t()]) :: %{String.t() => String.t()}
  def names([]), do: %{}

  def names(logins) do
    Repo.all(
      from(person in __MODULE__,
        where: person.login in ^Enum.uniq(logins),
        select: {person.login, person.name}
      )
    )
    |> Map.new()
  end

  @doc ~s(The letters for a person's avatar: "AD" for "Andrew Dryga", "Y" for "You".)
  @spec initials(String.t()) :: String.t()
  def initials(name) do
    name
    |> String.split(~r/[\s@._-]+/u, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
    |> case do
      "" -> "?"
      letters -> letters
    end
  end
end
