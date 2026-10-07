defmodule Ryker.ControlPlane.ConsolePersonQuery do
  @moduledoc "The people console sign-ins named, for every read of `control_plane_people`."
  import Ecto.Query
  alias Ryker.ControlPlane.ConsolePerson

  def all, do: from(people in ConsolePerson, as: :control_plane_people)

  def by_logins(queryable \\ all(), logins),
    do: where(queryable, [control_plane_people: p], p.login in ^logins)

  @doc "Each person as `{login, name}`."
  def select_names(queryable \\ all()),
    do: select(queryable, [control_plane_people: p], {p.login, p.name})

  @doc "The update a sign-in makes: the person's name, written only when it changed."
  def rename(name, now) do
    from(p in ConsolePerson,
      where: p.name != ^name,
      update: [set: [name: ^name, updated_at: ^now]]
    )
  end
end
