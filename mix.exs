defmodule ProjectionManager.MixProject do
  use Mix.Project

  def project do
    [
      app: :projection_manager,
      version: "0.1.0",
      elixir: "~> 1.9",
      test_coverage: [tool: ExCoveralls],
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0.0-rc.6", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.10", only: :test}
    ]
  end
end
