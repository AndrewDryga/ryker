defmodule Ryker.ControlPlane.LabControls do
  @moduledoc """
  The confirmed controls of the conversation page: the composer's send token,
  each operator message's edit and delete forms, each reply's reaction form,
  and every record card's actions, minted here with the exact CSRF resource
  the HTTP router checks when the form comes back.

  Minting and validation share one module so the action names and resource
  strings cannot drift apart: a control the page renders is, by construction,
  one the router will accept, and nothing else is.
  """

  alias Ryker.ControlPlane.{CSRF, PathRef, Projection}

  @send_action "conversation_lab:send"
  @message_action "conversation_lab:message"
  @reaction_action "conversation_lab:reaction"
  @record_action "conversation_lab:record"

  @doc """
  The latest page of `conversation_id`, decorated with its controls, and the
  composer's send token. A conversation with no record yet is an empty page
  under the same identity; nothing is written by reading it.
  """
  def snapshot(conversation_id, options) do
    with {:ok, conversation_id} <- PathRef.uuid(conversation_id) do
      prepare_snapshot(conversation_id, options)
    end
  end

  # One older page of a conversation, decorated with the same edit, reaction
  # and record controls as the latest page so a row loaded by scrolling up is
  # exactly as usable as one that was on screen at open.
  def history(conversation_id, cursor, page_size, options) do
    with {:ok, conversation_id} <- PathRef.uuid(conversation_id),
         {:ok, page} <- options.projection.lab_history.(conversation_id, cursor, page_size) do
      decorated =
        %{conversation_id: conversation_id, messages: page.messages}
        |> message_controls(options.csrf_secret)
        |> record_controls(options.csrf_secret)

      {:ok, %{page | messages: decorated.messages}}
    else
      :not_found -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # The rows of a conversation that changed since a moment, decorated the
  # same way, so a live window can refresh a row it holds off the latest page.
  def changes(conversation_id, since, page_size, options) do
    with {:ok, conversation_id} <- PathRef.uuid(conversation_id),
         {:ok, messages} <- options.projection.lab_changes.(conversation_id, since, page_size) do
      decorated =
        %{conversation_id: conversation_id, messages: messages}
        |> message_controls(options.csrf_secret)
        |> record_controls(options.csrf_secret)

      {:ok, decorated.messages}
    else
      :not_found -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_snapshot(conversation_id, options) do
    snapshot =
      case options.projection.lab_conversation.(conversation_id) do
        {:ok, snapshot} -> snapshot
        :not_found -> empty_conversation(conversation_id)
        {:error, _reason} -> nil
      end

    if snapshot do
      token = CSRF.token(options.csrf_secret, @send_action, conversation_id)

      snapshot =
        snapshot
        |> message_controls(options.csrf_secret)
        |> record_controls(options.csrf_secret)

      {:ok, snapshot, token}
    else
      {:error, :projection_unavailable}
    end
  end

  defp message_controls(snapshot, csrf_secret) do
    messages =
      Enum.map(snapshot.messages, fn message ->
        message
        |> put_message_edit_controls(snapshot.conversation_id, csrf_secret)
        |> put_reaction_controls(snapshot.conversation_id, csrf_secret)
      end)

    Map.put(snapshot, :messages, messages)
  end

  defp put_message_edit_controls(
         %{actor: :operator, editable: true, item_id: item_id} = message,
         conversation_id,
         csrf_secret
       )
       when is_binary(item_id) do
    edit_resource = message_resource(conversation_id, item_id, :edit)
    delete_resource = message_resource(conversation_id, item_id, :delete)

    Map.put(message, :message_controls, %{
      delete: %{
        path: "/conversations/#{conversation_id}/messages/#{item_id}/delete",
        token: CSRF.token(csrf_secret, @message_action, delete_resource)
      },
      edit: %{
        path: "/conversations/#{conversation_id}/messages/#{item_id}/edit",
        token: CSRF.token(csrf_secret, @message_action, edit_resource)
      }
    })
  end

  defp put_message_edit_controls(message, _conversation_id, _csrf_secret),
    do: Map.put(message, :message_controls, nil)

  defp put_reaction_controls(
         %{actor: :ryker, message_ref: message_ref} = message,
         conversation_id,
         csrf_secret
       )
       when is_binary(message_ref) do
    resource = reaction_resource(conversation_id, message_ref)

    Map.put(message, :reaction_controls, %{
      path:
        "/conversations/#{conversation_id}/replies/#{URI.encode(message_ref, &URI.char_unreserved?/1)}/reactions",
      token: CSRF.token(csrf_secret, @reaction_action, resource)
    })
  end

  defp put_reaction_controls(message, _conversation_id, _csrf_secret),
    do: Map.put(message, :reaction_controls, nil)

  defp empty_conversation(conversation_id) do
    %{
      blocked: false,
      conversation_id: conversation_id,
      conversation_ref: "control-plane:lab:#{conversation_id}",
      episodes: [],
      history: %{before: nil, exhausted: true, page_size: Projection.lab_page_size()},
      live: false,
      messages: [],
      pending: 0
    }
  end

  defp record_controls(snapshot, csrf_secret) do
    messages =
      Enum.map(snapshot.messages, fn message ->
        cards =
          message
          |> Map.get(:cards, [])
          |> Enum.map(&card_controls(&1, snapshot.conversation_id, csrf_secret))

        Map.put(message, :cards, cards)
      end)

    Map.put(snapshot, :messages, messages)
  end

  defp card_controls(
         %{actions: actions} = card,
         conversation_id,
         secret
       )
       when is_list(actions) and actions != [] do
    controls =
      Enum.map(actions, fn action ->
        action_context = action_context(card, action)

        record_control(
          card.ref,
          conversation_id,
          action,
          action_context,
          record_label(action),
          secret
        )
      end)

    Map.put(card, :controls, controls)
  end

  defp card_controls(%{action: nil} = card, _conversation_id, _secret),
    do: Map.put(card, :controls, [])

  defp card_controls(%{action: :answer_input} = card, conversation_id, secret) do
    controls =
      card.choices
      |> Enum.with_index()
      |> Enum.map(fn {choice, index} ->
        record_control(card.ref, conversation_id, :answer_input, index, choice, secret)
      end)

    Map.put(card, :controls, controls)
  end

  defp card_controls(%{action: action} = card, conversation_id, secret) do
    control =
      record_control(
        card.ref,
        conversation_id,
        action,
        nil,
        record_label(action),
        secret
      )

    Map.put(card, :controls, [control])
  end

  defp record_control(record_ref, conversation_id, action, action_context, label, secret) do
    path = record_path(conversation_id, record_ref, action)

    if read_action?(action) do
      %{
        choice_index: nil,
        label: label,
        method: :get,
        path: path,
        publication_ref: nil,
        token: nil
      }
    else
      resource = record_resource(conversation_id, record_ref, action, action_context)

      %{
        choice_index: choice_index(action_context),
        label: label,
        method: :post,
        path: path,
        publication_ref: publication_ref(action_context),
        token: CSRF.token(secret, @record_action, resource)
      }
    end
  end

  defp read_action?(action),
    do:
      action in [
        :view_diff,
        :view_timeline,
        :view_evidence,
        :view_handoff,
        :view_postmortem
      ]

  @doc "The record action a route segment names, or an error for a segment that names none."
  def record_action("confirm-task"), do: {:ok, :confirm_task}
  def record_action("open-incident"), do: {:ok, :open_incident}
  def record_action("confirm-memory"), do: {:ok, :confirm_memory}
  def record_action("confirm-behavior"), do: {:ok, :confirm_behavior}
  def record_action("confirm-schedule"), do: {:ok, :confirm_schedule}
  def record_action("confirm-automation"), do: {:ok, :confirm_automation}
  def record_action("confirm-post"), do: {:ok, :confirm_post}
  def record_action("review-publication"), do: {:ok, :review_publication}
  def record_action("answer"), do: {:ok, :answer_input}
  def record_action("stop-task"), do: {:ok, :stop_task}
  def record_action("close-task"), do: {:ok, :close_task}
  def record_action("publish-draft"), do: {:ok, :approve_publication}
  def record_action("check-publication"), do: {:ok, :check_publication}
  def record_action("task-publish"), do: {:ok, :approve_task_publication}
  def record_action("task-check"), do: {:ok, :check_task_publication}
  def record_action("task-retry"), do: {:ok, :retry_task_publication}
  def record_action("task-update"), do: {:ok, :update_task_publication}
  def record_action("task-discard"), do: {:ok, :discard_task_publication}
  def record_action(_action), do: {:error, :lab_record_action}

  defp record_action_name(:confirm_task), do: "confirm-task"
  defp record_action_name(:open_incident), do: "open-incident"
  defp record_action_name(:confirm_memory), do: "confirm-memory"
  defp record_action_name(:confirm_behavior), do: "confirm-behavior"
  defp record_action_name(:confirm_schedule), do: "confirm-schedule"
  defp record_action_name(:confirm_automation), do: "confirm-automation"
  defp record_action_name(:confirm_post), do: "confirm-post"
  defp record_action_name(:review_publication), do: "review-publication"
  defp record_action_name(:answer_input), do: "answer"
  defp record_action_name(:stop_task), do: "stop-task"
  defp record_action_name(:close_task), do: "close-task"
  defp record_action_name(:approve_publication), do: "publish-draft"
  defp record_action_name(:check_publication), do: "check-publication"
  defp record_action_name(:approve_task_publication), do: "task-publish"
  defp record_action_name(:check_task_publication), do: "task-check"
  defp record_action_name(:retry_task_publication), do: "task-retry"
  defp record_action_name(:update_task_publication), do: "task-update"
  defp record_action_name(:discard_task_publication), do: "task-discard"
  defp record_action_name(:view_diff), do: "diff"
  defp record_action_name(:view_timeline), do: "timeline"
  defp record_action_name(:view_evidence), do: "evidence"
  defp record_action_name(:view_handoff), do: "handoff"
  defp record_action_name(:view_postmortem), do: "postmortem"

  defp record_label(:confirm_task), do: "Start task"
  defp record_label(:open_incident), do: "Open local incident"
  defp record_label(:confirm_memory), do: "Remember this"
  defp record_label(:confirm_behavior), do: "Confirm"
  defp record_label(:confirm_schedule), do: "Schedule this"
  defp record_label(:confirm_automation), do: "Apply change"
  defp record_label(:confirm_post), do: "Post locally"
  defp record_label(:review_publication), do: "Review changes"
  defp record_label(:stop_task), do: "Stop"
  defp record_label(:close_task), do: "Close"
  defp record_label(:approve_publication), do: "Publish draft"
  defp record_label(:check_publication), do: "Check pull request"
  defp record_label(:approve_task_publication), do: "Create draft PR"
  defp record_label(:check_task_publication), do: "Check delivery"
  defp record_label(:retry_task_publication), do: "Retry publication"
  defp record_label(:update_task_publication), do: "Review latest state"
  defp record_label(:discard_task_publication), do: "Discard candidate"
  defp record_label(:view_diff), do: "View diff"
  defp record_label(:view_timeline), do: "Timeline"
  defp record_label(:view_evidence), do: "Evidence"
  defp record_label(:view_handoff), do: "Handoff"
  defp record_label(:view_postmortem), do: "Postmortem"

  defp record_resource(conversation_id, record_ref, action, action_context) do
    Enum.join(
      [
        conversation_id,
        record_ref,
        Atom.to_string(action),
        context_resource(action_context)
      ],
      ":"
    )
  end

  defp context_resource(%{generation: generation, publication_ref: publication_ref}),
    do: "#{generation}:#{publication_ref}"

  defp context_resource(%{publication_ref: publication_ref}),
    do: publication_ref

  defp context_resource(choice_index) when is_integer(choice_index),
    do: Integer.to_string(choice_index)

  defp context_resource(nil), do: "none"

  defp choice_index(%{generation: generation}), do: generation
  defp choice_index(%{}), do: nil
  defp choice_index(choice_index), do: choice_index

  defp publication_ref(%{publication_ref: publication_ref}), do: publication_ref
  defp publication_ref(_action_context), do: nil

  defp action_context(card, action)
       when action in [
              :retry_task_publication,
              :update_task_publication,
              :discard_task_publication
            ],
       do: %{
         generation: Map.get(card, :recovery_generation),
         publication_ref: Map.get(card, :publication_ref)
       }

  defp action_context(card, action)
       when action in [:approve_task_publication, :check_task_publication],
       do: %{publication_ref: Map.get(card, :publication_ref)}

  defp action_context(_card, _action), do: nil

  defp message_resource(conversation_id, item_id, action)
       when action in [:edit, :delete],
       do: "#{conversation_id}:#{item_id}:#{action}"

  defp reaction_resource(conversation_id, message_ref),
    do: "#{conversation_id}:#{message_ref}"

  @doc "Whether `token` confirms sending a message into `conversation_id`."
  def valid_send_token?(secret, conversation_id, token),
    do: CSRF.valid?(secret, @send_action, conversation_id, token)

  @doc "Whether `token` confirms editing or deleting one operator message."
  def valid_message_token?(secret, conversation_id, item_id, action, token)
      when action in [:edit, :delete],
      do:
        CSRF.valid?(
          secret,
          @message_action,
          message_resource(conversation_id, item_id, action),
          token
        )

  @doc "Whether `token` confirms a reaction on one delivered reply."
  def valid_reaction_token?(secret, conversation_id, message_ref, token),
    do:
      CSRF.valid?(
        secret,
        @reaction_action,
        reaction_resource(conversation_id, message_ref),
        token
      )

  @doc """
  Whether `token` confirms `action` on one record card, in the exact context
  the control was minted for: a chosen answer, a publication, or nothing.
  """
  def valid_record_token?(secret, conversation_id, record_ref, action, context, token),
    do:
      CSRF.valid?(
        secret,
        @record_action,
        record_resource(conversation_id, record_ref, action, context),
        token
      )

  @doc "The route a record card's `action` posts to, or a read-only view opens."
  def record_path(conversation_id, record_ref, action),
    do:
      "/conversations/#{conversation_id}/records/#{URI.encode(record_ref, &URI.char_unreserved?/1)}/#{record_action_name(action)}"
end
