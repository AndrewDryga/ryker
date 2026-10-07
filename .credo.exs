# Credo's default checks, run with --strict by the gate, plus the house rules
# Ryker shares with Emisar (`credo/checks/`, each with fixture tests in
# test/ryker/credo_checks/). Credo's default file list covers lib/ and test/
# but not evals/, the development- and test-only home of the model
# evaluations, nor the checks themselves.

# Where queries have not moved into Query modules yet (IL-1, IL-2). Each change
# that moves a context's queries removes its paths; the list only shrinks.
query_modules_pending = [
  "lib/ryker/control_plane/actions.ex",
  "lib/ryker/control_plane/behavior_library.ex",
  "lib/ryker/control_plane/capability_tools.ex",
  "lib/ryker/control_plane/channel_context.ex",
  "lib/ryker/control_plane/channel_detail.ex",
  "lib/ryker/control_plane/channel_directory.ex",
  "lib/ryker/control_plane/console_people.ex",
  "lib/ryker/control_plane/conversation_lab.ex",
  "lib/ryker/control_plane/conversation_memory.ex",
  "lib/ryker/control_plane/environments.ex",
  "lib/ryker/control_plane/episode_projection.ex",
  "lib/ryker/control_plane/episode_trace.ex",
  "lib/ryker/control_plane/episode_trace/case_file.ex",
  "lib/ryker/control_plane/episode_trace/input.ex",
  "lib/ryker/control_plane/episode_trace/maintenance.ex",
  "lib/ryker/control_plane/episode_trace/outcome.ex",
  "lib/ryker/control_plane/episode_trace/preparation.ex",
  "lib/ryker/control_plane/episode_trace/tool_activity.ex",
  "lib/ryker/control_plane/episode_trace/work.ex",
  "lib/ryker/control_plane/feedback_projection.ex",
  "lib/ryker/control_plane/findings_projection.ex",
  "lib/ryker/control_plane/improvement_projection.ex",
  "lib/ryker/control_plane/improvement_requests.ex",
  "lib/ryker/control_plane/incident_projection.ex",
  "lib/ryker/control_plane/instruction_settings.ex",
  "lib/ryker/control_plane/learning_activity.ex",
  "lib/ryker/control_plane/learning_requests.ex",
  "lib/ryker/control_plane/local_routing_projection.ex",
  "lib/ryker/control_plane/memory_projection.ex",
  "lib/ryker/control_plane/model_requests.ex",
  "lib/ryker/control_plane/overview_projection.ex",
  "lib/ryker/control_plane/repository_names.ex",
  "lib/ryker/control_plane/repository_projection.ex",
  "lib/ryker/control_plane/running_system.ex",
  "lib/ryker/control_plane/schedule_projection.ex",
  "lib/ryker/control_plane/settings_view.ex",
  "lib/ryker/control_plane/subscription_projection.ex",
  "lib/ryker/control_plane/task_progress.ex",
  "lib/ryker/control_plane/thread_context.ex",
  "lib/ryker/control_plane/usage_projection.ex",
  "lib/ryker/control_plane/workspace_projection.ex"
]

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
          {Ryker.Checks.IL01NoInlineEctoDsl, pending: query_modules_pending},
          {Ryker.Checks.IL02NoRepoGet, pending: query_modules_pending},
          {Ryker.Checks.IL06QueryModulePure, []},
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
          # IL-14: no String.to_atom on input; the atom table is never collected.
          {Credo.Check.Warning.UnsafeToAtom, []}
        ]
      }
    }
  ]
}
