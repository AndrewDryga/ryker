defmodule Ryker.GitHub.Runtime do
  @moduledoc """
  Owns GitHub App installation credentials and the single App webhook listener.

  The credential provider starts before the listener and before downstream
  delivery/publication workers can request an installation token.
  """

  use Supervisor

  alias Ryker.GitHub.{InstallationTokens, OnboardingWorker, Server}

  @spec start_link(map() | keyword()) :: Supervisor.on_start()
  def start_link(configuration) do
    Supervisor.start_link(__MODULE__, options!(configuration), name: __MODULE__)
  end

  @doc false
  @spec options!(map() | keyword()) :: %{server: map(), tokens: map(), onboarding: map()}
  def options!(configuration) do
    configuration = normalize_configuration!(configuration)
    tokens = InstallationTokens.options!(Map.fetch!(configuration, :tokens))
    onboarding = OnboardingWorker.options!(Map.get(configuration, :onboarding, %{}))
    server = Server.options!(Map.fetch!(configuration, :server))
    %{onboarding: onboarding, server: server, tokens: tokens}
  end

  @impl Supervisor
  def init(options) do
    Supervisor.init(
      [
        {InstallationTokens, options.tokens},
        {OnboardingWorker, options.onboarding},
        {Server, options.server}
      ],
      strategy: :one_for_one
    )
  end

  defp normalize_configuration!(configuration) when is_list(configuration) do
    if Keyword.keyword?(configuration) and
         Enum.uniq(Keyword.keys(configuration)) == Keyword.keys(configuration),
       do: configuration |> Map.new() |> normalize_configuration!(),
       else: raise(ArgumentError, "GitHub runtime configuration is invalid")
  end

  defp normalize_configuration!(%{} = configuration) do
    if Enum.sort(Map.keys(configuration)) in [[:server, :tokens], [:onboarding, :server, :tokens]],
      do: configuration,
      else: raise(ArgumentError, "GitHub runtime configuration is invalid")
  end

  defp normalize_configuration!(_configuration),
    do: raise(ArgumentError, "GitHub runtime configuration is invalid")
end
