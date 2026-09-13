defmodule Ryker.ControlPlane.ConversationLab do
  @moduledoc """
  Source-neutral local conversation ingress for the loopback control plane.

  A lab message is not sent directly to a model. It enters the same durable
  inbox, admission, episode, Work, state-tool, and delivery path as Slack,
  GitHub, or a signed webhook. The stable conversation destination lets later
  messages continue the same episode without adding a second chat store.
  """

  import Ecto.Query

  # Direct-conversation input enters the inbox directly; the Slack engagement
  # gate never runs for it, and the receipt says that instead of inventing
  # Slack checks.
  @engagement %{
    "version" => 1,
    "path" => "conversation_lab",
    "result" => "process",
    "reason" => "Explicitly submitted in a direct conversation.",
    "checks" => [],
    "settings" => nil,
    "execution_mode" => "live"
  }

  alias Ryker.Artifacts
  alias Ryker.Episodes.Reactions
  alias Ryker.Ingress.{Inbox, Input, WorkProfile}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo

  @maximum_message_bytes 20_000
  @maximum_attachments 2
  @option_keys [:attachments, :id_generator, :now]
  @operator_actor_ref "control-plane:user:local-operator"

  @doc "The actor every local-operator reaction is recorded under; the page uses it to mark the operator's own."
  @spec operator_actor_ref() :: String.t()
  def operator_actor_ref, do: @operator_actor_ref

  @spec send_message(String.t(), String.t(), WorkProfile.t(), keyword()) ::
          {:ok, Inbox.receipt()} | {:error, term()}
  def send_message(conversation_id, message, work_profile, options \\ [])

  def send_message(conversation_id, message, %WorkProfile{} = work_profile, options) do
    with {:ok, conversation_id} <- conversation_id(conversation_id),
         {:ok, settings} <- options(options),
         :ok <- message(message, settings.attachments),
         {:ok, event_id} <- generated_id(settings.id_generator),
         {:ok, occurred_at} <- occurred_at(settings.now) do
      persist_message(conversation_id, event_id, occurred_at, message, work_profile, settings)
    end
  end

  def send_message(_conversation_id, _message, _work_profile, _options),
    do: {:error, {:invalid_conversation_lab, :work_profile}}

  @doc """
  Records an edit of one exact local operator message as a new source revision.

  The browser never updates transcript state directly. The revision enters the
  same Inbox and admission path as a Slack `message_changed` event.
  """
  @spec edit_message(String.t(), String.t(), String.t(), WorkProfile.t(), keyword()) ::
          {:ok, Inbox.receipt()} | {:error, term()}
  def edit_message(conversation_id, item_id, message, work_profile, options \\ [])

  def edit_message(
        conversation_id,
        item_id,
        message,
        %WorkProfile{} = work_profile,
        options
      ) do
    with :ok <- message(message, []),
         {:ok, settings} <- options(options) do
      revise_message(conversation_id, item_id, :edit, message, work_profile, settings)
    end
  end

  def edit_message(_conversation_id, _item_id, _message, _work_profile, _options),
    do: {:error, {:invalid_conversation_lab, :work_profile}}

  @doc """
  Records deletion of one exact local operator message as a new source revision.
  """
  @spec delete_message(String.t(), String.t(), WorkProfile.t(), keyword()) ::
          {:ok, Inbox.receipt()} | {:error, term()}
  def delete_message(conversation_id, item_id, work_profile, options \\ [])

  def delete_message(conversation_id, item_id, %WorkProfile{} = work_profile, options) do
    with {:ok, settings} <- options(options) do
      revise_message(conversation_id, item_id, :delete, nil, work_profile, settings)
    end
  end

  def delete_message(_conversation_id, _item_id, _work_profile, _options),
    do: {:error, {:invalid_conversation_lab, :work_profile}}

  @doc """
  Records passive local-operator feedback on one exact delivered Lab reply.

  Like a Slack reaction event, this updates durable conversation context but
  does not create a model turn or grant authority.
  """
  @spec react_to_message(String.t(), String.t(), :add | :remove, String.t(), keyword()) ::
          {:ok, Ryker.Episodes.Transition.t()} | {:error, term()}
  def react_to_message(conversation_id, message_ref, action, emoji_name, options \\ []) do
    with {:ok, conversation_id} <- conversation_id(conversation_id),
         {:ok, settings} <- options(options),
         true <- settings.attachments == [],
         :ok <- reaction_action(action),
         :ok <- reaction_emoji(emoji_name),
         :ok <- reference(message_ref, :message_ref),
         {:ok, event_id} <- generated_id(settings.id_generator),
         {:ok, occurred_at} <- occurred_at(settings.now) do
      conversation_ref = "control-plane:lab:#{conversation_id}"

      Reactions.record(%{
        action: action,
        actor_ref: @operator_actor_ref,
        emoji_name: emoji_name,
        event_ref: "control-plane-reaction:#{event_id}",
        occurred_at: occurred_at,
        source: %{kind: "control_plane", ref: "local"},
        target: %{
          conversation_ref: conversation_ref,
          message_ref: message_ref,
          transport: "control_plane"
        }
      })
    else
      false -> {:error, {:invalid_conversation_lab, :options}}
      {:error, _reason} = error -> error
    end
  end

  defp persist_message(conversation_id, event_id, occurred_at, message, work_profile, settings) do
    Repo.transaction(fn ->
      record_message(conversation_id, event_id, occurred_at, message, work_profile, settings)
    end)
  end

  defp record_message(conversation_id, event_id, occurred_at, message, work_profile, settings) do
    with {:ok, files} <- store_attachments(conversation_id, event_id, settings.attachments),
         {:ok, input} <- lab_input(conversation_id, event_id, occurred_at, message, files),
         {:ok, receipt} <-
           Inbox.record(input, work_profile: work_profile, engagement_receipt: @engagement) do
      receipt
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp revise_message(conversation_id, item_id, kind, message, work_profile, settings) do
    with {:ok, conversation_id} <- conversation_id(conversation_id),
         {:ok, item_id} <- conversation_id(item_id),
         true <- settings.attachments == [],
         {:ok, event_id} <- generated_id(settings.id_generator),
         {:ok, occurred_at} <- occurred_at(settings.now) do
      Repo.transaction(fn ->
        revise_message_in_transaction(
          conversation_id,
          item_id,
          event_id,
          occurred_at,
          kind,
          message,
          work_profile
        )
      end)
    else
      false -> {:error, {:invalid_conversation_lab, :attachments}}
      {:error, _reason} = error -> error
    end
  end

  defp revise_message_in_transaction(
         conversation_id,
         item_id,
         event_id,
         occurred_at,
         kind,
         message,
         work_profile
       ) do
    source_item_ref = "control-plane-item:#{item_id}"

    with :ok <- lock_source_item(source_item_ref),
         {:ok, current} <- current_message(conversation_id, source_item_ref),
         :ok <- editable_message(current),
         {:ok, input} <- lifecycle_input(current, event_id, occurred_at, kind, message),
         {:ok, receipt} <-
           Inbox.record(input,
             revision_ties: :receipt_order,
             work_profile: work_profile,
             engagement_receipt: @engagement
           ) do
      receipt
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp current_message(conversation_id, source_item_ref) do
    case Repo.one(current_message_query(conversation_id, source_item_ref)) do
      %Entry{} = entry -> {:ok, entry}
      nil -> {:error, {:invalid_conversation_lab, :message_not_found}}
    end
  end

  defp current_message_query(conversation_id, source_item_ref) do
    conversation_ref = "control-plane:lab:#{conversation_id}"

    from(entry in Entry,
      where:
        entry.source_kind == "control_plane" and entry.source_ref == "local" and
          entry.actor_kind == :user and entry.actor_ref == "local-operator" and
          entry.destination_transport == "control_plane" and
          entry.destination_conversation_ref == ^conversation_ref and
          entry.destination_thread_ref == ^conversation_ref and
          entry.source_item_ref == ^source_item_ref,
      order_by: [desc: entry.revision, desc: entry.inserted_at, desc: entry.id],
      limit: 1,
      lock: "FOR UPDATE"
    )
  end

  defp editable_message(%Entry{event_kind: :delete}),
    do: {:error, {:invalid_conversation_lab, :message_deleted}}

  defp editable_message(%Entry{}), do: :ok

  defp lifecycle_input(current, event_id, occurred_at, kind, message) do
    Input.new(%{
      actor: %{kind: :user, ref: "local-operator"},
      content: lifecycle_content(current.content, kind, message),
      destination: %{
        transport: current.destination_transport,
        conversation_ref: current.destination_conversation_ref,
        thread_ref: current.destination_thread_ref
      },
      event_kind: kind,
      event_ref: "control-plane-event:#{event_id}",
      native_input_id: current.native_input_id,
      occurred_at: occurred_at,
      occurred_at_source: :ingress,
      revision: 1,
      source: %{kind: "control_plane", ref: "local"},
      source_capabilities: lifecycle_capabilities(kind, current.destination_conversation_ref),
      source_item_ref: current.source_item_ref
    })
  end

  defp lifecycle_content(content, :edit, message) do
    content
    |> Map.take(["files"])
    |> Map.put("text", message)
  end

  defp lifecycle_content(content, :delete, _message) do
    %{"text" => Map.get(content, "text", "")}
  end

  defp lifecycle_capabilities(:delete, _conversation_ref), do: %{}

  defp lifecycle_capabilities(:edit, conversation_ref) do
    source_capabilities(conversation_ref)
  end

  defp lock_source_item(source_item_ref) do
    case Repo.query(
           "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
           ["conversation-lab-message:" <> source_item_ref]
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:conversation_lab_persistence_failed, :source_lock, reason}}
    end
  end

  defp lab_input(conversation_id, event_id, occurred_at, message, files) do
    conversation_ref = "control-plane:lab:#{conversation_id}"

    Input.new(%{
      actor: %{kind: :user, ref: "local-operator"},
      content: content(message, files),
      destination: destination(conversation_id),
      event_kind: :message,
      event_ref: "control-plane-event:#{event_id}",
      native_input_id: "control-plane-message:#{event_id}",
      occurred_at: occurred_at,
      occurred_at_source: :ingress,
      revision: 1,
      source: %{kind: "control_plane", ref: "local"},
      source_capabilities: source_capabilities(conversation_ref),
      source_item_ref: "control-plane-item:#{event_id}"
    })
  end

  defp source_capabilities(conversation_ref) do
    %{
      "post_slack_message" => %{"destination_refs" => [conversation_ref]},
      "react" => %{"emoji_names" => nil}
    }
  end

  @spec conversation_ref(String.t()) :: {:ok, String.t()} | {:error, term()}
  def conversation_ref(conversation_id) do
    with {:ok, conversation_id} <- conversation_id(conversation_id) do
      {:ok, "control-plane:lab:#{conversation_id}"}
    end
  end

  defp destination(conversation_id) do
    conversation_ref = "control-plane:lab:#{conversation_id}"

    %{
      transport: "control_plane",
      conversation_ref: conversation_ref,
      thread_ref: conversation_ref
    }
  end

  defp conversation_id(value) do
    case Ecto.UUID.cast(value) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, {:invalid_conversation_lab, :conversation_id}}
    end
  end

  defp message(value, attachments) do
    if is_binary(value) and String.valid?(value) and
         (String.trim(value) != "" or attachments != []) and
         :binary.match(value, <<0>>) == :nomatch and byte_size(value) <= @maximum_message_bytes,
       do: :ok,
       else: {:error, {:invalid_conversation_lab, :message}}
  end

  defp options(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
         Keyword.keys(options) -- @option_keys == [] do
      settings = %{
        attachments: Keyword.get(options, :attachments, []),
        id_generator: Keyword.get(options, :id_generator, &Ecto.UUID.generate/0),
        now: Keyword.get(options, :now, &DateTime.utc_now/0)
      }

      cond do
        not is_function(settings.id_generator, 0) or not is_function(settings.now, 0) ->
          {:error, {:invalid_conversation_lab, :options}}

        not attachments?(settings.attachments) ->
          {:error, {:invalid_conversation_lab, :attachments}}

        true ->
          {:ok, settings}
      end
    else
      {:error, {:invalid_conversation_lab, :options}}
    end
  end

  defp options(_options), do: {:error, {:invalid_conversation_lab, :options}}

  defp generated_id(id_generator) do
    case Ecto.UUID.cast(id_generator.()) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, {:invalid_conversation_lab, :event_id}}
    end
  end

  defp occurred_at(now) do
    case now.() do
      %DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0} = value -> {:ok, value}
      _other -> {:error, {:invalid_conversation_lab, :now}}
    end
  end

  defp reaction_action(action) when action in [:add, :remove], do: :ok

  defp reaction_action(_action),
    do: {:error, {:invalid_conversation_lab, :reaction_action}}

  defp reaction_emoji(value) do
    if is_binary(value) and byte_size(value) <= 100 and
         Regex.match?(~r/\A[a-z0-9_+\-]+\z/, value),
       do: :ok,
       else: {:error, {:invalid_conversation_lab, :reaction_emoji}}
  end

  defp reference(value, field) do
    if is_binary(value) and String.valid?(value) and String.trim(value) != "" and
         :binary.match(value, <<0>>) == :nomatch and byte_size(value) <= 1_024,
       do: :ok,
       else: {:error, {:invalid_conversation_lab, field}}
  end

  defp attachments?(attachments)
       when is_list(attachments) and
              length(attachments) <= @maximum_attachments do
    Enum.all?(attachments, fn
      %{data: data, media_type: media_type, name: name} = attachment
      when map_size(attachment) == 3 ->
        is_binary(data) and is_binary(media_type) and is_binary(name)

      _invalid ->
        false
    end) and Enum.sum(Enum.map(attachments, &byte_size(&1.data))) <= Artifacts.maximum_bytes()
  end

  defp attachments?(_attachments), do: false

  defp store_attachments(conversation_id, event_id, attachments) do
    attachments
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {attachment, index}, {:ok, files} ->
      source_ref = "#{conversation_id}:#{event_id}:#{index}"

      case Artifacts.put(
             Map.put(attachment, :source_kind, "control_plane")
             |> Map.put(:source_ref, source_ref)
           ) do
        {:ok, artifact} -> {:cont, {:ok, [artifact_descriptor(artifact) | files]}}
        {:error, _reason} -> {:halt, {:error, {:invalid_conversation_lab, :attachments}}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      {:error, _reason} = error -> error
    end
  end

  defp artifact_descriptor(artifact) do
    %{
      "artifact_ref" => artifact.ref,
      "bytes" => artifact.byte_size,
      "media_type" => artifact.media_type,
      "name" => artifact.name,
      "sha256" => artifact.sha256,
      "status" => "available"
    }
  end

  defp content(message, []), do: %{"text" => message}
  defp content(message, files), do: %{"files" => files, "text" => message}
end
