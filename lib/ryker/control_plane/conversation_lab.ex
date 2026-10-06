defmodule Ryker.ControlPlane.ConversationLab do
  @moduledoc """
  Source-neutral local conversation ingress for the loopback control plane.

  A lab message is not sent directly to a model. It enters the same durable
  inbox, admission, episode, Work, state-tool, and delivery path as Slack,
  GitHub, or a signed webhook. The stable conversation destination lets later
  messages continue the same episode without adding a second chat store.

  Each conversation has an environment, stored with it: the one chosen for
  it, nil for "No environment", or, until it starts, the default environment.
  Its first message records the environment it started in, so a later change
  of the default does not move it; `select_environment/2` changes it for the
  messages that follow. `work_profile/2` resolves a message's Work profile
  from the console's placements: the environment's while it can run work,
  otherwise the profile of work outside any environment. A conversation's
  environment, once stored or changed, is announced on the conversation's
  topics (`Ryker.Episodes.subscribe_conversations/1`).
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
  alias Ryker.ControlPlane.Actor
  alias Ryker.Episodes
  alias Ryker.Episodes.Reactions
  alias Ryker.Ingress.{Inbox, Input, WorkProfile}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.Settings.Environment
  alias Ryker.Transcription

  @maximum_message_bytes 20_000
  @maximum_attachments 2
  @option_keys [:actor, :attachments, :id_generator, :now, :transcriber]

  @typedoc """
  What the running console holds for Chat: the Work profile of each
  environment that can run work, keyed by ref, and the profile of work outside
  any environment (nil before one is reviewed).
  """
  @type placements :: %{
          environments: %{String.t() => WorkProfile.t()},
          fallback_work_profile: WorkProfile.t() | nil
        }

  @doc """
  Chooses the environment a conversation's new messages run in; nil is "No
  environment". Work the conversation already started keeps its placement.
  """
  @spec select_environment(String.t(), String.t() | nil) ::
          {:ok, String.t() | nil} | {:error, term()}
  def select_environment(conversation_id, environment_ref) do
    with {:ok, conversation_id} <- conversation_id(conversation_id),
         :ok <- selectable_environment(environment_ref) do
      Repo.transaction(fn -> store_environment(conversation_id, environment_ref) end)
    end
  end

  @doc """
  The conversation's environment: the one chosen for it or recorded when it
  started, nil for "No environment", or the default environment (nil when
  none is the default) for a conversation that has not started yet.
  """
  @spec environment(String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def environment(conversation_id) do
    with {:ok, conversation_id} <- conversation_id(conversation_id) do
      {:ok, Map.fetch!(environments([conversation_id]), conversation_id)}
    end
  end

  @doc """
  The environment of each conversation, by id, read as `environment/1` reads
  one; the Chat list names it on every row. A conversation from before
  conversations kept their environment (2026-09-25) has no row, and works in
  the default like one that has not started. Ids that are not conversation
  ids are left out.
  """
  @spec environments([String.t()]) :: %{String.t() => String.t() | nil}
  def environments(conversation_ids) do
    ids = for id <- conversation_ids, {:ok, id} <- [conversation_id(id)], uniq: true, do: id

    stored =
      Repo.all(
        from(conversation in "control_plane_conversations",
          where: conversation.id in type(^ids, {:array, Ecto.UUID}),
          select: {type(conversation.id, Ecto.UUID), conversation.environment_ref}
        )
      )
      |> Map.new()

    default =
      if Enum.all?(ids, &Map.has_key?(stored, &1)),
        do: nil,
        else: Repo.one(default_environment_query())

    Map.new(ids, &{&1, Map.get(stored, &1, default)})
  end

  @doc """
  The Work profile a new message in the conversation runs on: its
  environment's while that environment can run work, otherwise the profile of
  work outside any environment.
  """
  @spec work_profile(String.t(), placements()) :: {:ok, WorkProfile.t()} | {:error, term()}
  def work_profile(conversation_id, %{environments: environments} = placements) do
    with {:ok, environment_ref} <- environment(conversation_id) do
      case (environment_ref && Map.get(environments, environment_ref)) ||
             Map.get(placements, :fallback_work_profile) do
        %WorkProfile{} = profile -> {:ok, profile}
        nil -> {:error, :conversation_lab_not_configured}
      end
    end
  end

  @doc """
  Records one operator message with up to two attached files. A voice
  message or video is transcribed first, outside the transaction that records
  it, so routing reads what it said; one too long or too large to transcribe
  is refused with the reason, and one Ryker could not transcribe is sent
  saying so.
  """
  @spec send_message(String.t(), String.t(), WorkProfile.t(), keyword()) ::
          {:ok, Inbox.receipt()} | {:error, term()}
  def send_message(conversation_id, message, work_profile, options \\ [])

  def send_message(conversation_id, message, %WorkProfile{} = work_profile, options) do
    with {:ok, conversation_id} <- conversation_id(conversation_id),
         {:ok, settings} <- options(options),
         :ok <- message(message, settings.attachments),
         {:ok, attachments} <- transcribed(settings.attachments, settings.transcriber),
         {:ok, event_id} <- generated_id(settings.id_generator),
         {:ok, occurred_at} <- occurred_at(settings.now) do
      settings = %{settings | attachments: attachments}
      persist_message(conversation_id, event_id, occurred_at, message, work_profile, settings)
    end
  end

  def send_message(_conversation_id, _message, _work_profile, _options),
    do: {:error, {:invalid_conversation_lab, :work_profile}}

  @doc """
  Records an edit of one exact message as a new source revision. Only its
  author edits it: the actor in `options` (`:actor`) must have sent it.

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
  Records deletion of one exact message as a new source revision, by its
  author only, as `edit_message/5` does.
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
  Records a person's passive feedback on one exact delivered Lab reply, under
  the actor in `options` (`:actor`).

  Like a Slack reaction event, this updates durable conversation context but
  does not create a model turn or grant authority.
  """
  @spec react_to_message(String.t(), String.t(), :add | :remove, String.t(), keyword()) ::
          {:ok, Ryker.Episodes.Transition.t() | %{status: :applied | :duplicate}}
          | {:error, term()}
  def react_to_message(conversation_id, message_ref, action, emoji_name, options \\ []) do
    with {:ok, conversation_id} <- conversation_id(conversation_id),
         {:ok, settings} <- options(options),
         true <- settings.attachments == [],
         :ok <- reaction_action(action),
         :ok <- reaction_emoji(emoji_name),
         :ok <- reference(message_ref, :message_ref),
         {:ok, event_id} <- generated_id(settings.id_generator),
         {:ok, occurred_at} <- occurred_at(settings.now) do
      conversation_ref = ref(conversation_id)

      Reactions.record(%{
        action: action,
        actor_ref: Actor.person_ref(settings.actor),
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
    with :ok <- start_conversation(conversation_id),
         {:ok, files} <- store_attachments(conversation_id, event_id, settings.attachments),
         {:ok, input} <-
           lab_input(conversation_id, event_id, occurred_at, message, files, settings.actor),
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
          work_profile,
          settings.actor
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
         work_profile,
         actor
       ) do
    source_item_ref = "control-plane-item:#{item_id}"

    with :ok <- start_conversation(conversation_id),
         :ok <- lock_source_item(source_item_ref),
         {:ok, current} <- current_message(conversation_id, source_item_ref, actor),
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

  # A person edits and deletes only what they sent.
  defp current_message(conversation_id, source_item_ref, actor) do
    case Repo.one(current_message_query(conversation_id, source_item_ref, actor)) do
      %Entry{} = entry -> {:ok, entry}
      nil -> {:error, {:invalid_conversation_lab, :message_not_found}}
    end
  end

  defp current_message_query(conversation_id, source_item_ref, actor) do
    conversation_ref = ref(conversation_id)

    from(entry in Entry,
      where:
        entry.source_kind == "control_plane" and entry.source_ref == "local" and
          entry.actor_kind == :user and entry.actor_ref == ^actor and
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
      actor: %{kind: :user, ref: current.actor_ref},
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

  defp lab_input(conversation_id, event_id, occurred_at, message, files, actor) do
    conversation_ref = ref(conversation_id)

    Input.new(%{
      actor: %{kind: :user, ref: actor},
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

  # A conversation starts in the default environment unless one was chosen for
  # it first, and keeps it: the row written here is never replaced but by a
  # choice.
  defp start_conversation(conversation_id) do
    case Repo.query(
           """
           INSERT INTO control_plane_conversations (id, environment_ref, inserted_at, updated_at)
           SELECT $1::text::uuid, (SELECT ref FROM environment_settings WHERE is_default LIMIT 1),
                  clock_timestamp(), clock_timestamp()
           ON CONFLICT (id) DO NOTHING
           """,
           [conversation_id]
         ) do
      {:ok, _result} ->
        Episodes.broadcast_conversation_updated("control_plane", ref(conversation_id))

      {:error, reason} ->
        {:error, {:conversation_lab_persistence_failed, :conversation, reason}}
    end
  end

  defp selectable_environment(nil), do: :ok

  defp selectable_environment(environment_ref) do
    if is_binary(environment_ref) and Regex.match?(Environment.ref_pattern(), environment_ref) and
         Repo.exists?(
           from(environment in Environment, where: environment.ref == ^environment_ref)
         ),
       do: :ok,
       else: {:error, {:invalid_conversation_lab, :environment_ref}}
  end

  # The environment's row may go between the check and the write; its foreign
  # key refuses the choice then, the same as an unknown environment.
  defp store_environment(conversation_id, environment_ref) do
    case Repo.query(
           """
           INSERT INTO control_plane_conversations (id, environment_ref, inserted_at, updated_at)
           VALUES ($1::text::uuid, $2, clock_timestamp(), clock_timestamp())
           ON CONFLICT (id) DO UPDATE
             SET environment_ref = EXCLUDED.environment_ref, updated_at = EXCLUDED.updated_at
           """,
           [conversation_id, environment_ref]
         ) do
      {:ok, _result} ->
        Episodes.broadcast_conversation_updated("control_plane", ref(conversation_id))
        environment_ref

      {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} ->
        Repo.rollback({:invalid_conversation_lab, :environment_ref})

      {:error, reason} ->
        Repo.rollback({:conversation_lab_persistence_failed, :environment, reason})
    end
  end

  defp default_environment_query do
    from(environment in Environment, where: environment.is_default, select: environment.ref)
  end

  @doc "The durable conversation reference for a validated conversation id."
  @spec conversation_ref(String.t()) :: {:ok, String.t()} | {:error, term()}
  def conversation_ref(conversation_id) do
    with {:ok, conversation_id} <- conversation_id(conversation_id) do
      {:ok, ref(conversation_id)}
    end
  end

  # The one spelling of a direct conversation's reference; readers pattern-match
  # the same prefix, so it never changes on its own.
  defp ref(conversation_id), do: "control-plane:lab:" <> conversation_id

  defp destination(conversation_id) do
    conversation_ref = ref(conversation_id)

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
        actor: Keyword.get(options, :actor, "local-operator"),
        attachments: Keyword.get(options, :attachments, []),
        id_generator: Keyword.get(options, :id_generator, &Ecto.UUID.generate/0),
        now: Keyword.get(options, :now, &DateTime.utc_now/0),
        transcriber: Keyword.get_lazy(options, :transcriber, &Transcription.transcriber/0)
      }

      cond do
        not usable?(settings) ->
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

  defp usable?(settings) do
    is_function(settings.id_generator, 0) and is_function(settings.now, 0) and
      transcriber?(settings.transcriber) and chat_actor?(settings.actor)
  end

  # The local console's one operator, or a person Tailscale or Cloudflare named
  # (`Ryker.ControlPlane.Actor.chat_ref/1`).
  defp chat_actor?("local-operator"), do: true
  defp chat_actor?(actor), do: Actor.chat_ref?(actor)

  defp transcriber?(module) do
    is_atom(module) and Code.ensure_loaded?(module) and
      function_exported?(module, :transcribe, 2)
  end

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

  defp transcribed(attachments, transcriber) do
    Enum.reduce_while(attachments, {:ok, []}, fn attachment, {:ok, done} ->
      case transcription(attachment, transcriber) do
        {:error, failure} when failure in [:too_long, :too_large] ->
          reason = Transcription.unavailable(attachment.media_type, failure)
          {:halt, {:error, {:recording_refused, attachment.name, reason}}}

        result ->
          {:cont, {:ok, [Map.put(attachment, :transcription, result) | done]}}
      end
    end)
    |> case do
      {:ok, done} -> {:ok, Enum.reverse(done)}
      {:error, _reason} = error -> error
    end
  end

  defp transcription(%{data: data, media_type: media_type}, transcriber) do
    if Artifacts.recording?(media_type), do: transcriber.transcribe(data, []), else: nil
  end

  defp store_attachments(conversation_id, event_id, attachments) do
    attachments
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {attachment, index}, {:ok, files} ->
      source_ref = "#{conversation_id}:#{event_id}:#{index}"

      case Artifacts.put(
             attachment
             |> Map.take([:data, :media_type, :name])
             |> Map.put(:source_kind, "control_plane")
             |> Map.put(:source_ref, source_ref)
           ) do
        {:ok, artifact} ->
          {:cont, {:ok, [artifact_descriptor(artifact, attachment[:transcription]) | files]}}

        {:error, _reason} ->
          {:halt, {:error, {:invalid_conversation_lab, :attachments}}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      {:error, _reason} = error -> error
    end
  end

  defp artifact_descriptor(artifact, transcription) do
    descriptor = %{
      "artifact_ref" => artifact.ref,
      "bytes" => artifact.byte_size,
      "media_type" => artifact.media_type,
      "name" => artifact.name,
      "sha256" => artifact.sha256,
      "status" => "available"
    }

    if transcription,
      do: Map.merge(descriptor, Transcription.outcome(artifact.media_type, transcription)),
      else: descriptor
  end

  defp content(message, []), do: %{"text" => message}
  defp content(message, files), do: %{"files" => files, "text" => message}
end
