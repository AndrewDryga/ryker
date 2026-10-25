defmodule Ryker.Learning.PersonalContextTest do
  use Ryker.DataCase, async: false
  alias Ryker.CanonicalJSON
  alias Ryker.Fixtures.Learning, as: LearningFixtures
  alias Ryker.Fixtures.Personalization
  alias Ryker.Learning
  alias Ryker.People

  @policy %{policy: "recorded-read-only-policy", policy_digest: String.duplicate("a", 64)}

  # A prepared learning prompt retains known profiles separately from its raw
  # messages. Forgetting a fact must retract that copy before another disclosure.
  test "forgotten profile context cannot authorize a saved learning prompt" do
    {entry, fact, run} = Personalization.learning_context!(@policy)
    expected_digest = CanonicalJSON.digest(fact.fact)
    assert People.forget_fact(fact.id, expected_digest) == {:ok, 1}
    assert People.known_about_authors([entry]) == []
    assert Learning.authorize(run.id) == {:error, :learning_source_stale}
  end

  test "a retry rebuilds a prepared learning prompt after its profile is forgotten" do
    {entry, fact, run} = Personalization.learning_context!(@policy)
    expected_digest = CanonicalJSON.digest(fact.fact)
    assert People.forget_fact(fact.id, expected_digest) == {:ok, 1}
    assert {:ok, replacement} = Learning.prepare([entry.id], @policy)
    refute replacement.id == run.id
    refute Map.has_key?(Jason.decode!(replacement.prompt), "known_about_authors")
    assert Jason.decode!(run.prompt)["known_about_authors"] != nil
  end

  test "unchanged profile context remains authorized" do
    {_entry, _fact, run} = Personalization.learning_context!(@policy)
    assert {:ok, authorized} = Learning.authorize(run.id)
    assert authorized.id == run.id
  end

  test "the same wording under another fact key cannot authorize a saved profile" do
    {_entry, fact, run} = Personalization.learning_context!(@policy)
    fact |> Ecto.Changeset.change(key: "another-kind") |> Repo.update!()
    assert Learning.authorize(run.id) == {:error, :learning_source_stale}
  end

  test "unrelated new facts do not invalidate an unchanged saved subset" do
    {_entry, fact, run} = Personalization.learning_context!(@policy)
    replacement = Map.from_struct(fact) |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
    replacement = Map.put(replacement, :key, "another-kind")
    source = struct!(People.PersonFact, replacement)
    Repo.insert!(source)
    assert {:ok, authorized} = Learning.authorize(run.id)
    assert authorized.id == run.id
  end

  test "a saved profile cannot borrow another author's authority" do
    {_entry, _fact, run} = Personalization.learning_context!(@policy)
    document = Jason.decode!(run.prompt)
    [profile] = document["known_about_authors"]
    profile = put_in(profile, ["actor", "ref"], "another-author")
    prompt = document |> Map.put("known_about_authors", [profile]) |> Jason.encode!()

    prompt_sha256 = CanonicalJSON.digest(prompt)
    run |> Ecto.Changeset.change(prompt: prompt, prompt_sha256: prompt_sha256) |> Repo.update!()

    assert Learning.authorize(run.id) == {:error, :learning_source_stale}
  end

  test "forgotten profile context cannot be frozen for submission or accepted as knowledge" do
    {_entry, fact, run} = Personalization.learning_context!(@policy)
    expected_digest = CanonicalJSON.digest(fact.fact)
    assert People.forget_fact(fact.id, expected_digest) == {:ok, 1}
    assert Learning.freeze_submit(run.id, 1) == {:error, :learning_source_stale}

    result =
      "testdata/learning/recorded-no-change-result.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("result")

    assert LearningFixtures.accept(run.id, result, %{}) == {:error, :learning_source_stale}
  end
end
