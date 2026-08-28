defmodule Responder.MixProject do
  use Mix.Project

  def project do
    [
      app: :responder,
      version: "0.1.0",
      elixir: ">= 1.19.0 and < 1.21.0",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Responder.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ecto_sql, "~> 3.14"},
      {:postgrex, ">= 0.0.0"},
      {:jason, "~> 1.4"},
      {:jsv, "~> 0.22", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
