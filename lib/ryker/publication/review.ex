defmodule Ryker.Publication.Review do
  @moduledoc false
  alias Ryker.CanonicalJSON
  alias Ryker.Crypto
  alias Ryker.GitObject

  @required ~w(candidate_head candidate_retained candidate_tree creation_base gate job_digest not_publishable_reasons operation_id parent_head parent_tree patch_truncated policy_findings publishable rebase session_id session_revision source_head source_tree)
  @optional ~w(gate_error gate_output pull_request)
  # What Coop says of the gate's output beside the review; the output itself is
  # read page by page (`Ryker.Publication.GateOutput`).
  @gate_output_keys ~w(bytes command complete exit_code incomplete lost)
  @reference ~r/\A[A-Za-z0-9_.:-]{1,256}\z/

  # Every code Coop refuses a candidate with (internal/sessionsvc/review.go),
  # most actionable first, each worded to read on after "blocked: ". A gate
  # that did not run has no code of its own; the typed field says so.
  @refusals [
    {"rebase_conflict", "the change conflicts with the latest base branch"},
    {"gate_failed", "the repository's checks failed on the committed change"},
    {"gate_startup_error", "the repository's checks couldn't start"},
    {"gate_not_configured", "no checks are set up for the repository"},
    {"gate_modified_candidate", "running the checks changed the committed files"},
    {"no_changes", "the committed change has no differences from the base branch"},
    {"parent_moved", "the base branch moved while the change was being checked"},
    {"source_moved", "the working copy changed while it was being checked"},
    {"fork_owner_active", "the working copy was still in use while it was being checked"},
    {"gate_not_run", "the repository's checks didn't run"}
  ]
  # Findings are counted from the list they name, so their code needs no clause.
  @refusal_codes ["policy_findings" | Enum.map(@refusals, &elem(&1, 0))]
  @unrecognized_refusal "the review refused the change for a reason I don't recognize"

  # What Ryker does about a refusal without a person (`Ryker.Publication.FixLoop`).
  # The task's own work can fix these, most actionable first.
  @fixable ~w(rebase_conflict gate_failed gate_modified_candidate)
  # These say only that something moved while the change was being checked.
  @momentary ~w(parent_moved source_moved fork_owner_active)

  # Coop's policy scan (internal/sessionsvc/review_scan.go) words each finding
  # as one of these sentences around the path it names. The last is a file that
  # runs on a host, in Coop's own description of how.
  @finding_shapes [
    {~r/\Asecret-like file: (?<path>.+)\z/u, "looks like a file that holds secrets"},
    {~r/\Apossible secret in (?<path>.+) — remove the credential before publication\z/u,
     "may contain a credential"},
    {~r/\A(?<path>.+) adds a (?<script>preinstall|install|postinstall|prepare) script — npm runs it automatically on install\z/u,
     :install_script},
    {~r/\A(?<path>.+) cannot be inspected for automatic install scripts\z/u,
     "couldn't be checked for automatic install scripts"},
    {~r/\A(?<path>.+) — (?<effect>(?:Runs|Selects|Changes|Starts|Provides|Can run|Defines) [^—]+)\.\z/u,
     :effect}
  ]

  @spec prepare(map(), map()) :: {:ok, map()} | {:error, term()}
  def prepare(document, expected) when is_map(document) and is_map(expected) do
    # Publication retains identity, not the bounded display preview or source projection.
    document = Map.drop(document, ["patch", "source"])

    with :ok <- fields(document),
         :ok <- reference(document["operation_id"], :operation_id),
         true <- document["session_id"] == expected.session_id,
         true <- document["session_revision"] == expected.revision,
         true <- digest?(document["job_digest"]),
         :ok <- git_identities(document),
         :ok <- enum(document["gate"], ~w(passed failed startup_error not_run none), :gate),
         :ok <- enum(document["rebase"], ~w(clean conflict), :rebase),
         true <- is_boolean(document["patch_truncated"]),
         true <- is_boolean(document["candidate_retained"]),
         true <- is_boolean(document["publishable"]),
         :ok <- bounded_strings(document["policy_findings"], 64, 4_096, :policy_findings),
         :ok <-
           bounded_strings(
             document["not_publishable_reasons"],
             64,
             256,
             :not_publishable_reasons
           ),
         :ok <- candidate_identity(document),
         :ok <- pull_request(document["pull_request"]),
         :ok <- gate_output(document["gate_output"]),
         :ok <- CanonicalJSON.validate(document, max_bytes: 512 * 1_024) do
      {:ok, document}
    else
      false -> {:error, {:invalid_publication_review, :identity}}
      {:error, reason} -> {:error, reason}
    end
  end

  def prepare(_document, _expected), do: {:error, {:invalid_publication_review, :document}}

  def fingerprint(document),
    do: document |> CanonicalJSON.encode!() |> Crypto.sha256_hex()

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

  @doc """
  Whether the repository has no checks to run at all.

  Nothing failed and nothing is missing that the change could fix, the same
  as a pull request whose CI has no checks: the task card marks both skipped.
  """
  @spec no_checks?(term()) :: boolean()
  def no_checks?(%{"gate" => "none"} = document),
    do: not (is_binary(document["gate_error"]) and document["gate_error"] != "")

  def no_checks?(_document), do: false

  @spec draft_shareable?(term()) :: boolean()
  def draft_shareable?(document), do: draft_verdict(document)["shareable"]

  @doc """
  How the repository's checks failed, as a sentence, or `nil` when they did not.

  A gate that ran and failed is deliberately not an incomplete check: it has a
  result, and `incomplete_checks/1` answers why a required check has none. Both
  still have to fail the stage that reports whether the change was checked, so
  this is the other half, named apart rather than folded in.
  """
  @spec gate_failure(term()) :: String.t() | nil
  def gate_failure(%{"gate" => "failed"} = document),
    do: with_gate_error(gate_reason("failed"), document["gate_error"])

  def gate_failure(_document), do: nil

  @doc "Whether the repository's checks said anything about why they stopped."
  @spec gate_error?(term()) :: boolean()
  def gate_error?(%{"gate_error" => error}) when is_binary(error), do: String.trim(error) != ""
  def gate_error?(_document), do: false

  @doc """
  Why the trusted review refused a candidate, one clause per cause, each
  reading on after "blocked: ". Empty only when the review names no cause.

  Coop refuses with codes. On 2026-09-28 the review card printed "Blocked by:
  gate_failed" and the task card, reading only the publication's own error
  code, said no cause was recorded. A code this host does not know still says
  the review refused the change, and never echoes the code. Policy findings
  come last, so a list of the files they name can follow them.
  """
  @spec refusal(term()) :: [String.t()]
  def refusal(document) when is_map(document) do
    codes = codes(document)
    unrecognized? = Enum.any?(codes, &(&1 not in @refusal_codes))

    for({code, clause} <- @refusals, code in codes, do: clause) ++
      if(unrecognized?, do: [@unrecognized_refusal], else: []) ++
      findings_refusal(document["policy_findings"], "policy_findings" in codes)
  end

  def refusal(_document), do: []

  @doc """
  What Ryker does about a refused review without a person, or nil for a
  publishable one.

  `:fix` sends the change back to its task's work: the repository's checks
  failed, the change conflicts with the latest base branch, or running the
  checks changed its files. `:recheck` asks the review again unchanged: the
  base branch or the working copy moved, or the working copy was still in use,
  while the change was being checked, which says nothing about the change.
  `:person` is everything else. A policy finding such as a possible credential
  is a person's call whatever else the review found; a change with no
  differences from its base has nothing to fix; missing or unstartable checks
  are a setting or a machine, and the agent writing the check that judges its
  own change would be no check at all; and a reason this host cannot read is
  never guessed at (Andrew's request, 2026-09-28).
  """
  @spec remedy(term()) :: :fix | :recheck | :person | nil
  def remedy(%{"publishable" => true}), do: nil

  def remedy(document) when is_map(document) do
    codes =
      if match?([_ | _], document["policy_findings"]),
        do: Enum.uniq(codes(document) ++ ["policy_findings"]),
        else: codes(document)

    cond do
      not is_list(document["policy_findings"]) -> :person
      codes == [] or codes -- (@fixable ++ @momentary) != [] -> :person
      Enum.any?(codes, &(&1 in @fixable)) -> :fix
      true -> :recheck
    end
  end

  def remedy(_document), do: :person

  @doc """
  The refusal codes the task's work is asked to fix, most actionable first:
  what a fix round's message and the task card name.
  """
  @spec fixable(term()) :: [String.t()]
  def fixable(document) when is_map(document) do
    codes = codes(document)
    Enum.filter(@fixable, &(&1 in codes))
  end

  def fixable(_document), do: []

  defp codes(document) do
    codes =
      [gate_refusal(document["gate"]), rebase_refusal(document["rebase"])]
      |> Enum.reject(&is_nil/1)
      |> Kernel.++(refusal_codes(document["not_publishable_reasons"]))
      |> Enum.uniq()

    # A gate never runs on a change that no longer applies: that is the
    # conflict, not a second cause to fix.
    if "rebase_conflict" in codes, do: codes -- ["gate_not_run"], else: codes
  end

  @doc """
  Each policy finding as the file it names and what is wrong with it, in the
  host's words, or `:unrecognized` for a finding worded some other way.

  A finding is Coop's sentence around a path the change chose. Printing it
  whole let that path read as part of the explanation; a shape Coop has not
  used before is counted by the caller, never echoed.
  """
  @spec findings(term()) :: [{String.t(), String.t()} | :unrecognized]
  def findings(findings) when is_list(findings), do: Enum.map(findings, &finding/1)
  def findings(_findings), do: []

  defp finding(text) when is_binary(text) do
    Enum.find_value(@finding_shapes, :unrecognized, fn {shape, problem} ->
      case Regex.named_captures(shape, text) do
        %{"path" => path} = captures -> {path, finding_problem(problem, captures)}
        nil -> nil
      end
    end)
  end

  defp finding(_text), do: :unrecognized

  defp finding_problem(:install_script, %{"script" => script}),
    do: "adds an npm #{script} script, which runs automatically on install"

  defp finding_problem(:effect, %{"effect" => <<first::utf8, rest::binary>>}),
    do: String.downcase(<<first::utf8>>) <> rest

  defp finding_problem(problem, _captures), do: problem

  defp gate_refusal("failed"), do: "gate_failed"
  defp gate_refusal("startup_error"), do: "gate_startup_error"
  defp gate_refusal("none"), do: "gate_not_configured"
  defp gate_refusal("not_run"), do: "gate_not_run"
  defp gate_refusal(_gate), do: nil

  defp rebase_refusal("conflict"), do: "rebase_conflict"
  defp rebase_refusal(_rebase), do: nil

  defp refusal_codes(codes) when is_list(codes), do: Enum.filter(codes, &is_binary/1)
  defp refusal_codes(_codes), do: []

  defp findings_refusal([_finding | _rest] = findings, _named?) do
    count = length(findings)
    ["the safety scan flagged #{count} issue#{if count == 1, do: "", else: "s"} in the change"]
  end

  defp findings_refusal(_findings, true), do: ["the safety scan flagged the change"]
  defp findings_refusal(_findings, false), do: []

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

  defp gate_reason("failed"), do: "The repository's checks failed."
  defp gate_reason(gate) when gate in ~w(passed startup_error not_run none), do: nil
  defp gate_reason(_gate), do: "The repository's checks have no known result."

  defp rebase_reason("clean"), do: nil
  defp rebase_reason(_rebase), do: "The change no longer applies to the current base."

  defp findings_reason([]), do: nil

  defp findings_reason(findings) when is_list(findings) do
    "The trusted policy review found #{length(findings)} issue#{if length(findings) == 1, do: "", else: "s"}."
  end

  defp findings_reason(_findings), do: "The trusted policy review is unreadable."

  defp snapshot_reason(document) do
    exact =
      document["candidate_retained"] == true and
        git_identities(document) == :ok and
        document["candidate_tree"] != document["parent_tree"]

    if exact, do: nil, else: "No exact complete snapshot of the change was retained."
  end

  # Why a required check has no result is the operator-facing half of "checks
  # unavailable"; without it the card can only say that something is missing.
  defp incomplete_checks(%{"gate" => "passed"}), do: []

  defp incomplete_checks(%{"gate" => gate} = document)
       when gate in ~w(startup_error not_run none),
       do: [with_gate_error(incomplete_check_label(gate), document["gate_error"])]

  defp incomplete_checks(_document), do: []

  # In the words the refusals above use for the same checks.
  defp incomplete_check_label("startup_error"), do: "The repository's checks couldn't start."
  defp incomplete_check_label("not_run"), do: "The repository's checks didn't run."
  defp incomplete_check_label("none"), do: "No checks are set up for the repository."

  # The gate's own error is a fragment ("docker: command not found"), so it
  # follows the sentence that says which checks it belongs to: every surface
  # can then print it as a sentence instead of in brackets.
  defp with_gate_error(sentence, error) when is_binary(error) do
    case String.trim(error) do
      "" -> sentence
      error -> String.trim_trailing(sentence, ".") <> ": " <> full_stop(error)
    end
  end

  defp with_gate_error(sentence, _error), do: sentence

  defp full_stop(text),
    do: if(String.ends_with?(text, [".", "!", "?"]), do: text, else: text <> ".")

  defp gate_output(nil), do: :ok

  defp gate_output(%{"bytes" => bytes, "complete" => complete} = output)
       when is_integer(bytes) and bytes >= 0 and is_boolean(complete) do
    if Map.keys(output) -- @gate_output_keys == [] and gate_command?(output["command"]) and
         optional?(output["exit_code"], &is_integer/1) and
         Enum.all?(~w(incomplete lost), &optional?(output[&1], fn text -> is_binary(text) end)),
       do: :ok,
       else: {:error, {:invalid_publication_review, :gate_output}}
  end

  defp gate_output(_output), do: {:error, {:invalid_publication_review, :gate_output}}

  defp gate_command?(nil), do: true
  defp gate_command?(command), do: bounded_strings(command, 64, 4_096, :gate_output) == :ok

  defp optional?(nil, _valid?), do: true
  defp optional?(value, valid?), do: valid?.(value)

  defp fields(document) do
    keys = Map.keys(document)

    if Enum.all?(@required, &(&1 in keys)) and Enum.all?(keys, &(&1 in (@required ++ @optional))),
      do: :ok,
      else: {:error, {:invalid_publication_review, :fields}}
  end

  defp git_identities(document) do
    if Enum.all?(
         ~w(candidate_head candidate_tree creation_base parent_head parent_tree source_head source_tree),
         &GitObject.id?(document[&1])
       ) do
      :ok
    else
      {:error, {:invalid_publication_review, :git_identity}}
    end
  end

  defp candidate_identity(%{"publishable" => true} = document) do
    with true <- is_nil(snapshot_reason(document)),
         true <- document["gate"] == "passed" and document["rebase"] == "clean",
         true <- document["policy_findings"] == [],
         true <- document["not_publishable_reasons"] == [] do
      :ok
    else
      false -> {:error, {:invalid_publication_review, :publishable}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp candidate_identity(%{"publishable" => false}), do: :ok

  defp pull_request(nil), do: :ok

  defp pull_request(%{"head_commit" => head, "number" => number, "ref" => ref} = pull_request)
       when map_size(pull_request) == 3 and is_binary(head) and is_integer(number) and number > 0 do
    if GitObject.id?(head) and bounded_text?(ref, 256),
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
end
