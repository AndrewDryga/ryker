defmodule Ryker.Slack.WelcomeDigestMigrationTest do
  @moduledoc """
  A channel's configuration now keeps the digest of what its welcome last said.
  The column is added to rows every installation already has: each keeps every
  value it had, starts with no digest (so the next sweep draws its welcome once),
  and accepts only a SHA-256.
  """
  # The migrator runs inside this test's sandbox transaction.
  use Ryker.MigrationCase
  alias Ryker.Slack.ChannelConfiguration

  @version 20_261_010_000_000

  test "a configuration keeps its values, starts without a digest and takes only a SHA-256" do
    now = DateTime.utc_now()

    configuration =
      Repo.insert!(%ChannelConfiguration{
        alert_policy: :reply,
        channel_ref: "C456",
        environment_ref: nil,
        id: Ecto.UUID.generate(),
        participation: :mentions,
        revision: 3,
        saved_at: now,
        welcome_message_ref: "1787832000.000100",
        workspace_ref: "T123"
      })

    assert migrate_down(@version) == :ok
    assert migrate_up(@version) == :ok

    kept = Repo.get!(ChannelConfiguration, configuration.id)
    assert {kept.revision, kept.welcome_message_ref} == {3, "1787832000.000100"}
    assert is_nil(kept.welcome_digest)

    kept |> Ecto.Changeset.change(welcome_digest: String.duplicate("a", 64)) |> Repo.update!()

    assert_raise Ecto.ConstraintError, ~r/welcome_digest_valid/, fn ->
      kept |> Ecto.Changeset.change(welcome_digest: "not a digest") |> Repo.update!()
    end
  end
end
