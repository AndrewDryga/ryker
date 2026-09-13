defmodule Ryker.ControlPlane.ChannelScope do
  @moduledoc """
  The one tested identity of a Slack channel across every table that mentions it.

  Slack custody tables (`slack_channel_*`, incident rooms, task cards) key on
  the raw team/channel pair. Every cross-transport context table (continuity,
  knowledge, behaviors, memory, learning, accounting) keys on the canonical
  `slack:T…` workspace ref and `slack:T…:C…` conversation ref. Production once
  compared the raw ref against the canonical column and reported four durable
  summaries as "No durable records"; every query on the Channel detail now
  takes its refs from this value instead of rebuilding them by hand.
  """

  @enforce_keys [:workspace_ref, :channel_ref, :canonical_workspace_ref, :conversation_ref]
  defstruct [
    :workspace_ref,
    :channel_ref,
    :canonical_workspace_ref,
    :conversation_ref,
    repository_ref: nil
  ]

  @type t :: %__MODULE__{
          workspace_ref: String.t(),
          channel_ref: String.t(),
          canonical_workspace_ref: String.t(),
          conversation_ref: String.t(),
          repository_ref: String.t() | nil
        }

  @maximum_ref_bytes 256

  @doc """
  Builds the scope from the raw Slack refs in the URL.

  A ref containing `:` cannot be told apart from a canonical ref once joined,
  so it is refused rather than guessed at.
  """
  @spec new(term(), term()) :: {:ok, t()} | :error
  def new(workspace_ref, channel_ref) do
    if raw_ref?(workspace_ref) and raw_ref?(channel_ref) do
      {:ok,
       %__MODULE__{
         workspace_ref: workspace_ref,
         channel_ref: channel_ref,
         canonical_workspace_ref: "slack:" <> workspace_ref,
         conversation_ref: "slack:" <> workspace_ref <> ":" <> channel_ref
       }}
    else
      :error
    end
  end

  @doc "The repository context that inherited rules, guidance and memory resolve through."
  @spec with_repository(t(), String.t() | nil) :: t()
  def with_repository(%__MODULE__{} = scope, repository_ref)
      when is_binary(repository_ref) and byte_size(repository_ref) in 1..1_024,
      do: %{scope | repository_ref: repository_ref}

  def with_repository(%__MODULE__{} = scope, _missing), do: %{scope | repository_ref: nil}

  @doc "Whether the raw channel ref names a Slack direct message."
  @spec direct_message?(t()) :: boolean()
  def direct_message?(%__MODULE__{channel_ref: "D" <> _rest}), do: true
  def direct_message?(%__MODULE__{}), do: false

  defp raw_ref?(value) do
    is_binary(value) and String.valid?(value) and byte_size(value) in 1..@maximum_ref_bytes and
      String.trim(value) == value and value != "" and
      not String.contains?(value, [":", "/", "\n", "\t", <<0>>])
  end
end
