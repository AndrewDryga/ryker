defmodule Ryker.StateTools.WorkStateTools do
  @moduledoc false
  alias Ryker.Delivery
  alias Ryker.Knowledge
  alias Ryker.Publication
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.StateTools.Binding

  # The newest records within the limit: the oldest kept the latest evidence
  # and waits of a long episode out of reach (2026-10-04 review).
  @spec get_work_state(map(), map()) :: {:ok, map()} | {:error, term()}
  def get_work_state(%{"limit" => limit}, binding) do
    Repo.transaction(fn ->
      with {:ok, current} <- Binding.fetch_and_lock_current(binding),
           {:ok, state} <- current_work_state(limit, current) do
        state
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  rescue
    error in Postgrex.Error ->
      if Repo.budget_exhausted?(error),
        do: {:error, :work_derived_context_busy},
        else: reraise(error, __STACKTRACE__)
  end

  defp current_work_state(limit, binding) do
    records =
      Records.model_records(binding.episode, binding.session)
      |> Enum.take(-limit)

    platform_actions = Delivery.PlatformActionCustody.model_actions(binding.episode.id)

    with :ok <-
           Knowledge.KnowledgeSnapshot.expose(
             binding,
             Enum.map(records, &Records.DerivedContext.record/1)
           ) do
      {:ok,
       %{
         "cursor" => "episode:#{binding.episode.id}:v#{binding.episode.semantic_version}",
         "episode" => %{
           "episode_ref" => binding.episode.key,
           "owner" => Atom.to_string(binding.episode.owner_kind),
           "state" => Atom.to_string(binding.episode.state)
         },
         "platform_actions" => platform_actions,
         "publication" =>
           Publication.ModelState.snapshot(binding.episode.id, binding.session.repository_ref),
         "related_publications" =>
           Publication.ModelState.related(binding.episode, binding.session),
         "records" => records
       }}
    end
  end
end
