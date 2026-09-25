defmodule Ryker.ControlPlane.InstructionsEditor do
  @moduledoc """
  The instructions editor for the global scope (on /instructions) and for one
  channel (on its page). Saving is explicit; a live refresh never overwrites
  an unsaved draft, and a save that races another one keeps the draft and
  shows what was saved meanwhile.
  """
  use Phoenix.LiveComponent
  alias Ryker.ControlPlane.{Components, Kit}
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
         |> assign(:message, "Instructions saved. Ryker uses them from its next step.")}

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
    do: "This text is larger than 8,192 bytes. Shorten it; your draft is preserved."

  defp error(:instructions_scope_unavailable),
    do: "This channel is no longer available for editing. Your draft has not been saved."

  defp error(_),
    do:
      "The instructions could not be saved. Check the text and try again; your draft is preserved."

  # The quiet line under the text: what is left, and the byte size only once
  # it is close enough to the 8 KiB limit to matter (emoji and some scripts
  # take several bytes a character).
  defp character_count(text) do
    left =
      case 2_000 - String.length(text) do
        remaining when remaining >= 0 -> "#{delimit(remaining)} characters left"
        -1 -> "1 character over the limit"
        over -> "#{delimit(-over)} characters over the limit"
      end

    if byte_size(text) > 6_144,
      do: left <> " · #{delimit(byte_size(text))} of 8,192 bytes",
      else: left
  end

  defp delimit(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp label(:global), do: "Instructions for every conversation"
  defp label(_channel), do: "Instructions for this channel"

  defp placeholder(:global), do: "Keep replies concise. Separate observed facts from guesses."

  defp placeholder(_channel),
    do: "Include the affected service and time window when reporting an incident."

  defp current_text(%{text: ""}), do: "Nothing. The saved instructions are empty."
  defp current_text(%{text: text}), do: text

  defp saved_on(at) do
    if at.year == Date.utc_today().year,
      do: Calendar.strftime(at, "%-d %b"),
      else: Calendar.strftime(at, "%-d %b %Y")
  end

  defp saved_title(at), do: Calendar.strftime(at, "%d %b %Y, %H:%M UTC")

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- On /instructions this is the "For every conversation" section; a
    channel's page gives the channel editor its own heading around it. --%>
    <section
      id={@id}
      class="instructions-editor"
      aria-labelledby={if @scope == :global, do: @id <> "-head"}
      aria-label={if @scope != :global, do: label(@scope)}
    >
      <Kit.section_head :if={@scope == :global} id={@id <> "-head"} title="For every conversation" />
      <div :if={@view.global} class="inherited-instructions">
        <p class="inherited-head">
          <span>For every conversation</span>
          <.link navigate="/instructions">Edit<span class="sr-only"> the instructions for every conversation</span></.link>
        </p>
        <p :if={@view.global.text == ""} class="inherited-empty">Nothing saved yet.</p>
        <%!-- pre-wrap text: whitespace inside these paragraphs is content. --%>
        <p
          :if={@view.global.text != ""}
          id="inherited-instructions"
          class="inherited-text"
          phx-no-format
        >{@view.global.text}</p>
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
        <label class="sr-only" for="instructions-text">{label(@scope)}</label>
        <textarea
          id="instructions-text"
          name="text"
          rows="4"
          aria-describedby="instructions-count"
          aria-invalid={to_string(not is_nil(@error))}
          placeholder={placeholder(@scope)}
        >{@draft}</textarea>
        <Components.form_feedback :if={@error} message={@error} tone={:error} />
        <div :if={@conflict} class="instructions-conflict">
          <p>Someone saved these instructions while you were editing:</p>
          <p id="instructions-current" class="instructions-current" phx-no-format>{current_text(@conflict)}</p>
          <button
            type="button"
            class="ui-button secondary"
            phx-click="review-current"
            phx-target={@myself}
          >Keep my draft and review against this version</button>
        </div>
        <div class="instructions-footer">
          <p class="instructions-meta">
            <span id="instructions-count">{character_count(@draft)}</span><span :if={@saved.saved_at}> · saved
              <time
              datetime={DateTime.to_iso8601(@saved.saved_at)}
              title={saved_title(@saved.saved_at)}
            >{saved_on(@saved.saved_at)}</time></span>
          </p>
          <span role="status" class="instructions-message">{@message}</span>
          <div class="instructions-actions">
            <button
              :if={@dirty}
              type="button"
              class="ui-button secondary"
              phx-click="cancel"
              phx-target={@myself}
            >Cancel</button><button
              type="submit"
              class="ui-button primary"
              disabled={!@dirty or not is_nil(@conflict)}
              phx-disable-with="Saving…"
            >Save</button>
          </div>
        </div>
      </form>
    </section>
    """
  end
end
