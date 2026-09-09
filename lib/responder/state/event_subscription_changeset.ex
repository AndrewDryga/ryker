defmodule Responder.State.EventSubscriptionChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Responder.State.EventSubscription

  @fields [
    :cursor,
    :deadline_at,
    :episode_id,
    :id,
    :last_observation,
    :last_observed_at,
    :matcher,
    :poll_after,
    :record_id,
    :ref,
    :resolution_kind,
    :revision,
    :source_kind,
    :status
  ]

  def insert(attributes) do
    %EventSubscription{}
    |> cast(attributes, @fields)
    |> validate_required([
      :episode_id,
      :id,
      :matcher,
      :record_id,
      :ref,
      :revision,
      :status
    ])
    |> validate_inclusion(:status, [:active])
    |> validate_number(:revision, greater_than: 0)
    |> unique_constraint(:ref)
    |> unique_constraint(:record_id)
    |> unique_constraint(:episode_id,
      name: :episode_event_subscriptions_one_active_episode_index
    )
    |> foreign_key_constraint(:episode_id)
    |> foreign_key_constraint(:record_id)
    |> check_constraint(:status, name: :episode_event_subscription_valid)
    |> check_constraint(:poll_after, name: :event_subscription_schedule_valid)
  end
end
