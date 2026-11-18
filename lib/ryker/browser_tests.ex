defmodule Ryker.BrowserTests do
  @moduledoc "Frozen browser reports; image custody remains with verified Work output artifacts."
  alias Ryker.Artifacts
  alias Ryker.BrowserTests.Report
  alias Ryker.CanonicalJSON
  alias Ryker.Crypto
  alias Ryker.GitObject
  alias Ryker.Repo
  alias Ryker.StateTools
  alias Ryker.UTCDateTime

  def record(document, binding) do
    with :ok <- validate(document),
         do: Repo.transaction(fn -> record_locked(document, binding) end)
  end

  defp record_locked(document, binding) do
    with {:ok, current} <- StateTools.Binding.fetch_and_lock_current(binding),
         true <- current.episode.execution_mode == :live,
         true <-
           is_nil(current.turn.validation_intent) or
             current.turn.validation_intent["verdict"] != "accept",
         %{"source" => source} <- current.session.worker_job_document,
         true <- is_integer(source["github_repository_id"]) do
      store!(current.turn.id, source, document)
    else
      _denied -> Repo.rollback(:state_tools_binding_not_authorized)
    end
  end

  def reports(turn_id),
    do: turn_id |> Report.Query.by_turn_id() |> Report.Query.chronological() |> Repo.all()

  defp store!(turn_id, source, document) do
    digest = CanonicalJSON.digest(document)
    existing = reports(turn_id)
    report = Enum.find(existing, &(&1.fingerprint == digest))
    if report == nil and length(existing) >= 3, do: Repo.rollback(:browser_report_limit)

    report =
      report ||
        Report.Changeset.insert(%{
          turn_id: turn_id,
          fingerprint: digest,
          document: document,
          source:
            Map.take(source, ~w(repository_ref github_repository github_repository_id binding))
        })
        |> Repo.insert!()

    %{
      "report_id" => report.id,
      "status" => "recorded",
      "url" => Artifacts.Shares.url(turn_id),
      "note" =>
        "Task-reported results saved. Include each intended screenshot filename in outcome.artifact_refs; images are retained only after completion."
    }
  end

  defp validate(document) do
    with :ok <-
           StateTools.SchemaCheck.exact_schema("record_browser_test", document, [
             StateTools.BrowserTools.tool()
           ]),
         true <- byte_size(CanonicalJSON.encode!(document)) <= 32_768,
         true <- GitObject.id?(document["revision"]["commit"]),
         true <- GitObject.id?(document["revision"]["tree"]),
         {:ok, observed} <- UTCDateTime.parse(document["observed_at"]),
         true <- DateTime.compare(observed, DateTime.add(DateTime.utc_now(), 300)) != :gt,
         true <- Enum.all?(document["cases"], &screenshot_name?/1) do
      :ok
    else
      _invalid -> {:error, :invalid_browser_report}
    end
  end

  defp screenshot_name?(%{"screenshot" => nil, "screenshot_sha256" => nil}), do: true

  defp screenshot_name?(%{"screenshot" => name, "screenshot_sha256" => sha}),
    do: Artifacts.Outputs.valid_name?(name) and Crypto.sha256_hex?(sha)
end
