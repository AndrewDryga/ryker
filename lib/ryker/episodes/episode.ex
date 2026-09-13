defmodule Ryker.Episodes.Episode do
  @moduledoc """
  Current durable projection of one episode.

  The event ledger remains the audit trail. This row exists so ownership can be
  checked and advanced under one database lock.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "episode_kernel_episodes" do
    field(:key, :string)
    field(:execution_mode, Ecto.Enum, values: [:live, :shadow], default: :live)
    field(:history_pruned_at, :utc_datetime_usec)

    field(:state, Ecto.Enum,
      values: [:working, :waiting_for_input, :waiting_for_event, :complete, :cancelled]
    )

    field(:owner_kind, Ecto.Enum, values: [:turn, :delivery, :input, :event])
    field(:owner_ref, :string)
    field(:owner_deadline_at, :utc_datetime_usec)
    field(:destination_transport, :string)
    field(:destination_conversation_ref, :string)
    field(:destination_thread_ref, :string)
    field(:linked_episode_id, :binary_id)
    # Only conclusion-relevant state advances this version. Slack transport
    # confirmation changes custody but must not invalidate an accepted result.
    field(:semantic_version, :integer, default: 0)
    field(:next_sequence, :integer, default: 1)
    field(:input_revisions, :map, default: %{})
    field(:active_input_refs, {:array, :string}, default: [])
    field(:queued_input_refs, {:array, :string}, default: [])
    field(:queued_input_order_keys, {:array, :string}, default: [])

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          key: String.t() | nil,
          execution_mode: :live | :shadow,
          state:
            :working | :waiting_for_input | :waiting_for_event | :complete | :cancelled | nil,
          owner_kind: :turn | :delivery | :input | :event | nil,
          owner_ref: String.t() | nil,
          owner_deadline_at: DateTime.t() | nil,
          destination_transport: String.t() | nil,
          destination_conversation_ref: String.t() | nil,
          destination_thread_ref: String.t() | nil,
          linked_episode_id: Ecto.UUID.t() | nil,
          semantic_version: non_neg_integer(),
          next_sequence: pos_integer(),
          input_revisions: map(),
          active_input_refs: [String.t()],
          queued_input_refs: [String.t()],
          queued_input_order_keys: [String.t()],
          history_pruned_at: DateTime.t() | nil
        }
end
