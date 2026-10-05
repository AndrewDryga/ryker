defmodule Ryker.MixProject do
  use Mix.Project

  # The operator assets copied into the release under share/ryker, listed once
  # in release-assets.txt for this build step, the archive check and the image
  # build alike.
  @release_assets Path.expand("release-assets.txt", __DIR__)
                  |> File.read!()
                  |> String.split("\n", trim: true)
                  |> Enum.reject(&String.starts_with?(&1, "#"))

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

  # evals/ holds the model evaluations, their Mix tasks and the local
  # Unix-socket Coop client they drive. Product Coop work runs through the
  # fleet client alone, so none of it compiles into a release.
  defp elixirc_paths(:test), do: ["lib", "evals", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "evals"]
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
      {:jsv, "~> 0.22", only: :test},
      {:lazy_html, "~> 0.1.12", only: :test},
      # A repository's .agent/project.yaml names the check its reviews run
      # (Ryker.CoopFleet.JobCheck); the Slack app manifest test reads YAML too.
      {:yaml_elixir, "~> 2.12"},
      # The weekly report's send time is read in a person's time zone; Elixir
      # ships a database that knows only UTC. Its IANA data is compiled in, and
      # its updater stays off, so it never reaches the network.
      {:tz, "~> 0.28"},
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
