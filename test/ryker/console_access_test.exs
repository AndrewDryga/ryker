defmodule Ryker.ConsoleAccessTest do
  # Andrew, 2026-10-13: Cloudflare and Tailscale only carry the console to a browser, and Ryker
  # signs people in itself. A tunnel's requests reach Ryker just as a local browser's do, so
  # a link that signed in twice, or a session that never ended, would let anyone holding one in.
  use Ryker.DataCase, async: true
  import Ecto.Query
  alias Ryker.ConsoleAccess
  alias Ryker.ConsoleAccess.{Link, Session}

  test "a link signs its person in once, on one browser" do
    {:ok, url} = ConsoleAccess.slack_link("T123", "U456", "Dana")
    token = token(url)

    assert {:ok, %Link{person_name: "Dana", person_via: :slack_operator} = link} =
             ConsoleAccess.fetch_link(token)

    assert {:ok, session_token, %Session{} = session, %Link{return_to: nil}} =
             ConsoleAccess.sign_in(token)

    # Each row's times come from one clock, the database's, which also stamps the link's use.
    # Stamped by the host's clock, which ran ahead of the test database's, every link failed its
    # own check when used.
    assert DateTime.diff(link.expires_at, link.inserted_at, :microsecond) == 900_000_000
    assert DateTime.diff(session.expires_at, session.inserted_at, :day) == 30
    assert session.inserted_at == session.last_seen_at

    assert session.person_via == :slack_operator
    assert session.person_login == "T123.U456"
    assert session.person_name == "Dana"
    assert {:ok, %Session{id: id}} = ConsoleAccess.fetch_session(session_token)
    assert id == session.id

    assert ConsoleAccess.sign_in(token) == {:error, :used}
    assert ConsoleAccess.fetch_link(token) == {:error, :used}
  end

  test "an expired link signs nobody in" do
    {:ok, url} = ConsoleAccess.slack_link("T123", "U456", "Dana")
    token = token(url)

    Repo.update_all(Link, set: expired(Repo.now!()))

    assert ConsoleAccess.fetch_link(token) == {:error, :expired}
    assert ConsoleAccess.sign_in(token) == {:error, :expired}
    assert Repo.aggregate(Session, :count) == 0
  end

  test "anything that is not a link's token names nothing" do
    for token <- [nil, "", "short", String.duplicate("a", 43), String.duplicate("!", 43)] do
      assert ConsoleAccess.fetch_link(token) == {:error, :not_found}
      assert ConsoleAccess.sign_in(token) == {:error, :not_found}
      assert ConsoleAccess.fetch_session(token) == {:error, :not_found}
    end
  end

  test "the owner's link opens the page it was made for" do
    {:ok, url} = ConsoleAccess.owner_link("/setup")

    assert {:ok, _session_token, %Session{person_via: :owner, person_name: "Owner"},
            %Link{return_to: "/setup"}} = ConsoleAccess.sign_in(token(url))
  end

  test "a session lasts 30 days from its last use, and a signed-out browser is nobody" do
    {:ok, url} = ConsoleAccess.slack_link("T123", "U456", "Dana")
    {:ok, session_token, session, _link} = ConsoleAccess.sign_in(token(url))
    now = Repo.now!()

    Repo.update_all(from(s in Session, where: s.id == ^session.id),
      set: [
        last_seen_at: DateTime.add(now, -2 * 3_600, :second),
        expires_at: DateTime.add(now, 60, :second)
      ]
    )

    assert {:ok, used} = ConsoleAccess.fetch_session(session_token)
    assert DateTime.diff(used.expires_at, now, :day) in 29..30
    assert DateTime.diff(Repo.get!(Session, session.id).expires_at, now, :day) in 29..30

    assert ConsoleAccess.sign_out(session_token) == {:ok, session.id}
    assert ConsoleAccess.fetch_session(session_token) == {:error, :not_found}
    assert ConsoleAccess.sign_out(session_token) == {:ok, nil}
  end

  test "a session past its 30 days is nobody" do
    {:ok, url} = ConsoleAccess.slack_link("T123", "U456", "Dana")
    {:ok, session_token, _session, _link} = ConsoleAccess.sign_in(token(url))

    Repo.update_all(Session, set: expired(Repo.now!()))

    assert ConsoleAccess.fetch_session(session_token) == {:error, :not_found}
    assert ConsoleAccess.sessions() == []
  end

  # People outside Slack get in by an invite from someone signed in, under the name given them.
  test "an invite names someone new, and a withdrawn one signs nobody in" do
    assert ConsoleAccess.invite("  ", "control-plane:slack_operator:T123.U456") ==
             {:error, :invalid_name}

    assert ConsoleAccess.invite("Dana\nX", "control-plane:slack_operator:T123.U456") ==
             {:error, :invalid_name}

    {:ok, kept} =
      ConsoleAccess.invite("Dana from Acme", "control-plane:slack_operator:T123.U456")

    {:ok, withdrawn} = ConsoleAccess.invite("Sam", "control-plane:slack_operator:T123.U456")

    assert [%Link{person_name: "Sam"} = sam, %Link{person_name: "Dana from Acme"}] =
             ConsoleAccess.open_invites()

    assert ConsoleAccess.withdraw_invite(sam.id) == :ok
    assert ConsoleAccess.sign_in(token(withdrawn)) == {:error, :not_found}

    assert {:ok, _session_token, %Session{person_via: :invite} = session, _link} =
             ConsoleAccess.sign_in(token(kept))

    assert session.person_name == "Dana from Acme"
    assert ConsoleAccess.open_invites() == []
    assert [%Session{id: id}] = ConsoleAccess.sessions()
    assert id == session.id
    assert ConsoleAccess.end_session(id) == :ok
    assert ConsoleAccess.sessions() == []
    assert ConsoleAccess.end_session(id) == {:error, :not_found}
  end

  # A name's column counts code points, as PostgreSQL's `char_length` does, and an accent written
  # as a mark of its own is a second one. Counted as a reader sees them, a long name passed the
  # check here and then failed the column's, so the invite or the Slack link was never made.
  test "a name is held to its column's 120 code points, not to the letters a reader sees" do
    accented = String.duplicate("e\u0301", 61)

    assert ConsoleAccess.invite(accented, "control-plane:slack_operator:T123.U456") ==
             {:error, :invalid_name}

    {:ok, url} = ConsoleAccess.slack_link("T123", "U456", accented)
    assert {:ok, %Link{person_name: name}} = ConsoleAccess.fetch_link(token(url))
    assert name == String.duplicate("e\u0301", 60)
  end

  test "links and sessions keep only their tokens' digests" do
    {:ok, url} = ConsoleAccess.slack_link("T123", "U456", "Dana")
    token = token(url)
    {:ok, session_token, _session, _link} = ConsoleAccess.sign_in(token)

    stored =
      Enum.map(Repo.all(Link), & &1.token_sha256) ++
        Enum.map(Repo.all(Session), & &1.token_sha256)

    refute token in stored
    refute session_token in stored
    assert Ryker.Crypto.sha256_hex(token) in stored
  end

  defp expired(now),
    do: [
      inserted_at: DateTime.add(now, -3_600, :second),
      expires_at: DateTime.add(now, -1, :second)
    ]

  defp token(url) do
    assert "/sign-in/" <> token = URI.parse(url).path
    token
  end
end
