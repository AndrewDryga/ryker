defmodule Ryker.Slack.API do
  @moduledoc false

  # Grouped as `Ryker.Slack.Client` splits the work behind them. Five are
  # required: find_message, post_message, find_files, upload_files and
  # add_reaction. Every other callback is optional, and its caller checks that
  # it is there.

  # --- messages -------------------------------------------------------------

  @callback find_message(term(), String.t(), String.t() | nil, String.t()) ::
              {:ok, String.t()} | :not_found | {:error, term()}
  @doc """
  Like `find_message/4`, looking only at messages posted after `oldest`, a
  Slack timestamp, or at every message when it is nil. Optional: without it
  the publisher walks the whole channel or thread.
  """
  @callback find_message(term(), String.t(), String.t() | nil, String.t(), String.t() | nil) ::
              {:ok, String.t()} | :not_found | {:error, term()}
  @callback post_message(term(), String.t(), String.t() | nil, String.t() | map(), String.t()) ::
              {:ok, String.t()} | {:error, term()}
  @doc """
  Posts one private line to exactly one person in a channel they are already in.

  Used when the host must tell a reader something their card cannot say, and
  never for content anyone else needs to see. Optional: a caller that has
  nothing else to say checks for it and stays silent when it is absent.
  """
  @callback post_ephemeral(term(), String.t(), String.t(), String.t() | nil, String.t()) ::
              :ok | {:error, term()}
  @callback update_message(term(), String.t(), String.t(), String.t() | map(), String.t()) ::
              :ok | {:error, term()}
  @callback read_messages(term(), String.t(), String.t() | nil, map()) ::
              {:ok, map()} | {:error, term()}

  # --- files ----------------------------------------------------------------

  @callback find_files(term(), String.t(), String.t() | nil, [String.t()]) ::
              {:ok, String.t()} | :not_found | {:error, term()}
  @callback upload_files(term(), String.t(), String.t() | nil, map(), String.t(), [map()]) ::
              {:ok, String.t()} | {:error, term()}
  @callback file_info(term(), String.t()) :: {:ok, map()} | {:error, term()}

  # --- reactions ------------------------------------------------------------

  @callback add_reaction(term(), String.t(), String.t(), String.t()) ::
              :ok | {:error, term()}
  @callback remove_reaction(term(), String.t(), String.t(), String.t()) ::
              :ok | {:error, term()}

  # --- assistant ------------------------------------------------------------

  @callback set_thread_status(term(), String.t(), String.t(), String.t()) ::
              :ok | {:error, term()}
  @callback search_context(term(), String.t(), map()) :: {:ok, map()} | {:error, term()}

  # --- conversations Ryker reads --------------------------------------------

  @callback list_conversations(term(), map()) :: {:ok, map()} | {:error, term()}
  @callback conversation_info(term(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback conversation_state(term(), String.t()) ::
              {:ok, :active | :archived} | :not_found | {:error, term()}
  @callback list_bookmarks(term(), String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback joined_conversations(term()) ::
              {:ok,
               [
                 %{
                   :channel_ref => String.t(),
                   :private => boolean(),
                   optional(:name) => String.t()
                 }
               ]}
              | {:error, term()}
  @callback shared_conversations(term(), String.t(), String.t()) ::
              {:ok, MapSet.t(String.t())} | {:error, term()}

  # --- rooms Ryker creates and sets up --------------------------------------

  @callback ensure_conversation(
              term(),
              String.t(),
              String.t(),
              boolean(),
              String.t(),
              DateTime.t()
            ) :: {:ok, String.t()} | {:error, term()}
  @callback invite_users(term(), String.t(), [String.t()]) :: :ok | {:error, term()}
  @callback set_topic(term(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback pin_message(term(), String.t(), String.t()) :: :ok | {:error, term()}

  # --- views ----------------------------------------------------------------

  @callback publish_home(term(), String.t(), map()) :: :ok | {:error, term()}
  @callback open_view(term(), String.t(), map()) :: :ok | {:error, term()}

  @optional_callbacks find_message: 5,
                      post_ephemeral: 5,
                      update_message: 5,
                      read_messages: 4,
                      file_info: 2,
                      remove_reaction: 4,
                      set_thread_status: 4,
                      search_context: 3,
                      list_conversations: 2,
                      conversation_info: 2,
                      conversation_state: 2,
                      list_bookmarks: 2,
                      joined_conversations: 1,
                      shared_conversations: 3,
                      ensure_conversation: 6,
                      invite_users: 3,
                      set_topic: 3,
                      pin_message: 3,
                      publish_home: 3,
                      open_view: 3
end
