defmodule Ryker.TestSupport.FakeSlackAPI do
  @moduledoc """
  One Slack workspace for tests, behind the part of `Ryker.Slack.API` the Slack
  publisher needs, plus the channels Ryker has joined.

  It keeps every message and file share it accepts under the channel, thread
  and delivery ref (or filenames) it was sent with, so a retry finds what an
  earlier attempt posted, the way the real client walks history. `state/1`
  holds every accepted write in order (reactions in `reacted`, as well as the
  set of emoji each message carries in `reactions`), and when an `:observer`
  is given each message write is also sent to it:

    * `{:slack_posted, channel, thread, document, delivery_ref, message_ref}`
    * `{:slack_updated, channel, message_ref, document, delivery_ref}`
    * `{:slack_uploaded, channel, thread, document, delivery_ref, files}`

  Of the optional callbacks it exports only `update_message/5`,
  `joined_conversations/1`, `leave_conversation/2`, which keeps each channel
  Ryker left in `left`, and `find_message/5`, which finds what
  `find_message/4` finds and keeps each search's `oldest` in `searched_since`. Code that
  checks for another one, such as removing a reaction or posting a private
  line, finds it absent, as it did with every fake this one replaced.

  Options:

    * `:observer` - the process told about each accepted write.
    * `:message_ref` - `fn n -> ref end` naming the n-th message the workspace
      holds, posts and file shares counted together from 1. Defaults to
      `"n.000001"`.
    * `:render` - when true, a document is rendered with `Ryker.Slack.Renderer`
      first, as the real client does before it sends; one that does not render
      is refused with the renderer's error, and the rendered document is what
      is kept and reported.
    * `:lose` - the calls, `:post_message` or `:upload_files`, whose first
      answer is lost after Slack took the write: the write is kept, and the
      caller sees `{:error, :socket_closed}` once.
    * `:share_delay` - how many `find_files/5` searches miss an upload's share
      before it shows. Above zero, the upload answers
      `{:error, {:slack_file_share_pending, file_refs}}`, as the real client
      does when its own search right after the upload misses; the n-th upload's
      files are `"Fn01"`, `"Fn02"` and so on.
    * `:refuse` - `%{delivery_ref => reason}`: a post with that delivery ref is
      refused with `{:error, reason}` and nothing is kept. `refuse/2` replaces
      it mid-test.
    * `:channels` - what `joined_conversations/1` returns; `put_channels/2`
      replaces it mid-test.
  """
  @behaviour Ryker.Slack.API
  alias Ryker.Slack.Renderer

  @options [
    channels: [],
    lose: [],
    message_ref: &__MODULE__.default_message_ref/1,
    observer: nil,
    refuse: %{},
    render: false,
    share_delay: 0
  ]

  def child_spec(options), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}}

  def start_link(options \\ []) do
    options = Keyword.validate!(options, @options)

    Agent.start_link(fn ->
      options
      |> Map.new()
      |> Map.merge(%{
        file_finds: 0,
        files: %{},
        hidden_shares: %{},
        finds: 0,
        left: [],
        messages: %{},
        posts: [],
        ephemerals: [],
        reacted: [],
        searched_since: [],
        reactions: MapSet.new(),
        updates: [],
        uploads: []
      })
    end)
  end

  def state(agent), do: Agent.get(agent, & &1)
  def refuse(agent, refusals), do: Agent.update(agent, &%{&1 | refuse: refusals})
  def put_channels(agent, channels), do: Agent.update(agent, &%{&1 | channels: channels})

  @doc false
  def default_message_ref(n), do: "#{n}.000001"

  @impl true
  def post_ephemeral(agent, channel, user, thread, text) do
    Agent.update(agent, fn state ->
      shown = %{channel: channel, text: text, thread: thread, user: user}
      Map.update!(state, :ephemerals, &(&1 ++ [shown]))
    end)
  end

  @impl true
  def find_message(agent, channel, thread, delivery_ref) do
    Agent.get_and_update(agent, fn state ->
      result = found(Map.fetch(state.messages, {channel, thread, delivery_ref}))
      {result, %{state | finds: state.finds + 1}}
    end)
  end

  @impl true
  def find_message(agent, channel, thread, delivery_ref, oldest) do
    Agent.update(agent, &%{&1 | searched_since: &1.searched_since ++ [oldest]})
    find_message(agent, channel, thread, delivery_ref)
  end

  @impl true
  def post_message(agent, channel, thread, document, delivery_ref) do
    Agent.get_and_update(agent, fn state ->
      with :ok <- refusal(state, delivery_ref),
           {:ok, document} <- document(state, document) do
        message_ref = next_message_ref(state)
        notify(state, {:slack_posted, channel, thread, document, delivery_ref, message_ref})

        post = %{
          channel: channel,
          delivery_ref: delivery_ref,
          document: document,
          message_ref: message_ref,
          thread: thread
        }

        state
        |> Map.update!(:messages, &Map.put(&1, {channel, thread, delivery_ref}, message_ref))
        |> Map.update!(:posts, &(&1 ++ [post]))
        |> answer(:post_message, {:ok, message_ref})
      else
        {:error, reason} -> {{:error, reason}, state}
      end
    end)
  end

  @impl true
  def update_message(agent, channel, message_ref, document, delivery_ref) do
    Agent.get_and_update(agent, fn state ->
      case document(state, document) do
        {:ok, document} ->
          notify(state, {:slack_updated, channel, message_ref, document, delivery_ref})

          update = %{
            channel: channel,
            delivery_ref: delivery_ref,
            document: document,
            message_ref: message_ref
          }

          {:ok, Map.update!(state, :updates, &(&1 ++ [update]))}

        {:error, reason} ->
          {{:error, reason}, state}
      end
    end)
  end

  @impl true
  def find_files(agent, channel, thread, filenames, oldest) do
    Agent.get_and_update(agent, fn state ->
      key = {channel, thread, filenames}

      state = %{
        state
        | file_finds: state.file_finds + 1,
          searched_since: state.searched_since ++ [oldest]
      }

      case Map.get(state.hidden_shares, key, 0) do
        0 -> {found(Map.fetch(state.files, key)), state}
        hidden -> {:not_found, put_in(state.hidden_shares[key], hidden - 1)}
      end
    end)
  end

  @impl true
  def upload_files(agent, channel, thread, document, delivery_ref, files) do
    Agent.get_and_update(agent, fn state ->
      case document(state, document) do
        {:ok, document} ->
          message_ref = next_message_ref(state)
          filenames = Enum.map(files, & &1.filename)
          notify(state, {:slack_uploaded, channel, thread, document, delivery_ref, files})

          upload = %{
            channel: channel,
            delivery_ref: delivery_ref,
            document: document,
            files: files,
            message_ref: message_ref,
            thread: thread
          }

          state =
            state
            |> Map.update!(:files, &Map.put(&1, {channel, thread, filenames}, message_ref))
            |> Map.update!(:uploads, &(&1 ++ [upload]))
            |> hide_share({channel, thread, filenames})

          answer(state, :upload_files, upload_answer(state, message_ref, files))

        {:error, reason} ->
          {{:error, reason}, state}
      end
    end)
  end

  @impl true
  def add_reaction(agent, channel, message_ref, emoji_name) do
    Agent.update(agent, fn state ->
      %{
        state
        | reacted: state.reacted ++ [{channel, message_ref, emoji_name}],
          reactions: MapSet.put(state.reactions, {channel, message_ref, emoji_name})
      }
    end)
  end

  @impl true
  def joined_conversations(agent), do: Agent.get(agent, &{:ok, &1.channels})

  @impl true
  def leave_conversation(agent, channel) do
    Agent.update(agent, fn state -> %{state | left: state.left ++ [channel]} end)
  end

  # Slack shows a share a moment after the upload completes: until then the
  # upload answers with its files' ids, and searches miss the share.
  defp hide_share(%{share_delay: 0} = state, _key), do: state
  defp hide_share(state, key), do: put_in(state.hidden_shares[key], state.share_delay)

  defp upload_answer(%{share_delay: 0}, message_ref, _files), do: {:ok, message_ref}

  defp upload_answer(state, _message_ref, files) do
    upload = length(state.uploads)

    file_refs =
      for index <- 1..length(files),
          do: "F#{upload}#{index |> Integer.to_string() |> String.pad_leading(2, "0")}"

    {:error, {:slack_file_share_pending, file_refs}}
  end

  defp found({:ok, message_ref}), do: {:ok, message_ref}
  defp found(:error), do: :not_found

  defp refusal(state, delivery_ref) do
    case Map.fetch(state.refuse, delivery_ref) do
      {:ok, reason} -> {:error, reason}
      :error -> :ok
    end
  end

  defp document(%{render: true}, %{} = document), do: Renderer.render(document)
  defp document(_state, document), do: {:ok, document}

  defp next_message_ref(state),
    do: state.message_ref.(map_size(state.messages) + map_size(state.files) + 1)

  defp notify(%{observer: nil}, _message), do: :ok
  defp notify(%{observer: observer}, message), do: send(observer, message)

  # Slack took the write; whether the caller hears so is the only question.
  defp answer(state, call, result) do
    if call in state.lose,
      do: {{:error, :socket_closed}, %{state | lose: List.delete(state.lose, call)}},
      else: {result, state}
  end
end
