defmodule Ryker.CoopFleet.ManagedSourcesGitAuthTest do
  @moduledoc """
  Found live 2026-09-27: every repository Andrew added stopped in setup. Git
  sent the GitHub App installation token as "Authorization: Bearer", which
  GitHub's git endpoint refuses ("could not read Username") for public and
  private repositories alike; it takes the token only as the password of the
  x-access-token user. A freshly minted token proved both forms that day.
  """
  use ExUnit.Case, async: true
  alias Ryker.CoopFleet.ManagedSources

  test "a managed source fetch authenticates to GitHub's git endpoint the one way it accepts" do
    assert ManagedSources.git_authorization("ghs_token") ==
             "Authorization: Basic " <> Base.encode64("x-access-token:ghs_token")
  end
end
