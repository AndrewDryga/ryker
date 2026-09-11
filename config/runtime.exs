import Config

if config_env() == :prod do
  bootstrap = Responder.Bootstrap.load!()

  config :responder, Responder.Repo, bootstrap.repo
  config :responder, :bootstrap, bootstrap
  config :logger, level: bootstrap.log_level
end
