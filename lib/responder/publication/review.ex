defmodule Responder.Publication.Review do
  @moduledoc false

  alias Responder.CanonicalJSON

  @required ~w(candidate_head candidate_tree creation_base gate not_publishable_reasons operation_id parent_head parent_tree patch_bytes patch_truncated policy_digest policy_findings publishable rebase session_id session_revision source_head source_tree)
  @optional ~w(gate_error patch patch_artifact_id patch_digest pull_request)
  @git_identity ~r/\A[a-f0-9]{40,64}\z/
  @reference ~r/\A[A-Za-z0-9_.:-]{1,256}\z/

  @spec prepare(map(), map()) :: {:ok, map()} | {:error, term()}
  def prepare(document, expected) when is_map(document) and is_map(expected) do
    with :ok <- fields(document),
         :ok <- reference(document["operation_id"], :operation_id),
         true <- document["session_id"] == expected.session_id,
         true <- document["session_revision"] == expected.revision,
         true <- digest?(document["policy_digest"]),
         :ok <- git_identities(document),
         :ok <- enum(document["gate"], ~w(passed failed startup_error not_run none), :gate),
         :ok <- enum(document["rebase"], ~w(clean conflict), :rebase),
         true <- is_boolean(document["patch_truncated"]),
         true <- is_boolean(document["publishable"]),
         :ok <- bounded_strings(document["policy_findings"], 64, 4_096, :policy_findings),
         :ok <-
           bounded_strings(
             document["not_publishable_reasons"],
             64,
             256,
             :not_publishable_reasons
           ),
         :ok <- patch_identity(document),
         :ok <- pull_request(document["pull_request"]),
         :ok <- CanonicalJSON.validate(document, max_bytes: 512 * 1_024) do
      {:ok, document}
    else
      false -> {:error, {:invalid_publication_review, :identity}}
      {:error, _reason} = error -> error
    end
  end

  def prepare(_document, _expected), do: {:error, {:invalid_publication_review, :document}}

  def fingerprint(document),
    do: document |> CanonicalJSON.encode!() |> digest()

  def publishable?(%{"publishable" => true}), do: true
  def publishable?(_document), do: false

  @doc """
  Decides whether an exact snapshot is safe to share as a draft pull request.

  This is deliberately not `publishable?/1`. Merge readiness asks whether the
  trusted gate passed; shareability asks whether the host holds one exact,
  security-clean snapshot a person could read. A gate that could not start is
  an environment blocker, a gate that failed is work the agent should correct,
  and a policy finding is neither — collapsing the three into one boolean is
  what turned "Docker is missing" into "nothing can be shared".

  Shareability never waives a check, grants merge or deployment authority, or
  by itself authorizes publication: the caller still owns that grant.
  """
  @spec draft_verdict(term()) :: map()
  def draft_verdict(document) when is_map(document) do
    reasons = draft_reasons(document)

    %{
      "gate" => document["gate"],
      "incomplete_checks" => incomplete_checks(document),
      "reasons" => reasons,
      "shareable" => reasons == []
    }
  end

  def draft_verdict(_document),
    do: %{
      "gate" => nil,
      "incomplete_checks" => [],
      "reasons" => ["The trusted review is missing."],
      "shareable" => false
    }

  @spec draft_shareable?(term()) :: boolean()
  def draft_shareable?(document), do: draft_verdict(document)["shareable"]

  defp draft_reasons(document) do
    blocking =
      [
        gate_reason(document["gate"]),
        rebase_reason(document["rebase"]),
        findings_reason(document["policy_findings"]),
        snapshot_reason(document)
      ]
      |> Enum.reject(&is_nil/1)

    blocking ++ List.wrap(unexplained_reason(document, blocking))
  end

  # Every clause above returns nil for a clean gate, so a refusal none of them
  # accounts for would otherwise read as shareable. That is the secret, path,
  # identity and authorization class, which can never produce a pull request:
  # the host cannot read the reason, so it cannot call the snapshot safe.
  defp unexplained_reason(%{"publishable" => true}, _blocking), do: nil
  defp unexplained_reason(_document, [_reason | _rest]), do: nil

  defp unexplained_reason(%{"gate" => gate}, []) when gate in ~w(startup_error not_run none),
    do: nil

  defp unexplained_reason(_document, []),
    do: "The trusted review refused this candidate without a reason the host can read."

  defp gate_reason("failed"), do: "The trusted gate failed."
  defp gate_reason(gate) when gate in ~w(passed startup_error not_run none), do: nil
  defp gate_reason(_gate), do: "The trusted gate result is unknown."

  defp rebase_reason("clean"), do: nil
  defp rebase_reason(_rebase), do: "The change no longer applies to the current base."

  defp findings_reason([]), do: nil

  defp findings_reason(findings) when is_list(findings),
    do:
      "The trusted policy review found #{length(findings)} issue#{if length(findings) == 1, do: "", else: "s"}."

  defp findings_reason(_findings), do: "The trusted policy review is unreadable."

  defp snapshot_reason(document) do
    exact =
      match?(:ok, reference(document["patch_artifact_id"], :patch_artifact_id)) and
        digest?(document["patch_digest"]) and is_integer(document["patch_bytes"]) and
        document["patch_bytes"] > 0 and document["patch_bytes"] <= 64 * 1_024 * 1_024 and
        document["patch_truncated"] == false

    if exact, do: nil, else: "No exact complete snapshot of the change was retained."
  end

  # Why a required check has no result is the operator-facing half of "checks
  # unavailable"; without it the card can only say that something is missing.
  defp incomplete_checks(%{"gate" => "passed"}), do: []

  defp incomplete_checks(%{"gate" => gate} = document)
       when gate in ~w(startup_error not_run none) do
    case document["gate_error"] do
      error when is_binary(error) and error != "" -> [error]
      _absent -> incomplete_check_label(gate)
    end
  end

  defp incomplete_checks(_document), do: []

  defp incomplete_check_label("startup_error"), do: ["The trusted gate could not start."]
  defp incomplete_check_label("not_run"), do: ["The trusted gate did not run."]
  defp incomplete_check_label("none"), do: ["This workspace has no trusted gate configured."]

  defp fields(document) do
    keys = Map.keys(document)

    if Enum.all?(@required, &(&1 in keys)) and Enum.all?(keys, &(&1 in (@required ++ @optional))),
      do: :ok,
      else: {:error, {:invalid_publication_review, :fields}}
  end

  defp git_identities(document) do
    if Enum.all?(
         ~w(candidate_head candidate_tree creation_base parent_head parent_tree source_head source_tree),
         &(is_binary(document[&1]) and Regex.match?(@git_identity, document[&1]))
       ) do
      :ok
    else
      {:error, {:invalid_publication_review, :git_identity}}
    end
  end

  defp patch_identity(%{"publishable" => true} = document) do
    with :ok <- reference(document["patch_artifact_id"], :patch_artifact_id),
         true <- digest?(document["patch_digest"]),
         true <- is_integer(document["patch_bytes"]) and document["patch_bytes"] > 0,
         true <- document["patch_bytes"] <= 64 * 1_024 * 1_024,
         true <- document["patch_truncated"] in [true, false],
         true <- document["gate"] == "passed" and document["rebase"] == "clean",
         true <- document["policy_findings"] == [],
         true <- document["not_publishable_reasons"] == [] do
      :ok
    else
      false -> {:error, {:invalid_publication_review, :publishable}}
      {:error, _reason} = error -> error
    end
  end

  defp patch_identity(%{"publishable" => false, "patch_bytes" => bytes})
       when is_integer(bytes) and bytes >= 0 and bytes <= 64 * 1_024 * 1_024,
       do: :ok

  defp patch_identity(_document), do: {:error, {:invalid_publication_review, :patch}}

  defp pull_request(nil), do: :ok

  defp pull_request(%{"head_commit" => head, "number" => number, "ref" => ref} = pull_request)
       when map_size(pull_request) == 3 and is_binary(head) and is_integer(number) and number > 0 do
    if Regex.match?(@git_identity, head) and bounded_text?(ref, 256),
      do: :ok,
      else: {:error, {:invalid_publication_review, :pull_request}}
  end

  defp pull_request(_pull_request),
    do: {:error, {:invalid_publication_review, :pull_request}}

  defp bounded_strings(values, maximum_count, maximum_bytes, _field)
       when is_list(values) and length(values) <= maximum_count do
    if Enum.all?(values, &bounded_text?(&1, maximum_bytes)),
      do: :ok,
      else: {:error, {:invalid_publication_review, :text}}
  end

  defp bounded_strings(_values, _maximum_count, _maximum_bytes, field),
    do: {:error, {:invalid_publication_review, field}}

  defp enum(value, values, field) do
    if value in values,
      do: :ok,
      else: {:error, {:invalid_publication_review, field}}
  end

  defp reference(value, field) do
    if is_binary(value) and Regex.match?(@reference, value),
      do: :ok,
      else: {:error, {:invalid_publication_review, field}}
  end

  defp bounded_text?(value, maximum) do
    is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
      :binary.match(value, <<0>>) == :nomatch and String.trim(value) != ""
  end

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{64}\z/, value)
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
