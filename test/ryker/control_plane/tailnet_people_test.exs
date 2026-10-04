defmodule Ryker.ControlPlane.TailnetPeopleTest do
  use Ryker.DataCase, async: true

  alias Ryker.ControlPlane.TailnetPeople

  # Chat called everyone "You" while Tailscale Serve said who they were (Andrew, 2026-10-04).
  # Every record of a console person names the same login, whichever form the record keeps.
  test "every form a console person's reference takes names the same person" do
    for ref <- [
          "tailscale:andrew@example.com",
          "control_plane:user:tailscale:andrew@example.com",
          "control-plane:user:tailscale:andrew@example.com",
          "control-plane:tailscale:andrew@example.com"
        ] do
      assert TailnetPeople.identity(ref) == {:tailnet, "andrew@example.com"}, ref
    end

    for ref <- [
          "local-operator",
          "control_plane:user:local-operator",
          "control-plane:user:local-operator",
          "control-plane:local"
        ] do
      assert TailnetPeople.identity(ref) == :local, ref
    end

    for ref <- ["slack:user:U123", "tailscale:", "control-plane:tailscale:", nil] do
      assert TailnetPeople.identity(ref) == nil, inspect(ref)
    end
  end

  test "a person is named as Tailscale last named them, by their login before that" do
    assert TailnetPeople.person("tailscale:andrew@example.com") ==
             %{name: "andrew@example.com", href: nil}

    assert :ok = TailnetPeople.seen(%{login: "andrew@example.com", name: "Andrew"})
    assert :ok = TailnetPeople.seen(%{login: "andrew@example.com", name: "Andrew Example"})

    assert TailnetPeople.person("control-plane:tailscale:andrew@example.com") ==
             %{name: "Andrew Example", href: nil}

    assert TailnetPeople.person("local-operator") == %{name: "You", href: nil}
    assert TailnetPeople.person("slack:user:U123") == nil
    assert TailnetPeople.seen(nil) == :ok
  end

  test "an avatar takes the first letters of a name" do
    assert TailnetPeople.initials("Andrew Example") == "AE"
    assert TailnetPeople.initials("Zoë Smith") == "ZS"
    assert TailnetPeople.initials("andrew@example.com") == "AE"
    assert TailnetPeople.initials("You") == "Y"
  end
end
