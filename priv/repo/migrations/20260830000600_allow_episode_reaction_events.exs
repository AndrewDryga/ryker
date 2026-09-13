defmodule Ryker.Repo.Migrations.AllowEpisodeReactionEvents do
  use Ecto.Migration

  def up do
    drop(constraint(:episode_kernel_events, :episode_kernel_event_kind_valid))

    create(
      constraint(:episode_kernel_events, :episode_kernel_event_kind_valid,
        check: event_kind_check(true)
      )
    )
  end

  def down do
    drop(constraint(:episode_kernel_events, :episode_kernel_event_kind_valid))

    create(
      constraint(:episode_kernel_events, :episode_kernel_event_kind_valid,
        check: event_kind_check(false)
      )
    )
  end

  defp event_kind_check(include_reaction?) do
    reaction = if include_reaction?, do: ", 'reaction_recorded'", else: ""

    """
    kind IN (
      'input_admitted', 'owner_transferred', 'input_wait_started',
      'event_wait_started', 'wait_resumed', 'result_accepted',
      'delivery_confirmed', 'episode_cancelled'#{reaction}
    )
    """
  end
end
