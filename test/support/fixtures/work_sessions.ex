defmodule Ryker.Fixtures.WorkSessions do
  @moduledoc """
  A Work session pinned for a test the way admission, a schedule or a task
  offer pins one, in a transaction of its own. Only tests ever pinned outside
  a transaction: until 2026-10-07 that was `Ryker.Work.Custody.pin_episode`,
  in six arities nothing else called (2026-10-04 review).
  """

  alias Ryker.Repo
  alias Ryker.Work.Custody

  @doc """
  Pins `episode_id` to `policy` as `Custody.pin_episode_in_transaction/4`
  does, with the same `options`, and answers what it does.
  """
  def pin_episode(episode_id, policy, policy_digest, options \\ []) do
    Repo.transaction(fn ->
      case Custody.pin_episode_in_transaction(episode_id, policy, policy_digest, options) do
        {:ok, session} -> session
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end
end
