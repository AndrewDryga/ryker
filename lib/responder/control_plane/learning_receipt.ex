defmodule Responder.ControlPlane.LearningReceipt do
  @moduledoc "Inspection of the saved learning judgment that produced one knowledge revision."
  use Phoenix.Component
  alias Responder.ControlPlane.{InspectionRedactor, PromptDocument, SlackMarkdown, SourceText}
  alias Responder.Repo
  alias Responder.State.{KnowledgeRevision, LearningRun}

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
      at: run.applied_at,
      expired: expired,
      input_count: length(run.inputs),
      reason: result["reason"],
      target: producer["target"] || producer["model"] || "Model not recorded",
      sections: if(expired, do: [], else: sections(run, prompt, result, secrets))
    }
  end

  defp sections(run, prompt, result, secrets) do
    [
      section(
        "inputs",
        "Source messages",
        "The messages supplied together, in their original order.",
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
        "How Responder asked the model to maintain useful knowledge without replying.",
        prompt["instructions"],
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
        "Responder's complete prompt text. The response format is supplied separately above; provider-owned instructions are not recorded here.",
        run.prompt,
        secrets
      ),
      section(
        "result",
        "Model response",
        "The proposed topic updates accepted together in this learning pass.",
        result,
        secrets
      )
    ]
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
        <h2>How update {@receipt.version} was learned</h2>
        <p>{@receipt.input_count} messages · {@receipt.target}</p>
      </div>
      <p>No reply was sent by this learning pass.</p>
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

  defp part(%{section: %{id: "result"}} = assigns) do
    ~H"""
    <article :for={update <- @section.value["updates"] || []} class="learning-source">
      <div class="learning-source-heading">
        <strong>{update["title"]}</strong><span>{if update["target_ref"],
          do: "Topic updated",
          else: "Topic created"}</span>
      </div>
      <div class="markdown-preview">
        {Phoenix.HTML.raw(SlackMarkdown.preview(update["summary"] || "", nil))}
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

  defp part(assigns) do
    ~H"""
    <pre class="model-document-text" tabindex="0">{@section.artifact.text}</pre>
    """
  end
end
