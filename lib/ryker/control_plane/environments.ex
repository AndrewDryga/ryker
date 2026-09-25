defmodule Ryker.ControlPlane.Environments do
  @moduledoc """
  What each environment holds and who uses it, in words.

  An environment names the repositories work in it may use, in order (work
  changes the first and only reads the others), and at most one Emisar
  account. Slack channels and webhook sources choose one; Chat and every
  conversation without its own choice use the default. The Environments page,
  a channel's page, the Repositories list and the Emisar page read their words
  from here, so an environment reads the same everywhere. Everything except
  the channel counts is derived from the settings snapshot.
  """

  import Ecto.Query

  alias Ryker.ControlPlane.Integrations
  alias Ryker.Repo
  alias Ryker.Settings.Environment

  @doc """
  How many Slack channels choose each environment, by environment ref.

  A channel's choice lives in the Slack tables, not in the settings snapshot,
  so it is counted there, the same way the settings guard counts it before it
  refuses a removal. A channel Ryker has left still holds its choice.
  """
  @spec channel_counts() :: %{String.t() => non_neg_integer()}
  def channel_counts do
    Repo.all(
      from(configuration in "slack_channel_configurations",
        where: not is_nil(configuration.environment_ref),
        group_by: configuration.environment_ref,
        select: {configuration.environment_ref, count()}
      )
    )
    |> Map.new()
  end

  @doc "The default first, then the rest by name, the way every list shows them."
  @spec ordered([Environment.t()]) :: [Environment.t()]
  def ordered(environments),
    do: Enum.sort_by(environments, &{!&1.is_default, String.downcase(&1.display_name), &1.ref})

  @doc "The name people know a repository by: owner/repo when it came from GitHub."
  @spec repository_name(map(), String.t()) :: String.t()
  def repository_name(snapshot, ref) do
    case Enum.find(snapshot.repositories, &(&1.ref == ref)) do
      %{github_repository: name} when is_binary(name) and name != "" -> name
      %{display_name: name} when is_binary(name) and name != "" -> name
      _unknown -> ref
    end
  end

  @doc "The name of the Emisar account an environment uses, or nil when it has none."
  @spec emisar_name(map(), Environment.t()) :: String.t() | nil
  def emisar_name(_snapshot, %{emisar_connection_ref: nil}), do: nil

  def emisar_name(snapshot, %{emisar_connection_ref: ref}) do
    case Enum.find(snapshot.emisar_connections, &(&1.ref == ref)) do
      %{display_name: name} -> name
      nil -> ref
    end
  end

  @doc "The environment a ref names in the snapshot, or nil."
  @spec find(map(), String.t() | nil) :: Environment.t() | nil
  def find(_snapshot, nil), do: nil
  def find(snapshot, ref), do: Enum.find(snapshot.environments, &(&1.ref == ref))

  @doc "The environments that contain a repository, in list order."
  @spec containing(map(), String.t()) :: [Environment.t()]
  def containing(snapshot, repository_ref) do
    snapshot.environments
    |> Enum.filter(&(repository_ref in Environment.repository_refs(&1)))
    |> ordered()
  end

  @doc ~s(How many repositories, then which one takes the changes: ["2 repositories", "changes go to acme/api"].)
  @spec repository_facts(map(), Environment.t()) :: [String.t()]
  def repository_facts(snapshot, environment) do
    case Environment.repository_refs(environment) do
      [] ->
        ["No repositories"]

      [writable | _rest] = refs ->
        [
          Integrations.count(length(refs), "repository"),
          "changes go to " <> repository_name(snapshot, writable)
        ]
    end
  end

  @doc "The environment's Emisar account as one fact."
  @spec emisar_fact(map(), Environment.t()) :: String.t()
  def emisar_fact(snapshot, environment) do
    case emisar_name(snapshot, environment) do
      nil -> "No Emisar account"
      name -> "Emisar: " <> name
    end
  end

  @doc "Who chooses the environment: \"Used by 2 channels and 1 webhook source\"."
  @spec used_by(non_neg_integer(), non_neg_integer()) :: String.t()
  def used_by(0, 0), do: "Not used by any channel yet"
  def used_by(channels, webhook_sources), do: "Used by " <> users(channels, webhook_sources)

  @doc """
  Why a removal was refused, naming who still chooses the environment:
  "Staging is used by 3 channels and 1 webhook source. Change them first."
  """
  @spec refusal(String.t(), %{channels: non_neg_integer(), webhook_sources: non_neg_integer()}) ::
          String.t()
  def refusal(name, %{channels: channels, webhook_sources: webhook_sources}) do
    them = if channels + webhook_sources == 1, do: "it", else: "them"
    "#{name} is used by #{users(channels, webhook_sources)}. Change #{them} first."
  end

  defp users(channels, webhook_sources) do
    [
      channels > 0 && Integrations.count(channels, "channel"),
      webhook_sources > 0 && Integrations.count(webhook_sources, "webhook source")
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" and ")
  end

  @doc ~s(Names in a sentence: "Production", "Production and Staging", "A, B and C".)
  @spec sentence([String.t()]) :: String.t()
  def sentence([one]), do: one
  def sentence([first, second]), do: "#{first} and #{second}"
  def sentence([first | rest]), do: first <> ", " <> sentence(rest)

  @doc """
  The ref a new environment gets from its name: lowercase words joined by
  dashes, never one another environment already has.
  """
  @spec new_ref(String.t(), [String.t()]) :: String.t()
  def new_ref(display_name, taken) do
    base =
      display_name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 56)
      |> String.trim_trailing("-")
      |> then(&if(&1 == "", do: "environment", else: &1))

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      number -> "#{base}-#{number}"
    end)
    |> Enum.find(&(&1 not in taken))
  end
end
