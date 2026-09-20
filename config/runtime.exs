import Config

if config_env() == :prod do
  bootstrap = Ryker.Bootstrap.load!()

  config :ryker, Ryker.Repo, bootstrap.repo
  config :ryker, :bootstrap, bootstrap
  config :ryker, :credential_key, bootstrap.credential_key
  config :ryker, :github_public_url, bootstrap.github_public_url
  config :ryker, :webhook_public_url, bootstrap.webhook_public_url
  config :logger, level: bootstrap.log_level
end
