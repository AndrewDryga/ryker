defmodule Ryker.StateTools.EvidenceToolsTest do
  @moduledoc """
  Evidence is cited from where it was seen, and a URL is where most of it is.
  `cite_source` took only bare refs (`^[A-Za-z0-9_.:-]+$`) for its source, and
  refused these four well-formed citations on 2026-09-27/28 as
  invalid_arguments: the Timeline showed "Record evidence — Failed" and the
  observation was lost. Each source here is the one the model sent.
  """
  use Ryker.DataCase, async: true
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: Fixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Records
  alias Ryker.Records.Record
  alias Ryker.StateTools.Tools
  alias Ryker.Work.Custody

  @sources [
    "https://emisar.dev/app/emisar/runs/01a0e652-c772-7926-9999-18094648cab3",
    "https://registry.emisar.dev/v1/catalog.json",
    "https://github.com/AndrewDryga/ryker/blob/67d5ee3dff091c293b20a209c648915807f0f2e7/scripts/deploy.sh",
    "hcp-terraform@0.8.9/sha256:7d808108fe995fbb94f0c44396a2df00f6bae257b1cccef204193063660d59c6"
  ]

  test "evidence cites a URL, a file on GitHub or a pinned pack as where it was seen" do
    options = bound_options!()

    for source <- @sources do
      assert {:ok, %{"record_ref" => ref}} =
               Tools.call("cite_source", citation(source), options),
             source

      assert Repo.get_by!(Record, ref: ref).payload["source_name"] == source
    end
  end

  test "a source is still one reference: blank or spaced text is refused" do
    options = bound_options!()

    assert Tools.call("cite_source", citation(""), options) ==
             {:error,
              "invalid_arguments: 1 issue. /source_ref (min_length): needs at least 1 character. Nothing was changed; correct these fields and call again."}

    for source <- ["an emisar run", "https://emisar.dev/app runs"] do
      assert Tools.call("cite_source", citation(source), options) ==
               {:error,
                "invalid_arguments: 1 issue. /source_ref (pattern): does not match its pattern. Nothing was changed; correct these fields and call again."},
             inspect(source)
    end
  end

  test "a citation preserves its source measurement time separately from its title and recording time" do
    # The tool always replaced the measurement with nil, even when the source
    # supplied one, leaving every displayed measurement unavailable.
    options = bound_options!()
    arguments = Map.put(citation(hd(@sources)), "observed_at", "2026-10-27T15:00:00Z")

    assert {:ok, %{"record_ref" => ref}} = Tools.call("cite_source", arguments, options)
    record = Repo.get_by!(Record, ref: ref)
    assert record.payload["observed_at"] == "2026-10-27T15:00:00Z"
    assert record.payload["target"] == arguments["subject"]
    refute DateTime.to_iso8601(record.inserted_at) == record.payload["observed_at"]
  end

  test "an unavailable measurement is never inferred from a citation title" do
    options = bound_options!()

    arguments =
      citation(hd(@sources))
      |> Map.put("subject", "Infrastructure health October 27 around 15:00 UTC")
      |> Map.put("observed_at", nil)

    assert {:ok, %{"record_ref" => ref}} = Tools.call("cite_source", arguments, options)
    assert Repo.get_by!(Record, ref: ref).payload["observed_at"] == nil
  end

  test "an invalid measurement time refuses the citation without recording it" do
    options = bound_options!()
    arguments = Map.put(citation(hd(@sources)), "observed_at", "2026-02-30T15:00:00Z")
    count = Repo.aggregate(Record, :count, :id)
    assert {:error, reason} = Tools.call("cite_source", arguments, options)
    assert reason =~ "observed_at"
    assert Repo.aggregate(Record, :count, :id) == count
  end

  defp citation(source) do
    %{
      "subject" => "Live Emisar monitoring coverage",
      "relation" => "supports",
      "source_ref" => source,
      "observation" => "Read-only alert policy inspection succeeded.",
      "supersedes" => []
    }
  end

  defp bound_options! do
    suffix = Ecto.UUID.generate()

    assert {:ok, transition} =
             Episodes.apply(
               Fixtures.admit_input(%{
                 episode_id: Ecto.UUID.generate(),
                 episode_key: "evidence-source:#{suffix}",
                 native_input_id: "source:#{suffix}",
                 turn_ref: "turn:#{suffix}",
                 execution_mode: :shadow
               })
             )

    assert {:ok, _} =
             WorkSessions.pin_episode(
               transition.episode.id,
               "test-policy",
               String.duplicate("a", 64),
               repository_ref: "ryker"
             )

    assert {:ok, claim} = Custody.claim_next("worker:#{suffix}", 60)

    %{
      binding: %{
        episode: claim.episode,
        session: claim.session,
        turn: claim.turn,
        state_token: Records.token(claim.turn)
      }
    }
  end
end
