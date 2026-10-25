defmodule Ryker.Work.SessionTest do
  use ExUnit.Case, async: true
  alias Ryker.Work.Session

  test "only the same retained episode and session identify one native transcript" do
    session = %Session{id: Ecto.UUID.generate(), episode_id: Ecto.UUID.generate()}
    assert Session.same_identity?(session, session)
    refute Session.same_identity?(session, %{session | id: Ecto.UUID.generate()})
    refute Session.same_identity?(session, %{session | episode_id: Ecto.UUID.generate()})
  end

  test "missing or non-session identities never authorize transcript reuse" do
    refute Session.same_identity?(%Session{}, %Session{})
    refute Session.same_identity?(%Session{}, nil)
    refute Session.same_identity?(%{}, %{})
  end
end
