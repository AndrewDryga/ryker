defmodule Ryker.Flywheel.Runs do
  @moduledoc "Run custody and source checkpoints. Every reviewed page commits with its findings."
  alias Ryker.{AdvisoryLock, Lease, Reference, Repo}
  alias Ryker.Flywheel.{Coverage, Findings, Protocol, Receipt, Run, Sources}

  @lease_seconds 900

  def start(request) do
    with {:ok, ends_at} <- Protocol.datetime(request["until"]),
         :ok <- start_request(request, ends_at) do
      Repo.transaction(fn -> start_locked(request, ends_at) end)
    end
  end

  defp start_locked(request, ends_at) do
    AdvisoryLock.hold!("ryker:flywheel")

    case Repo.fetch(Run.Query.by_request_ref(request["request_ref"])) do
      {:ok, run} -> existing(run, request)
      {:error, :not_found} -> insert_run(request, ends_at)
    end
  end

  defp start_request(request, ends_at) do
    sources = request["sources"]

    valid =
      Reference.valid?(request["request_ref"], 200) and request["mode"] in ~w(suggest auto) and
        valid_sources?(sources) and Protocol.policy?(request["policy"]) and
        DateTime.compare(ends_at, Repo.now!()) != :gt and
        (is_binary(request["from"]) or request["since_last"] == true)

    if valid, do: :ok, else: {:error, :invalid_flywheel_run}
  end

  defp valid_sources?(sources) do
    is_list(sources) and length(sources) in 1..40 and
      Enum.all?(sources, &Reference.valid?(&1, 120)) and
      length(Enum.uniq(sources)) == length(sources)
  end

  defp existing(%Run{} = run, request) do
    same =
      to_string(run.mode) == request["mode"] and run.policy == request["policy"] and
        Enum.sort(Map.keys(run.progress)) == Enum.sort(request["sources"]) and
        (request["from"] == nil or
           DateTime.compare(run.starts_at, Protocol.datetime!(request["from"])) == :eq) and
        DateTime.compare(run.ends_at, elem(Protocol.datetime(request["until"]), 1)) == :eq

    if not same, do: Repo.rollback(:flywheel_request_conflict)

    if run.status == :running and request["lease_ref"] != run.lease_ref,
      do: Repo.rollback(:flywheel_run_busy)

    run
  end

  defp insert_run(request, ends_at) do
    if Repo.exists?(Run.Query.running()), do: Repo.rollback(:flywheel_resume_required)
    runs = Repo.all(Run.Query.ordered_by_oldest())
    starts_at = start_time(request, runs, ends_at)
    if DateTime.compare(starts_at, ends_at) != :lt, do: Repo.rollback(:invalid_flywheel_period)

    progress =
      Coverage.plan(runs, request["sources"], starts_at, ends_at, request["since_last"] == true)

    attributes = %{
      request_ref: request["request_ref"],
      mode: request["mode"],
      starts_at: starts_at,
      ends_at: ends_at,
      progress: progress,
      policy: request["policy"],
      lease_ref: Repo.generate_id(),
      lease_expires_at: DateTime.add(Repo.now!(), @lease_seconds, :second)
    }

    case Repo.insert(Run.Changeset.insert(attributes)) do
      {:ok, run} -> run
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp start_time(%{"from" => value}, _runs, _ends_at) do
    case Protocol.datetime(value) do
      {:ok, at} -> at
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp start_time(_request, [], ends_at), do: DateTime.add(ends_at, -7, :day)

  defp start_time(_request, runs, _ends_at),
    do: Enum.min_by(runs, & &1.starts_at, DateTime).starts_at

  def resume(id, lease_ref) do
    Repo.transaction(fn ->
      run = fetch_and_lock_run!(id)
      now = Repo.now!()
      if run.status != :running, do: Repo.rollback(:flywheel_run_finished)

      if DateTime.compare(run.lease_expires_at, now) == :gt and run.lease_ref != lease_ref,
        do: Repo.rollback(:flywheel_run_busy)

      renew(run, %{lease_ref: Repo.generate_id()})
    end)
  end

  def with_run(id, lease_ref, operation) do
    Repo.transaction(fn ->
      run = fetch_and_lock_run!(id)

      if run.status != :running or not Lease.held?(run, lease_ref, Repo.now!()),
        do: Repo.rollback(:flywheel_lease_lost)

      operation.(run)
    end)
  end

  defp fetch_and_lock_run!(id) do
    AdvisoryLock.hold!("ryker:flywheel")
    run = id |> Run.Query.by_id() |> Run.Query.lock_for_update() |> Repo.peek()
    run || Repo.rollback(:flywheel_run_not_found)
  end

  def renew(%Run{} = run, attributes) do
    attributes =
      Map.put(
        attributes,
        :lease_expires_at,
        Lease.renewed(run.lease_expires_at, Repo.now!(), @lease_seconds)
      )

    run |> Run.Changeset.checkpoint(attributes) |> Repo.update!()
  end

  def collect(%Run{} = run, source) do
    progress = source!(run, source)
    if progress["status"] == "complete", do: Repo.rollback(:flywheel_source_complete)
    page = Sources.page(source, progress)
    stage(run, source, page)
  end

  def stage(%Run{} = run, source, page) do
    progress = source!(run, source)

    if not Protocol.page?(page) or page["cursor"] != progress["cursor"],
      do: Repo.rollback(:invalid_flywheel_page)

    if progress["status"] == "complete", do: Repo.rollback(:flywheel_source_complete)
    previous_query = progress["query"] || get_in(progress, ["pending", "query"])

    if previous_query && previous_query != page["query"],
      do: Repo.rollback(:flywheel_source_query_changed)

    identities = Protocol.identities(source, page["records"])

    pending = %{
      "identities" => identities,
      "next_cursor" => page["next_cursor"],
      "complete" => page["complete"],
      "query" => page["query"],
      "content_digest" => Protocol.digest(page["records"]),
      "coverage" => Map.get(page, "coverage", "complete"),
      "limitation" => page["limitation"]
    }

    digest = Protocol.digest(pending)
    pending = Map.put(pending, "digest", digest)
    # Bodies stay in the source. On resume a fresh export replaces a page that
    # changed since collection; a stale review cannot acknowledge that replacement.
    progress = Map.merge(progress, %{"pending" => pending, "status" => "pending"})
    run = renew(run, %{progress: Map.put(run.progress, source, progress)})
    unreviewed = Enum.reject(page["records"], &reviewed?(source, &1))

    %{
      run: run,
      page: Map.put(page, "records", unreviewed),
      digest: digest,
      previously_reviewed: length(identities) - length(unreviewed)
    }
  end

  defp reviewed?(source, record),
    do: Repo.exists?(Receipt.Query.by_identity(source, record["ref"], record["version"]))

  def review(%Run{} = run, source, digest, findings) do
    progress = source!(run, source)
    pending = progress["pending"]
    review_digest = Protocol.digest(%{"digest" => digest, "findings" => findings})

    if is_nil(pending) and progress["last_review_digest"] == review_digest do
      %{run: run, findings: [], replayed: true}
    else
      review_pending(run, source, digest, findings, progress, pending, review_digest)
    end
  end

  defp review_pending(run, source, digest, findings, progress, pending, review_digest) do
    if not is_map(pending) or pending["digest"] != digest,
      do: Repo.rollback(:flywheel_page_changed)

    if not is_list(findings) or length(findings) > 100,
      do: Repo.rollback(:invalid_flywheel_findings)

    identities = pending["identities"] || []
    saved = Enum.map(findings, &Findings.observe(run, &1, identities))
    now = Repo.now!()

    rows =
      Enum.map(
        identities,
        &%{
          id: Repo.generate_id(),
          source: &1["source"],
          ref: &1["ref"],
          version: &1["version"],
          run_id: run.id,
          reviewed_at: now
        }
      )

    Repo.insert_all(Receipt, rows,
      on_conflict: :nothing,
      conflict_target: [:source, :ref, :version]
    )

    limitations = Enum.uniq((progress["limitations"] || []) ++ List.wrap(pending["limitation"]))
    final_status = terminal_status(limitations)
    status = if pending["complete"], do: final_status, else: "pending"

    progress =
      Map.merge(progress, %{
        "status" => status,
        "cursor" => pending["next_cursor"],
        "pending" => nil,
        "reviewed" => progress["reviewed"] + length(identities),
        "query" => pending["query"],
        "last_digest" => digest,
        "last_review_digest" => review_digest,
        "limitations" => limitations,
        "reason" => Enum.join(limitations, "; ")
      })

    %{run: renew(run, %{progress: Map.put(run.progress, source, progress)}), findings: saved}
  end

  defp terminal_status([]), do: "complete"
  defp terminal_status(_limitations), do: "partial"

  def gap(%Run{} = run, source, status, reason, closed) do
    progress = source!(run, source)

    if status not in ~w(partial unavailable expired) or not Reference.valid?(reason, 2_000),
      do: Repo.rollback(:invalid_flywheel_gap)

    if progress["status"] == "complete", do: Repo.rollback(:flywheel_source_complete)

    if not is_boolean(closed) or
         (closed and
            (status != "expired" or not is_nil(progress["pending"]) or
               not is_nil(progress["cursor"]))),
       do: Repo.rollback(:invalid_flywheel_gap_closure)

    progress =
      Map.merge(progress, %{
        "status" => status,
        "reason" => reason,
        "pending" => nil,
        "closed" => closed
      })

    renew(run, %{progress: Map.put(run.progress, source, progress)})
  end

  def finish(%Run{} = run) do
    states = Enum.map(run.progress, fn {_source, progress} -> progress["status"] end)
    if "pending" in states, do: Repo.rollback(:flywheel_sources_pending)
    status = if Enum.all?(states, &(&1 == "complete")), do: :complete, else: :partial
    renew(run, %{status: status})
  end

  def charge(%Run{} = run, source, reference, amount) do
    progress = source!(run, source)

    valid =
      Reference.valid?(reference, 200) and is_binary(amount) and
        Regex.match?(~r/^[0-9]{1,5}(\.[0-9]{1,6})?$/, amount)

    if not valid, do: Repo.rollback(:invalid_flywheel_charge)
    charges = progress["charges"] || %{}

    if charges[reference] && charges[reference] != amount,
      do: Repo.rollback(:flywheel_charge_conflict)

    progress = Map.put(progress, "charges", Map.put(charges, reference, amount))
    renew(run, %{progress: Map.put(run.progress, source, progress)})
  end

  def budget_available?(%Run{} = run) do
    spent =
      Enum.reduce(run.progress, Decimal.new(0), fn {_source, progress}, sum ->
        Enum.reduce(progress["charges"] || %{}, sum, fn {_ref, amount}, total ->
          Decimal.add(total, Decimal.new(amount))
        end)
      end)

    elapsed = DateTime.diff(Repo.now!(), run.inserted_at, :second)

    Decimal.compare(spent, Decimal.new(run.policy["max_cost_usd"])) == :lt and
      elapsed < run.policy["max_minutes"] * 60
  end

  defp source!(%Run{} = run, source),
    do: run.progress[source] || Repo.rollback(:flywheel_source_not_registered)
end
