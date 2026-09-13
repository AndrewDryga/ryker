defmodule Ryker.Slack.API do
  @moduledoc false

  @callback find_message(term(), String.t(), String.t() | nil, String.t()) ::
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
  @callback find_files(term(), String.t(), String.t() | nil, [String.t()]) ::
              {:ok, String.t()} | :not_found | {:error, term()}
  @callback upload_files(term(), String.t(), String.t() | nil, map(), String.t(), [map()]) ::
              {:ok, String.t()} | {:error, term()}
  @callback add_reaction(term(), String.t(), String.t(), String.t()) ::
              :ok | {:error, term()}
  @callback remove_reaction(term(), String.t(), String.t(), String.t()) ::
              :ok | {:error, term()}
  @callback search_context(term(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback list_conversations(term(), map()) :: {:ok, map()} | {:error, term()}
  @callback conversation_info(term(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback list_bookmarks(term(), String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback file_info(term(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback read_messages(term(), String.t(), String.t() | nil, map()) ::
              {:ok, map()} | {:error, term()}
  @callback joined_conversations(term()) ::
              {:ok, [%{channel_ref: String.t(), private: boolean()}]} | {:error, term()}
  @callback shared_conversations(term(), String.t(), String.t()) ::
              {:ok, MapSet.t(String.t())} | {:error, term()}
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
  @callback conversation_state(term(), String.t()) ::
              {:ok, :active | :archived} | :not_found | {:error, term()}
  @callback publish_home(term(), String.t(), map()) :: :ok | {:error, term()}
  @callback open_view(term(), String.t(), map()) :: :ok | {:error, term()}
  @callback set_thread_status(term(), String.t(), String.t(), String.t()) ::
              :ok | {:error, term()}

  @optional_callbacks list_conversations: 2,
                      search_context: 3,
                      remove_reaction: 4,
                      conversation_info: 2,
                      list_bookmarks: 2,
                      file_info: 2,
                      read_messages: 4,
                      joined_conversations: 1,
                      shared_conversations: 3,
                      ensure_conversation: 6,
                      invite_users: 3,
                      set_topic: 3,
                      pin_message: 3,
                      conversation_state: 2,
                      open_view: 3,
                      post_ephemeral: 5,
                      publish_home: 3,
                      set_thread_status: 4,
                      update_message: 5
end
