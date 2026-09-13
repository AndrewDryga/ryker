defmodule Ryker.ControlPlane.InstructionsEditor do
  @moduledoc "Explicit two-scope editor; live refresh never overwrites an unsaved draft."
  use Phoenix.LiveComponent
  alias Ryker.Instructions

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      cond do
        not Map.has_key?(socket.assigns, :draft) ->
          reset(socket, assigns.view.setting)

        not socket.assigns.dirty and socket.assigns.saved != assigns.view.setting ->
          reset(socket, assigns.view.setting)

        true ->
          socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("edit", %{"text" => text, "revision" => revision}, socket)
      when is_binary(text),
      do:
        {:noreply,
         draft(socket, text)
         |> assign(
           message: "",
           error: if(socket.assigns.conflict, do: socket.assigns.error),
           expected_revision: revision(revision)
         )}

  def handle_event("cancel", _, socket),
    do: {:noreply, reset(socket, socket.assigns.view.setting)}

  def handle_event("review-current", _, socket) do
    current = socket.assigns.conflict

    {:noreply,
     socket
     |> assign(saved: current, expected_revision: current.revision, conflict: nil, error: nil)
     |> draft(socket.assigns.draft)}
  end

  def handle_event("save", %{"text" => text, "revision" => revision}, socket)
      when is_binary(text) do
    socket = draft(socket, text) |> assign(:expected_revision, revision(revision))

    case socket.assigns.save.(socket.assigns.scope, text, socket.assigns.expected_revision) do
      {:ok, saved} ->
        view = %{socket.assigns.view | setting: saved}

        {:noreply,
         socket
         |> assign(:view, view)
         |> reset(saved)
         |> assign(:message, "Instructions saved. They apply to the next model turn.")}

      {:error, {:instructions_conflict, current}} ->
        {:noreply,
         assign(socket,
           view: %{socket.assigns.view | setting: current},
           conflict: current,
           error:
             "The saved instructions changed since you started editing. Your draft has not been saved."
         )}

      {:error, reason} ->
        {:noreply, assign(socket, :error, error(reason))}
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:noreply,
       socket
       |> draft(text)
       |> assign(:expected_revision, revision(revision))
       |> assign(
         :error,
         "The save could not be confirmed. Your draft is preserved; check the current saved text before retrying."
       )}
  end

  defp reset(socket, saved),
    do:
      assign(socket,
        saved: saved,
        expected_revision: saved.revision,
        draft: saved.text,
        dirty: false,
        error: nil,
        conflict: nil,
        message: ""
      )

  defp revision(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> number
      _ -> nil
    end
  end

  defp revision(_), do: nil

  defp draft(socket, text) do
    text = String.replace(text, "\r\n", "\n")

    assign(socket,
      draft: text,
      dirty: Instructions.normalize_text(text) != {:ok, socket.assigns.saved.text}
    )
  end

  defp error({:invalid_instructions, :characters}),
    do: "Use at most 2,000 characters. Your draft is preserved."

  defp error({:invalid_instructions, :bytes}),
    do: "This text exceeds 8 KiB of UTF-8 data. Shorten it; your draft is preserved."

  defp error(:instructions_scope_unavailable),
    do: "This channel is no longer available for editing. Your draft has not been saved."

  defp error(_),
    do:
      "The instructions could not be saved. Check the text and try again; your draft is preserved."

  defp character_count(text) do
    case 2_000 - String.length(text) do
      remaining when remaining >= 0 -> "#{remaining} characters remaining"
      -1 -> "1 character over the limit"
      over -> "#{-over} characters over the limit"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="instructions-editor" aria-labelledby="instructions-label">
      <div :if={@view.global} class="inherited-instructions">
        <div class="instructions-heading">
          <h2>Inherited global instructions</h2><.link navigate="/instructions">Edit global instructions →</.link>
        </div>
        <p :if={@view.global.text == ""} class="muted">No global instructions are saved.</p>
        <pre :if={@view.global.text != ""} id="inherited-instructions">{@view.global.text}</pre>
      </div>
      <form
        id="instructions-form"
        phx-hook="InstructionDraft"
        phx-change="edit"
        phx-submit="save"
        phx-target={@myself}
        data-dirty={to_string(@dirty)}
        data-saved-text={@saved.text}
        data-scope={@view.setting.scope_ref}
      >
        <input type="hidden" name="revision" value={@expected_revision} />
        <label id="instructions-label" for="instructions-text">{if @scope == :global,
          do: "Global instructions",
          else: "Channel instructions"}</label>
        <p id="instructions-help">
          {if @scope == :global,
            do: "These instructions guide Ryker in every conversation.",
            else:
              "Adds instructions for this channel. Channel instructions take priority if they conflict with global instructions."}
        </p>
        <textarea
          id="instructions-text"
          name="text"
          rows="8"
          aria-describedby="instructions-help instructions-count instructions-timing"
          aria-invalid={to_string(not is_nil(@error))}
          placeholder={
            if @scope == :global,
              do: "Keep replies concise. Separate observed facts from guesses.",
              else: "Include the affected service and time window when reporting an incident."
          }
        >{@draft}</textarea>
        <div class="instructions-meta">
          <span id="instructions-count">{character_count(@draft)} · {byte_size(@draft)} / 8,192 bytes</span><span :if={
            @saved.saved_at
          }>Saved
          <time datetime={DateTime.to_iso8601(@saved.saved_at)}>{Calendar.strftime(
            @saved.saved_at,
            "%d %b, %H:%M UTC"
          )}</time>
          by {@saved.saved_by}</span>
        </div>
        <p id="instructions-timing" class="muted">
          Changes apply to the next model turn. Work already submitted keeps its current instructions. Clear and save to remove this scope's instructions.
        </p>
        <p :if={@error} role="alert">{@error}</p>
        <div :if={@conflict} class="instructions-conflict">
          <h3>Currently saved</h3><pre id="instructions-current">{if @conflict.text == "", do: "No custom instructions.", else: @conflict.text}</pre><button
            type="button"
            class="ui-button secondary"
            phx-click="review-current"
            phx-target={@myself}
          >Keep my draft and review against this version</button>
        </div>
        <div class="instructions-actions">
          <button
            type="submit"
            class="ui-button primary"
            disabled={!@dirty or not is_nil(@conflict)}
            phx-disable-with="Saving…"
          >Save changes</button><button
            type="button"
            class="ui-button secondary"
            phx-click="cancel"
            phx-target={@myself}
            disabled={!@dirty}
          >Cancel</button><span role="status">{@message}</span>
        </div>
      </form>
      <p class="instructions-footnote">
        Instructions do not grant permissions or change participation settings. They are always supplied;
        <.link navigate="/guidance">Guidance</.link>
        is recalled when relevant. An authorized task request can override a standing style default.
      </p>
    </section>
    """
  end
end
