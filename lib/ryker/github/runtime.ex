defmodule Ryker.GitHub.Runtime do
  @moduledoc """
  Owns GitHub App installation credentials, the single App webhook listener
  and the poller that fetches the deliveries GitHub could not make to it.

  The credential provider starts before the listener and before downstream
  delivery/publication workers can request an installation token.
  """
  use Supervisor
  alias Ryker.GitHub.{DeliveryPoller, InstallationTokens, OnboardingWorker, Server}
  alias Ryker.Options

  @spec start_link(map() | keyword()) :: Supervisor.on_start()
  def start_link(configuration) do
    Supervisor.start_link(__MODULE__, options!(configuration), name: __MODULE__)
  end

  @doc false
  @spec options!(map() | keyword()) :: %{
          app_id: pos_integer(),
          server: map(),
          tokens: map(),
          onboarding: map()
        }
  def options!(configuration) do
    configuration = normalize_configuration!(configuration)
    tokens = InstallationTokens.options!(Map.fetch!(configuration, :tokens))
    onboarding = OnboardingWorker.options!(Map.get(configuration, :onboarding, %{}))
    server = Server.options!(Map.fetch!(configuration, :server))
    app_id = Map.fetch!(configuration, :app_id)

    unless is_integer(app_id) and app_id > 0,
      do: raise(ArgumentError, "GitHub runtime configuration is invalid")

    %{app_id: app_id, onboarding: onboarding, server: server, tokens: tokens}
  end

  @impl Supervisor
  def init(options) do
    Supervisor.init(
      [
        {InstallationTokens, options.tokens},
        {OnboardingWorker, options.onboarding},
        {Server, options.server},
        # The listener takes what GitHub can reach it with; the poller fetches
        # what GitHub could not deliver, such as to 127.0.0.1.
        {DeliveryPoller,
         %{
           app_id: options.app_id,
           app_http: options.tokens.app_http,
           requester: options.tokens.requester,
           router: Server.router_options(options.server)
         }}
      ],
      strategy: :one_for_one
    )
  end

  defp normalize_configuration!(configuration) do
    Options.normalize!(
      configuration,
      [:app_id, :onboarding, :server, :tokens],
      [:app_id, :server, :tokens],
      "GitHub runtime configuration is invalid"
    )
  end
end
