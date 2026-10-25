defmodule Ryker.Work.EnvironmentContext do
  @moduledoc "The source environment retained by an input, session or episode; never inferred from its channel."
  alias Ryker.Episodes
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.Work.Session

  @doc "The exact retained environment, or nil when the source names none."
  @spec ref(map() | nil) :: String.t() | nil
  def ref(%{work_profile: %{"environment_ref" => ref}}), do: ref
  def ref(%{work_profile: _none}), do: nil
  def ref(%{environment_ref: ref}), do: ref

  def ref(%Episodes.Episode{id: id}) when is_binary(id),
    do: Repo.one(Session.Query.select_latest_environment_ref(id))

  def ref(_source), do: nil

  @doc "Retained source provenance; a missing Work producer remains unknown."
  @spec provenance(map() | nil) :: %{
          environment_ref: String.t() | nil,
          environment_known: boolean()
        }
  def provenance(%Episodes.Episode{id: id}) when is_binary(id) do
    id
    |> Session.Query.latest_of_episode()
    |> Session.Query.for_work()
    |> Repo.peek()
    |> provenance()
  end

  def provenance(nil), do: %{environment_ref: nil, environment_known: false}

  def provenance(%{environment_known: known} = source),
    do: %{environment_ref: ref(source), environment_known: known}

  def provenance(%{work_profile: _profile} = source),
    do: %{environment_ref: ref(source), environment_known: true}

  def provenance(%{environment_ref: environment_ref}),
    do: %{environment_ref: environment_ref, environment_known: true}

  def provenance(_source), do: %{environment_ref: nil, environment_known: false}

  @doc "Model-facing labels for the retained identity, keeping a removed environment's ref."
  @spec model_context(map() | nil) :: map() | nil
  def model_context(source) do
    case ref(source) do
      nil -> nil
      ref -> Settings.model_environment(ref) || %{"ref" => ref}
    end
  end
end
