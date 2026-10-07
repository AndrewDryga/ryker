# Credo's default checks, run with --strict by the gate, plus the house rules
# Ryker shares with Emisar (`credo/checks/`, each with fixture tests in
# test/ryker/credo_checks/). Credo's default file list covers lib/ and test/
# but not evals/, the development- and test-only home of the model
# evaluations, nor the checks themselves.

%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["credo/", "evals/", "lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      requires: ["credo/checks/*.ex"],
      checks: %{
        extra: [
          {Ryker.Checks.AcronymModuleCase, []},
          {Ryker.Checks.BroadcastEventAsData, []},
          {Ryker.Checks.ChangesetNoTruncate, []},
          {Ryker.Checks.ContextCryptoBoundary, []},
          {Ryker.Checks.ContextNoMapTakeDrop, []},
          {Ryker.Checks.EnumOverValidateInclusion, []},
          {Ryker.Checks.IL01NoInlineEctoDsl, []},
          {Ryker.Checks.IL02NoRepoGet, []},
          {Ryker.Checks.IL05TaggedReads, []},
          {Ryker.Checks.IL06QueryModulePure, []},
          {Ryker.Checks.IL07SchemaFieldsOnly, []},
          {Ryker.Checks.IL08ChangesetPure, []},
          {Ryker.Checks.IL08ValidationInChangesets, []},
          {Ryker.Checks.IL12NoFloatMoney, []},
          {Ryker.Checks.InlineBroadcast, []},
          {Ryker.Checks.MatchOnMapFieldValue, []},
          {Ryker.Checks.MultilineAliasGroup, []},
          {Ryker.Checks.MultilineDoColon, []},
          {Ryker.Checks.NoApplicationPutEnv, []},
          {Ryker.Checks.NoBlankBetweenDirectives, []},
          {Ryker.Checks.NoIfOnArgField, []},
          {Ryker.Checks.NoHashPrefixSlice, []},
          {Ryker.Checks.NoPipeInBranchHead, []},
          {Ryker.Checks.NoPreloadInRepoOpts, []},
          {Ryker.Checks.NoProcessDictionary, []},
          {Ryker.Checks.NoUnsafeDeserialization, []},
          {Ryker.Checks.PreferCaptureClosure, []},
          {Ryker.Checks.RepoExistsOverCount, []},
          {Ryker.Checks.ShortBindings, []},
          {Ryker.Checks.SubscribeNeedsConnected, []},
          {Ryker.Checks.TestContextPattern, []},
          {Ryker.Checks.TestNoProcessSleep, []},
          {Ryker.Checks.VendorViaWrapper, []},
          {Ryker.Checks.WebNoChangesetConstruction, []},
          {Ryker.Checks.WebNoRepoCalls, []},
          # IL-14: no String.to_atom on input; the atom table is never collected.
          {Credo.Check.Warning.UnsafeToAtom, []}
        ]
      }
    }
  ]
}
