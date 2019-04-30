defmodule After8.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :after8,
      version: @version,
      elixir: "~> 1.8",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),

      # Docs
      name: "After8",
      docs: [
        source_ref: "v#{@version}",
        source_url: "https://github.com/whatyouhide/after8"
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:castore, "~> 0.1"},
      {:mint, "~> 0.2"},
      {:bypass, "~> 1.0", only: :test},
      {:ex_doc, "~> 0.20", only: :dev},
      {:dialyxir, "1.0.0-rc.6", only: :dev, runtime: false}
    ]
  end
end
