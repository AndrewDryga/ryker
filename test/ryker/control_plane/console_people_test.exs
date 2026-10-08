defmodule Ryker.ControlPlane.ConsolePeopleTest do
  use Ryker.DataCase, async: true
  alias Ryker.ControlPlane.ConsolePeople

  # Chat called everyone "You" while Tailscale Serve said who they were (Andrew, 2026-10-04).
  # Every record of a console person names the same login, whichever form the record keeps.
  test "every form a console person's reference takes names the same person" do
    for ref <- [
          "tailscale:andrew@example.com",
          "control_plane:user:tailscale:andrew@example.com",
          "control-plane:user:tailscale:andrew@example.com",
          "control-plane:tailscale:andrew@example.com"
        ] do
      assert ConsolePeople.identity(ref) == {:person, "andrew@example.com"}, ref
    end

    # Signed in with Google through Cloudflare Access instead (2026-10-04), the same forms say so.
    for ref <- [
          "cloudflare:dev@tenant.example",
          "control_plane:user:cloudflare:dev@tenant.example",
          "control-plane:user:cloudflare:dev@tenant.example",
          "control-plane:cloudflare:dev@tenant.example"
        ] do
      assert ConsolePeople.identity(ref) == {:person, "dev@tenant.example"}, ref
    end

    for ref <- [
          "local-operator",
          "control_plane:user:local-operator",
          "control-plane:user:local-operator",
          "control-plane:local"
        ] do
      assert ConsolePeople.identity(ref) == :local, ref
    end

    for ref <- [
          "slack:user:U123",
          "tailscale:",
          "control-plane:tailscale:",
          "cloudflare:",
          "github:user:dev@tenant.example",
          nil
        ] do
      assert ConsolePeople.identity(ref) == nil, inspect(ref)
    end
  end

  test "a person is named as Tailscale last named them, by their login before that" do
    assert ConsolePeople.person("tailscale:andrew@example.com") ==
             %{name: "andrew@example.com", href: nil}

    assert ConsolePeople.seen(%{login: "andrew@example.com", name: "Andrew"}) == :ok
    assert ConsolePeople.seen(%{login: "andrew@example.com", name: "Andrew Example"}) == :ok

    assert ConsolePeople.person("control-plane:tailscale:andrew@example.com") ==
             %{name: "Andrew Example", href: nil}

    assert ConsolePeople.person("local-operator") == %{name: "You", href: nil}
    assert ConsolePeople.person("slack:user:U123") == nil
    assert ConsolePeople.seen(nil) == :ok
  end

  # Cloudflare names a person by their email, up to 200 bytes, and Tailscale by their login
  # when it sends no name; the table keeps 120 characters. Every page a person with a longer
  # one opened crashed in mount on the check (2026-10-04 review).
  test "a name longer than the table keeps is shortened, never refused" do
    login = String.duplicate("a", 150) <> "@example.com"
    long = String.duplicate("é", 130)

    assert ConsolePeople.seen(%{login: login, name: login}) == :ok
    assert ConsolePeople.seen(%{login: "tailscale-user", name: long}) == :ok

    assert %{name: kept} = ConsolePeople.person("tailscale:tailscale-user")
    assert String.length(kept) == 120
    assert String.starts_with?(long, kept)
  end

  test "an avatar takes the first letters of a name" do
    assert ConsolePeople.initials("Andrew Example") == "AE"
    assert ConsolePeople.initials("Zoë Smith") == "ZS"
    assert ConsolePeople.initials("andrew@example.com") == "AE"
    assert ConsolePeople.initials("You") == "Y"
  end
end
