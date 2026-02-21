defmodule WeightedSemaphore.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/yoavgeva/weighted_semaphore"

  def project do
    [
      app: :weighted_semaphore,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      name: "WeightedSemaphore",
      description: "A weighted semaphore for bounding concurrent access to a shared resource.",
      dialyzer: [plt_add_apps: [:ex_unit]]
    ]
  end

  def application do
    []
  end

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "WeightedSemaphore",
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
