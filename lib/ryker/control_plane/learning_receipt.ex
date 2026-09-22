defmodule Ryker.ControlPlane.LearningReceipt do
  @moduledoc "Inspection of exact saved learning attempts, including rejected and no-change results."
  import Ecto.Query
  use Phoenix.Component

  import Ryker.ControlPlane.Components, only: [execution_target: 1]

  alias Ryker.ControlPlane.{
    InspectionRedactor,
    LearningActivity,
    PromptDocument,
    SlackMarkdown,
    SourceText
  }

  alias Ryker.Repo
  alias Ryker.State.{KnowledgeRevision, LearningRun}

  def project(id, version, secrets) when is_binary(id) and is_binary(version) do
    with {number, ""} when number in 1..9_223_372_036_854_775_807 <- Integer.parse(version),
         %{} = revision <- Repo.get_by(KnowledgeRevision, knowledge_id: id, version: number),
         [_, run_id, digest] <- reference(revision.source_result_ref),
         %{status: :applied, result_sha256: ^digest} = run <- Repo.get(LearningRun, run_id) do
      receipt(run, number, secrets)
    else
      _ -> nil
    end
  end

  def project(_, _, _), do: nil

  def project_attempt(batch_id, run_id, secrets) do
    with {:ok, ^batch_id} <- Ecto.UUID.cast(batch_id),
         {:ok, ^run_id} <- Ecto.UUID.cast(run_id),
         %{} = run <-
           Repo.one(from(r in LearningRun, where: r.id == ^run_id and r.batch_id == ^batch_id)) do
      receipt(run, nil, secrets)
    else
      _ -> nil
    end
  end

  def path(revision) do
    if reference(revision.source_result_ref) do
      "/memory?" <>
        URI.encode_query(%{
          "kind" => "knowledge",
          "item" => revision.knowledge_id,
          "update" => revision.version
        }) <> "#learning-receipt"
    end
  end

  defp reference(value) when is_binary(value),
    do:
      Regex.run(
        ~r/\Alearning:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}):([0-9a-f]{64})\z/,
        value
      )

  defp reference(_), do: nil

  defp receipt(run, version, secrets) do
    expired = not is_nil(run.pruned_at)
    prompt = document(run.prompt, secrets)
    result = document(run.result, secrets)
    producer = document(run.producer, secrets)

    %{
      id: run.id,
      version: version,
      attempt_number: LearningActivity.attempt_number(run),
      status: run.status,
      outcome: outcome(run.status, result),
      at: run.applied_at || run.inserted_at,
      error: LearningActivity.error(run.error_code),
      expired: expired,
      input_count: length(run.inputs),
      reason: result["reason"],
      target: producer["target"] || producer["model"] || "Model not recorded",
      sections: if(expired, do: [], else: sections(run, prompt, result, secrets))
    }
  end

  defp sections(run, prompt, _result, secrets) do
    [
      section(
        "inputs",
        "Source messages",
        "The messages supplied together, in the order submitted to the model.",
        prompt["inputs"],
        secrets
      ),
      section(
        "knowledge",
        "Prior knowledge",
        "The exact topic versions offered before this update, not today's memory.",
        prompt["knowledge"],
        secrets
      ),
      section(
        "instructions",
        "Learning instructions",
        "How Ryker asked the model to maintain useful knowledge without replying.",
        prompt["instructions"],
        secrets
      ),
      section(
        "custom_instructions",
        "Custom instructions",
        "The global and channel text, scopes and revisions retained with this learning attempt, not today's settings.",
        prompt["custom_instructions"],
        secrets
      ),
      section(
        "contract",
        "Response format",
        "The output contract supplied alongside the prompt text.",
        run.output_schema,
        secrets
      ),
      section(
        "prompt",
        "Full submitted prompt",
        "Ryker's complete prompt text. The response format is supplied separately above; provider-owned instructions are not recorded here.",
        run.prompt,
        secrets
      ),
      section(
        "result",
        "Model response",
        "Proposed topic updates from this attempt. The attempt outcome says whether they were applied.",
        run.result,
        secrets
      ),
      section(
        "validation",
        "Validation details",
        "The host's recorded checks and remote stop receipt.",
        %{
          "validation" => run.validation_receipt,
          "stop" => run.stop_receipt,
          "error_code" => run.error_code
        },
        secrets
      )
    ]
    |> Enum.reject(
      &(&1.id == "validation" and is_nil(run.validation_receipt) and is_nil(run.stop_receipt) and
          is_nil(run.error_code))
    )
  end

  defp section(id, title, description, value, secrets) do
    artifact = InspectionRedactor.artifact(value, secrets: secrets, preserve_format: true)

    %{
      id: id,
      title: title,
      description: description,
      artifact: artifact,
      value: displayed_value(artifact),
      tokens: if(artifact.text, do: ceil(byte_size(artifact.text) / 4), else: 0)
    }
  end

  defp displayed_value(%{text: text}) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, value} -> value
      _ -> text
    end
  end

  defp displayed_value(_), do: nil

  defp document(value, secrets) do
    case InspectionRedactor.artifact(value, secrets: secrets).text do
      nil ->
        %{}

      text ->
        case Jason.decode(text) do
          {:ok, %{} = parsed} -> parsed
          _ -> %{}
        end
    end
  end

  def render(assigns) do
    ~H"""
    <section class="learning-receipt" id="learning-receipt" aria-label="Learning receipt">
      <div class="learning-receipt-heading">
        <p class="ui-eyebrow">LEARNING WITHOUT REPLYING</p>
        <h2>
          {if @receipt.version,
            do: "How update #{@receipt.version} was learned",
            else: "Learning attempt #{@receipt.attempt_number}"}
        </h2>
        <div class="learning-receipt-meta">
          <span>{@receipt.input_count} messages</span>
          <.execution_target target={@receipt.target} compact />
        </div>
      </div>
      <p :if={!@receipt.version}>{@receipt.outcome}</p>
      <p>No reply was sent by this learning pass.</p>
      <p :if={@receipt.error} class="memory-unavailable">{@receipt.error}</p>
      <p :if={@receipt.reason} class="learning-reason">{@receipt.reason}</p>
      <p :if={@receipt.expired} class="memory-unavailable">
        The saved request and response expired under the conversation memory retention policy.
        The update identity and outcome remain; no old content is reconstructed.
      </p>
      <details :for={section <- @receipt.sections} class="learning-part" id={"learning-#{section.id}"}>
        <summary>
          <strong>{section.title}</strong><span>≈ {section.tokens} estimated tokens</span>
        </summary>
        <p>{section.description}</p>
        <p :if={section.artifact.state != :retained}>Not recorded.</p>
        <.part :if={section.artifact.state == :retained} section={section} />
      </details>
      <p :if={!@receipt.expired} class="learning-estimate">
        Token counts estimate the displayed, redacted text; they are not provider usage receipts.
      </p>
    </section>
    """
  end

  defp part(%{section: %{id: "inputs"}} = assigns) do
    ~H"""
    <article :for={{input, index} <- Enum.with_index(@section.value || [], 1)} class="learning-source">
      <div class="learning-source-heading">
        <strong>Message {index}</strong><time>{input["occurred_at"]}</time>
      </div>
      <div class="markdown-preview">
        {Phoenix.HTML.raw(
          SlackMarkdown.preview(
            SourceText.from_content(input["content"]) || "No readable message text.",
            get_in(input, ["source", "ref"])
          )
        )}
      </div>
      <details>
        <summary>Full message fields</summary><pre class="model-document-text" tabindex="0">{Jason.encode!(input, pretty: true)}</pre>
      </details>
    </article>
    """
  end

  defp part(%{section: %{id: "knowledge"}} = assigns) do
    ~H"""
    <p :if={@section.value == []}>No prior topics were supplied.</p>
    <article :for={item <- @section.value || []} class="learning-source">
      <div class="learning-source-heading">
        <strong>{item["title"] || item["topic_key"]}</strong><span>Version {item["version"]}</span>
      </div>
      <div class="markdown-preview">
        {Phoenix.HTML.raw(SlackMarkdown.preview(item["summary"] || "", nil))}
      </div>
      <details>
        <summary>Full topic fields</summary><pre class="model-document-text" tabindex="0">{Jason.encode!(item, pretty: true)}</pre>
      </details>
    </article>
    """
  end

  defp part(%{section: %{id: "result", value: value}} = assigns) when is_map(value) do
    ~H"""
    <article :for={update <- @section.value["updates"] || []} class="learning-source">
      <div class="learning-source-heading">
        <strong>{update["title"] || "No topic change proposed"}</strong><span>{proposal_label(update)}</span>
      </div>
      <div class="markdown-preview">
        {Phoenix.HTML.raw(SlackMarkdown.preview(update["summary"] || update["reason"] || "", nil))}
      </div>
    </article>
    <details>
      <summary>Full response fields</summary><pre class="model-document-text" tabindex="0">{@section.artifact.text}</pre>
    </details>
    """
  end

  defp part(%{section: %{id: "prompt"}} = assigns) do
    ~H"""
    <div class="prompt-assembly">{Phoenix.HTML.raw(PromptDocument.render(@section.artifact))}</div>
    """
  end

  defp part(%{section: %{id: "custom_instructions", value: value}} = assigns)
       when is_map(value) do
    ~H"""
    {Phoenix.HTML.raw(Ryker.ControlPlane.RequestContextHTML.instruction_layers(@section.value))}
    """
  end

  defp part(assigns) do
    ~H"""
    <pre class="model-document-text" tabindex="0">{@section.artifact.text}</pre>
    """
  end

  defp proposal_label(%{"action" => "defer"}), do: "Deferred"
  defp proposal_label(%{"action" => "update"}), do: "Proposed update"
  defp proposal_label(%{"action" => "create"}), do: "Proposed new topic"
  defp proposal_label(_), do: "Proposed topic change"

  defp outcome(:applied, %{"updates" => updates}) when is_list(updates) do
    if Enum.all?(updates, &(&1["action"] == "defer")),
      do: "No change needed",
      else: "Knowledge updated"
  end

  defp outcome(:applied, _), do: "Learning completed"
  defp outcome(status, _), do: LearningActivity.label(status)
end
