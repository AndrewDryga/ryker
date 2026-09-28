defmodule Ryker.ControlPlane.RequestPage do
  @moduledoc """
  A model's checked answer as the Timeline shows it under the check that read
  it, and the recorded response a turn's latest answer is kept as.
  """
  use Phoenix.Component
  import Ryker.ControlPlane.Components

  # An answer sent exactly as it was checked is read once, in the
  # conversation, so its card keeps only what the conversation does not show
  # (`sent`). A title is shown only where the answer changed the request's
  # title (`title_update`); a title that stayed the same says nothing.
  def candidate_response(assigns) do
    assigns =
      assigns
      |> assign_new(:sent, fn -> false end)
      |> assign_new(:title_update, fn -> nil end)
      |> assign(:document, candidate_document(assigns.response))
      |> assign(:response_meta, candidate_response_meta(assigns.response))

    ~H"""
    <section
      :if={@response.state == :retained}
      class="candidate-response"
      id={"#{@prefix}-response-#{@attempt}"}
    >
      <div id={"#{@prefix}-response-#{@attempt}-body"} class="candidate-response-body" tabindex="-1">
        <.message_block
          :if={@document && is_binary(@document["message"]) && !@sent}
          sender="Ryker"
        >
          {Phoenix.HTML.raw(Ryker.ControlPlane.SlackMarkdown.preview(@document["message"]))}
        </.message_block>
        <p
          :if={@document && is_binary(@document["decision_reason"])}
          class="candidate-decision-reason"
        >
          {@document["decision_reason"]}
        </p>
        <.title_update :if={@title_update} title={@title_update} />
        <.disclosure
          id={"#{@prefix}-response-#{@attempt}-raw"}
          label="Raw response"
          kind={:source}
          class="candidate-response-raw"
        >
          <:meta>{@response_meta}</:meta>
          <.copy_block label="Copy JSON">
            <pre class="model-document-text" tabindex="0">{@response.text}</pre>
          </.copy_block>
        </.disclosure>
      </div>
    </section>
    <p :if={@response.state == :expired} class="artifact-unavailable">
      Response body expired for this attempt. Its check receipt is preserved here.
    </p>
    """
  end

  defp candidate_document(%{state: :retained, truncated: false, text: text}) do
    case Jason.decode(text) do
      {:ok, %{} = document} -> document
      _ -> nil
    end
  end

  defp candidate_document(_), do: nil

  defp candidate_response_meta(response) do
    kind = if candidate_document(response), do: "JSON", else: "Text"

    [
      kind,
      response_size(response.bytes),
      response.truncated && "Display truncated"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" · ")
  end

  defp response_size(nil), do: "Size not recorded"
  defp response_size(count) when count < 1_024, do: "#{count} bytes"
  defp response_size(count), do: "#{div(count, 1_024)} KiB"

  def latest_archived_response(sections) do
    with %{artifact: %{state: :retained, sha256: digest}} <-
           Enum.find(sections, &(&1.id == "candidate")),
         %{artifact: %{state: :retained, truncated: false, text: text}, responses: responses} <-
           Enum.find(sections, &(&1.id == "validation")),
         {:ok, %{"candidate_attempt" => attempt, "history" => history}} when is_list(history) <-
           Jason.decode(text),
         %{"candidate_sha256" => ^digest} <-
           Enum.find(history, &(is_map(&1) && &1["candidate_attempt"] == attempt)),
         %{state: :retained, sha256: ^digest} = artifact <- responses[attempt] do
      %{attempt: attempt, artifact: artifact}
    else
      _ -> nil
    end
  end
end
