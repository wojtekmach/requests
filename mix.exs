defmodule Requests.MixProject do
  use Mix.Project

  def project do
    [
      app: :requests,
      version: "0.1.0-dev",
      elixir: "~> 1.10",
      start_permanent: Mix.env() == :prod,
      docs: docs(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Requests.Application, []}
    ]
  end

  defp docs do
    [
      main: "Requests"
    ]
  end

  defp deps do
    [
      {:finch, "~> 0.6.0"},
      {:mint, github: "elixir-mint/mint", override: true},
      {:jason, "~> 1.0", optional: true},
      {:nimble_csv, "~> 1.0", optional: true},
      {:bypass, "~> 2.1", only: :test},
      {:ex_doc, ">= 0.0.0", only: :docs}
    ]
  end
end
