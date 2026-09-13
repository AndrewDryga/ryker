import Config

if config_env() == :prod do
  bootstrap = Ryker.Bootstrap.load!()

  config :ryker, Ryker.Repo, bootstrap.repo
  config :ryker, :bootstrap, bootstrap
  config :logger, level: bootstrap.log_level
end
