defmodule Ryker.MixProject do
  use Mix.Project

  @release_assets ~w(
    README.md
    CHANGELOG.md
    LICENSE
    SECURITY.md
    deploy/nginx/ryker.conf
    deploy/systemd/ryker.service
    deploy/systemd/ryker.env.example
    docs/elixir-ingress-admission.md
    docs/elixir-platform-adapters.md
    docs/operations.md
    docs/releasing.md
    docs/slack-app.md
    docs/testing.md
    scripts/activate-elixir-release.sh
    scripts/check-elixir-release.sh
    scripts/install-elixir-release.sh
  )

  def project do
    [
      app: :ryker,
      version: release_version(),
      elixir: ">= 1.19.0 and < 1.21.0",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      releases: releases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Ryker.Application, []},
      extra_applications: [:logger, :crypto, :public_key]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp release_version do
    case System.get_env("RYKER_ELIXIR_VERSION") do
      version when is_binary(version) and version != "" ->
        version

      _missing ->
        if Mix.env() == :prod,
          do: raise("RYKER_ELIXIR_VERSION is required for production builds"),
          else: "0.1.0-dev"
    end
  end

  defp deps do
    [
      {:bandit, "~> 1.12"},
      {:phoenix, "1.8.10"},
      {:phoenix_live_view, "1.2.9"},
      {:phoenix_html, "~> 4.3"},
      {:ecto_sql, "~> 3.14"},
      {:finch, "~> 0.23"},
      {:mint_web_socket, "~> 1.0"},
      {:postgrex, ">= 0.0.0"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:jsv, "~> 0.22", only: :test},
      {:lazy_html, "~> 0.1.12", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp releases do
    [
      ryker: [
        applications: [runtime_tools: :permanent],
        include_executables_for: [:unix],
        steps: [:assemble, &copy_release_assets/1, :tar]
      ]
    ]
  end

  defp copy_release_assets(%Mix.Release{path: release_path} = release) do
    overlays =
      Enum.map(@release_assets, fn relative_path ->
        overlay = Path.join(["share", "ryker", relative_path])
        source = Path.expand(relative_path, __DIR__)
        target = Path.join(release_path, overlay)
        File.mkdir_p!(Path.dirname(target))
        File.cp!(source, target)
        overlay
      end)

    %{release | overlays: overlays ++ release.overlays}
  end
end
