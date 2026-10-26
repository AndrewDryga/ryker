defmodule Ryker.Work.CompletionReview.Evidence do
  @moduledoc "A bounded review snapshot and the fingerprints of its complete evidence ledger."
  alias Ryker.{CanonicalJSON, Episodes, Knowledge, Records, Repo}
  alias Ryker.Work.{ActivityEvent, Final, FinalPreflight, Turn}
  alias Ryker.Work.CompletionReview.Prompt

  @maximum_events 256
  @evidence_budgets [
    {["work"], 64_000},
    {["previous_inputs", "items"], 24_000},
    {["records"], 40_000},
    {["tool_observations", "items"], 64_000}
  ]

  @doc "Freeze only evidence authorized for this Work session, under its parent lease."
  def snapshot(claim, final) do
    _sources = sources!(claim)
    records = records(claim)
    observations = observations(claim)

    tools =
      observations
      |> ActivityEvent.Query.recent_evidence(@maximum_events)
      |> Repo.all()
      |> Enum.reverse()

    identities = observations |> ActivityEvent.Query.select_evidence_identities() |> Repo.all()

    snapshot = %{
      "candidate" => Final.document(final),
      "request_input_available" => Episodes.Origins.person_participated?(claim.episode.id),
      "dismissible_wait_refs" => dismissible_waits(claim),
      "work" => (claim.turn.submission || %{})["context"] || %{},
      "previous_inputs" => previous_inputs(claim),
      "records" => records,
      "tool_observations" => %{
        "items" => tools,
        "omitted" => max(length(identities) - @maximum_events, 0)
      },
      "ledger_sha256" => fingerprint(claim),
      "progress_sha256" =>
        CanonicalJSON.digest(%{"records" => records, "observations" => identities})
    }

    fit(snapshot)
  end

  # JSON previews are escaped again in the prompt. Measure the actual wire
  # document, reserving space for the previous reviews custody adds afterward.
  # The candidate and fingerprints stay exact; every shortened body is marked.
  defp fit(snapshot) do
    Enum.find_value([1, 2, 4, 8, 16], fn divisor ->
      fitted =
        Enum.reduce(@evidence_budgets, snapshot, fn {path, budget}, document ->
          update_in(document, path, &CanonicalJSON.bounded(&1, div(budget, divisor)))
        end)

      if byte_size(Prompt.build(fitted)) <= 224_000, do: {:ok, fitted}
    end) || {:error, :completion_review_context_too_large}
  end

  @doc "Both durable records and tool evidence must still be exactly those the reviewer saw."
  def fingerprint(claim) do
    episode = Repo.fetch!(Episodes.Episode.Query.by_id(claim.episode.id))

    identities =
      claim |> observations() |> ActivityEvent.Query.select_evidence_identities() |> Repo.all()

    CanonicalJSON.digest(%{
      "disclosed_sources" => sources!(claim),
      "authorized_records" => records(claim),
      "records" =>
        FinalPreflight.ledger_sha256(episode.id, episode.semantic_version, [], claim.turn.id),
      "observations" => identities
    })
  end

  defp observations(claim) do
    ActivityEvent.Query.completion_evidence(
      claim.episode.id,
      claim.session.id,
      claim.turn.coop_turn_id
    )
  end

  defp dismissible_waits(claim) do
    claim.turn.id
    |> Records.Record.Query.by_turn_id()
    |> Records.Record.Query.by_kinds(["input_request", "event_wait"])
    |> Records.Record.Query.open()
    |> Records.Record.Query.limit_to(256)
    |> Repo.all()
    |> Enum.map(& &1.ref)
  end

  defp previous_inputs(claim) do
    items =
      claim.episode.id
      |> Turn.Query.review_inputs(claim.session.id)
      |> Repo.all()
      |> Enum.reverse()

    %{
      "items" => items,
      "window" =>
        "Latest 100 submitted input groups; original request also appears in Work continuity."
    }
  end

  # Review serves this same active request. Forgetting learned memory keeps
  # its original message answerable, so preserve the parent's input-only role.
  # Recalled memory still needs live sources; historical records below are
  # separately authorized as new disclosures, without this input exception.
  defp sources!(claim) do
    case Knowledge.KnowledgeSnapshot.producer_sources(claim.episode, claim.session, claim.session) do
      sources when is_list(sources) -> sources
      {:error, reason} -> Repo.rollback(reason)
      _stale -> Repo.rollback(:work_knowledge_context_stale)
    end
  end

  defp records(claim) do
    claim.episode.id
    |> Records.retained_records()
    |> Enum.map(&Records.DerivedContext.record/1)
    |> Records.DerivedContext.filter(claim.episode, claim.session.repository_ref, nil)
    |> Enum.map(& &1["document"])
  end
end
