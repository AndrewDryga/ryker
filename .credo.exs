# Credo's default file list covers lib/ and test/ but not evals/, the
# development- and test-only home of the model evaluations. Everything else is
# Credo's default configuration, run with --strict by the gate.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["evals/", "lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      }
    }
  ]
}
