defmodule Ryker.Fixtures.ControlPlaneOptions do
  @moduledoc """
  The control-plane options map with every projection and action replaced by
  a deterministic double: one recorded workspace of channels, failures,
  memories, schedules and a fully decorated local conversation, so the HTTP
  routes and the secondary pages are exercised against the same durable
  shapes without a database.

  Actions and the channel projection report what they were called with to
  `parent`, so a test can assert that a refused request never reached them.
  """

  alias Ryker.ControlPlane.EpisodeCausality

  @secret String.duplicate("s", 32)

  @doc "The CSRF secret every token in `options/1` is minted with."
  def secret, do: @secret

  def options(parent) do
    %{
      actions: %{
        delete_lab_message: fn conversation_id, item_id ->
          send(parent, {:lab_message_delete, conversation_id, item_id})
          {:ok, %{status: :recorded}}
        end,
        discard_retention: fn ref ->
          send(parent, {:discarded_retention, ref})
          {:ok, %{ref: ref}}
        end,
        forget_memory: fn ref ->
          send(parent, {:forgot_memory, ref})
          {:ok, %{ref: ref}}
        end,
        resolve_episode: fn ref ->
          send(parent, {:resolved_episode, ref})
          {:ok, %{key: ref}}
        end,
        resolve_memory_review: fn ref, action, replacement ->
          send(parent, {:memory_review, ref, action, replacement})
          {:ok, %{ref: ref}}
        end,
        rearm_admission: fn ref ->
          send(parent, {:rearmed_admission, ref})
          {:ok, %{ref: ref}}
        end,
        rearm_delivery: fn ref ->
          send(parent, {:rearmed_delivery, ref})
          {:ok, %{delivery_ref: ref}}
        end,
        rearm_emisar: fn ref ->
          send(parent, {:rearmed_emisar, ref})
          {:ok, %{request_id: ref}}
        end,
        rearm_retention: fn ref ->
          send(parent, {:rearmed_retention, ref})
          {:ok, %{ref: ref}}
        end,
        rearm_slack_interaction: fn ref ->
          send(parent, {:rearmed_slack_interaction, ref})
          {:ok, %{event_ref: ref}}
        end,
        react_to_lab_message: fn conversation_id, message_ref, action, emoji_name ->
          send(parent, {:lab_reaction, conversation_id, message_ref, action, emoji_name})
          {:ok, %{status: :applied}}
        end,
        rearm_slack_incident: fn ref ->
          send(parent, {:rearmed_slack_incident, ref})
          {:ok, %{ref: ref}}
        end,
        retry_work: fn ref, _fingerprint ->
          send(parent, {:retried_work, ref})
          {:ok, %{key: ref}}
        end,
        review_episode: fn ref ->
          send(parent, {:reviewed_episode, ref})
          {:ok, %{key: ref}}
        end,
        act_on_lab_record: fn conversation_id, record_ref, action, choice_index ->
          send(
            parent,
            {:lab_record_action, conversation_id, record_ref, action, choice_index}
          )

          {:ok, %{status: :confirmed}}
        end,
        edit_lab_message: fn conversation_id, item_id, message ->
          send(parent, {:lab_message_edit, conversation_id, item_id, message})
          {:ok, %{status: :recorded}}
        end,
        view_lab_task_record: fn conversation_id, record_ref, view, params ->
          send(parent, {:lab_task_view, conversation_id, record_ref, view, params})

          navigation =
            if view == :diff do
              [
                %{
                  label: "Next",
                  offset: 2_400,
                  snapshot_digest: String.duplicate("a", 64)
                }
              ]
            else
              []
            end

          {:ok,
           %{
             body:
               if(view == :diff,
                 do: "Patch page for #{record_ref}",
                 else: "Timeline for #{record_ref}\n- Input admitted"
               ),
             kind: view,
             navigation: navigation,
             title: if(view == :diff, do: "Workspace diff", else: "Durable timeline")
           }}
        end,
        send_lab_message: fn conversation_id, message, attachments ->
          if byte_size(message) <= 20_000 do
            case attachments do
              [] -> send(parent, {:lab_message, conversation_id, message})
              files -> send(parent, {:lab_message, conversation_id, message, files})
            end

            {:ok, %{status: :recorded}}
          else
            {:error, {:invalid_conversation_lab, :message}}
          end
        end,
        set_behavior_status: fn ref, status ->
          send(parent, {{:behavior_status, status}, ref})
          {:ok, %{ref: ref, status: status}}
        end,
        set_schedule_status: fn ref, status ->
          send(parent, {{:schedule_status, status}, ref})
          {:ok, %{ref: ref, status: status}}
        end,
        run_schedule: fn ref ->
          send(parent, {:schedule_run_now, ref})
          {:ok, %{ref: ref, status: :dispatched}}
        end
      },
      csrf_secret: @secret,
      observability: %{
        health: fn -> {:ok, %{database: :ok}} end,
        metrics: fn ->
          {:ok,
           "ryker_queue_claimable{queue=\"ingress\"} 0\nryker_queue_oldest_age_seconds{queue=\"ingress\"} 0\n"}
        end,
        ready: fn -> {:ok, %{stalled_queues: []}} end
      },
      projection: %{
        readiness: fn ->
          %{
            chat: %{state: :ready, title: "Chat is ready", detail: "Ready."},
            slack: %{state: :not_connected}
          }
        end,
        configuration: fn -> [%{key: "runtime", value: "configured"}] end,
        operator_configuration: fn ->
          %{
            grants: [
              %{kind: "MCP tool", name: "search_slack", source: "/etc/ryker.yaml"}
            ],
            rows: [
              %{key: "runtime.mode", source: "/etc/ryker.yaml", value: "product"}
            ],
            source: "/etc/ryker.yaml"
          }
        end,
        channels: fn _params ->
          [
            %{
              channel_ref: "C456",
              episodes: 2,
              incident_room: false,
              last_at: ~U[2026-08-28 12:00:00Z],
              membership: :joined,
              participation: :mentions,
              private: false,
              environment_ref: "production",
              environment_name: "Production",
              environment_source: :channel,
              workspace_ref: "T123"
            }
          ]
        end,
        # An incident room's channel has a page of its own: the room is what
        # mentions it, so the room page's channel link always opens.
        channel: fn
          "T123", channel, params when channel in ["C456", "CINCIDENT"] ->
            send(parent, {:channel_params, params})

            {:ok,
             %{
               params: %{},
               scope: %Ryker.ControlPlane.ChannelScope{
                 workspace_ref: "T123",
                 channel_ref: channel,
                 canonical_workspace_ref: "slack:T123",
                 conversation_ref: "slack:T123:" <> channel,
                 repository_ref: "ryker"
               },
               channel: %{
                 kind: :channel,
                 membership: %{
                   deleted_at: nil,
                   external_shared: false,
                   generation: 1,
                   joined_at: ~U[2026-08-28 12:00:00Z],
                   left_at: nil,
                   private: true,
                   status: :joined,
                   updated_at: ~U[2026-08-28 12:00:00Z]
                 },
                 configuration: %{
                   actor_ref: "U123",
                   alert_policy: :offer,
                   invite_user_group_refs: [],
                   invite_user_refs: [],
                   participation: :mentions,
                   environment_ref: "production",
                   revision: 2,
                   saved_at: ~U[2026-08-28 12:00:00Z]
                 },
                 incident_room: nil,
                 environment: %{
                   emisar: "Production approvals",
                   name: "Production",
                   ref: "production",
                   repositories: [%{ref: "ryker", name: "acme/ryker"}],
                   source: :channel,
                   writable: "ryker"
                 }
               },
               environments: [%{ref: "production", name: "Production"}],
               episodes: %{
                 key: "episode_page",
                 items: [
                   %{
                     execution_mode: :live,
                     ref: "episode:one",
                     state: :working,
                     thread_ref: "1787832000.001000",
                     title: "checkout is returning 502s",
                     updated_at: ~U[2026-08-28 12:00:00Z]
                   }
                 ],
                 total: 1,
                 page: 1,
                 pages: 1
               },
               participation: %{source: :channel, value: :mentions},
               schedules: %{
                 key: "schedule_page",
                 items: [
                   %{
                     next_occurrence_at: ~U[2026-08-29 09:00:00Z],
                     ref: "schedule:one",
                     status: :active,
                     title: "Daily health"
                   }
                 ],
                 total: 1,
                 page: 1,
                 pages: 1
               },
               summaries: %{
                 key: "summary_page",
                 items: [
                   %{
                     ref: "summary:one",
                     title: "database",
                     text: "Replication is stalled",
                     groups: [{"Decisions", ["Fail over"]}],
                     repository_ref: "ryker",
                     thread_ref: "1787832000.001000",
                     updated_at: ~U[2026-08-28 12:00:00Z],
                     source_at: nil,
                     expires_at: nil,
                     recall_warning: nil,
                     maintenance_error: nil,
                     maintenance_retry_at: nil,
                     recall_count: 0,
                     last_recalled_at: nil,
                     request_path: "/timeline/episode%3Aone",
                     source: nil
                   }
                 ],
                 total: 1,
                 page: 1,
                 pages: 1
               },
               continuity: %{drafts: 0, handover_failures: 0},
               knowledge: %{key: "knowledge_page", items: [], total: 0, page: 1, pages: 1},
               rules: %{key: "rule_page", items: [], total: 0, page: 1, pages: 1},
               preferences: %{key: "preference_page", items: [], total: 0, page: 1, pages: 1},
               guidance: %{key: "guidance_page", items: [], total: 0, page: 1, pages: 1},
               memory: %{key: "memory_page", items: [], total: 0, page: 1, pages: 1},
               usage: %{
                 window: "7d",
                 mode: "all",
                 executions: 0,
                 measured: 0,
                 costed: 0,
                 input_tokens: 0,
                 cached_input_tokens: 0,
                 output_tokens: 0,
                 reasoning_tokens: 0,
                 cost_usd: nil,
                 link: "/activity?mode=all&usage_channel=slack%3AT123%3AC456&usage_window=7d",
                 usage_path: "/usage?mode=all&window=7d"
               },
               learning: %{enabled: true, needs_attention: 0, waiting: 0}
             }}

          _workspace, _channel, _params ->
            :not_found
        end,
        episode: fn
          "episode:one", _params ->
            {:ok,
             %{
               episode: %{
                 created_at: ~U[2026-08-28 11:00:00Z],
                 destination: "slack:T123:C456",
                 next_action: "continue work",
                 ref: "episode:one",
                 state: :working,
                 updated_at: ~U[2026-08-28 12:00:00Z]
               },
               events: [
                 %{
                   kind: :input_admitted,
                   occurred_at: ~U[2026-08-28 11:00:00Z],
                   summary: "input admitted"
                 }
               ],
               records: [%{kind: "evidence", status: :open, summary: "Repository checked"}],
               trace: %{
                 causality: EpisodeCausality.index([], [], []),
                 actions: [
                   %{
                     href: "/actions/episode/episode%3Aone/resolve",
                     label: "Close as no longer needed",
                     tone: :danger
                   },
                   %{
                     href: "/actions/episode/episode%3Aone/review",
                     label: "Mark ending reviewed",
                     tone: :secondary
                   }
                 ],
                 chapters: [
                   %{
                     blurb: "The input that opened this work.",
                     span: "+0 ms",
                     steps: [
                       %{
                         actor: "Episode kernel",
                         at: ~U[2026-08-28 11:00:00Z],
                         details: [
                           %{label: "Source", value: "slack:message:one"},
                           %{label: "Secret", value: "redacted"}
                         ],
                         duration_ms: nil,
                         href: nil,
                         id: "kernel-1",
                         stage: "Input",
                         state: "input admitted",
                         summary: "Authenticated input joined this episode.",
                         title: "Input admitted",
                         tone: nil
                       }
                     ],
                     title: "What came in"
                   }
                 ],
                 metrics: [
                   %{
                     detail: "continue work",
                     label: "State",
                     tone: nil,
                     value: "working"
                   }
                 ],
                 next_action: "continue work",
                 review: %{actor_ref: nil, at: nil, awaiting: true, current: false, note: nil},
                 source: %{
                   href: "https://slack.com/archives/C456/p1787832000001000",
                   label: "Open source message",
                   transport: "Slack"
                 },
                 stats: [%{label: "events", value: 1}],
                 stopped: %{
                   action: "Inspect the failure and retry only after its cause is corrected",
                   attempted: ["3 candidate attempts", "host validation recorded"],
                   headline: "Work needs operator recovery",
                   href: "/failures/work/episode%3Aone",
                   reason: "work execution blocked"
                 }
               },
               secret: "raw-secret-value"
             }}

          _ref, _params ->
            :not_found
        end,
        failure: &failure_row/2,
        failures: fn _params -> {:ok, failure_rows()} end,
        findings: fn _params -> %{items: [], total: 0, page: 1, pages: 1} end,
        incidents: fn _params ->
          [
            %{
              channel_name: "inc-latency",
              channel_ref: "CINCIDENT",
              channel_state: :active,
              episode_ref: "episode:incident",
              private: true,
              publication_ref: nil,
              publication_status: nil,
              ref: "incident:one",
              repository_ref: "ryker",
              requested_at: ~U[2026-08-28 11:55:00Z],
              status: :ready,
              title: "Investigate latency",
              updated_at: ~U[2026-08-28 12:00:00Z],
              workspace_ref: "T123"
            }
          ]
        end,
        incident: fn
          "incident:one" ->
            {:ok,
             %{
               lifecycle: [
                 %{
                   channel_ref: "CINCIDENT",
                   kind: :joined,
                   occurred_at: ~U[2026-08-28 12:00:00Z]
                 }
               ],
               publication: %{
                 branch_ref: "ryker/operator-incident",
                 commit_sha: String.duplicate("a", 40),
                 last_error: "stored diagnostic sha256:abc123",
                 pr_number: 42,
                 pr_url: "https://github.example/emisar/ryker/pull/42",
                 ref: "publication:incident",
                 repository: "ryker",
                 status: :blocked,
                 updated_at: ~U[2026-08-28 12:00:00Z]
               },
               records: [],
               room: %{
                 channel_name: "inc-latency",
                 channel_ref: "CINCIDENT",
                 channel_state: :active,
                 episode_ref: "episode:incident",
                 private: true,
                 ref: "incident:one",
                 repository_ref: "ryker",
                 requested_at: ~U[2026-08-28 11:55:00Z],
                 source_channel_ref: "C456",
                 source_episode_ref: "episode:one",
                 status: :ready,
                 title: "Investigate latency",
                 updated_at: ~U[2026-08-28 12:00:00Z],
                 workspace_ref: "T123"
               }
             }}

          _ref ->
            :not_found
        end,
        lab_artifact: fn
          "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
          "018f3ef7-1f62-7ee0-a83c-0c12f21d83e9",
          "artifact_chart" ->
            {:ok,
             %{
               byte_size: 13,
               data: <<137, 80, 78, 71, 13, 10, 26, 10, "chart">>,
               media_type: "image/png",
               name: "generated-chart.png",
               ref: "artifact_chart",
               sha256: String.duplicate("a", 64)
             }}

          _conversation_id, _turn_id, _artifact_ref ->
            :not_found
        end,
        lab_conversation: fn
          "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6" ->
            {:ok,
             %{
               blocked: false,
               conversation_id: "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
               conversation_ref: "control-plane:lab:018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
               episodes: [
                 %{
                   next_action: "continue_work",
                   ref: "episode:lab",
                   state: :working,
                   updated_at: ~U[2026-08-28 12:00:00Z],
                   work_status: :pending
                 }
               ],
               live: true,
               messages: [
                 %{
                   actor: :integration,
                   attachments: [],
                   cards: [],
                   editable: false,
                   event_kind: :event,
                   item_id: nil,
                   occurred_at: ~U[2026-08-28 11:58:00Z],
                   reactions: [],
                   ref: "webhook:event:one",
                   revision: 1,
                   state: nil,
                   status: :decided,
                   text: "Webhook universal · manual.unknown · revision 1"
                 },
                 %{
                   actor: :operator,
                   attachments: [
                     %{
                       bytes: 32,
                       media_type: "application/yaml",
                       name: "status.yaml",
                       ref: "artifact:input:lab:status",
                       status: "available"
                     }
                   ],
                   occurred_at: ~U[2026-08-28 11:59:00Z],
                   editable: true,
                   event_kind: :message,
                   item_id: "018f3ef7-1f62-7ee0-a83c-0c12f21d83e7",
                   reactions: [
                     %{
                       delivery_ref: "reaction:lab:one",
                       emoji_name: "eyes",
                       status: :delivered
                     }
                   ],
                   ref: "lab:event:one",
                   revision: 1,
                   state: nil,
                   status: :decided,
                   text: "Explain <unsafe> state"
                 },
                 %{
                   actor: :ryker,
                   attachments: [
                     %{
                       bytes: 13,
                       media_type: "image/png",
                       name: "generated-chart.png",
                       path:
                         "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/turns/018f3ef7-1f62-7ee0-a83c-0c12f21d83e9/artifacts/artifact_chart",
                       ref: "artifact_chart",
                       status: "available"
                     }
                   ],
                   cards: [
                     %{
                       action: :confirm_task,
                       choices: [],
                       details: [{"Repository", "ryker"}],
                       kind: "task_offer",
                       label: "Engineering task",
                       ref: "record:task_offer:lab",
                       status: :open,
                       summary: "Starts only after local confirmation.",
                       title: "Repair <unsafe> Lab flow",
                       url: nil
                     },
                     %{
                       action: :open_incident,
                       choices: [],
                       details: [],
                       kind: "task_offer",
                       label: "Local incident",
                       ref: "record:task_offer:incident",
                       status: :open,
                       summary: "Start a linked incident investigation locally.",
                       title: "Investigate service health",
                       url: nil
                     },
                     %{
                       action: :answer_input,
                       choices: ["Staging", "Production"],
                       details: [],
                       kind: "input_request",
                       label: "Input needed",
                       ref: "record:input_request:lab",
                       status: :open,
                       summary: "Choose the exact destination.",
                       title: "Where should this run?",
                       url: nil
                     },
                     %{
                       action: nil,
                       actions: [
                         :stop_task,
                         :view_diff,
                         :close_task,
                         :view_timeline,
                         :view_evidence,
                         :view_handoff,
                         :view_postmortem,
                         :approve_task_publication,
                         :check_task_publication,
                         :retry_task_publication,
                         :update_task_publication,
                         :discard_task_publication
                       ],
                       choices: [],
                       details: [{"Work", "pending"}],
                       kind: "task",
                       label: "Engineering task",
                       publication_ref: "publication:confirmed-task",
                       recovery_generation: 4,
                       ref: "record:task_offer:confirmed",
                       status: "working",
                       summary: "Focused tests are running.",
                       title: "Confirmed Lab task",
                       url: nil
                     },
                     %{
                       action: :confirm_memory,
                       choices: [],
                       details: [],
                       kind: "memory_offer",
                       label: "Memory proposal",
                       ref: "record:memory_offer:lab",
                       status: :open,
                       summary: "Remember the exact approved fact.",
                       title: "Primary repository",
                       url: nil
                     },
                     %{
                       action: :confirm_behavior,
                       choices: [],
                       details: [],
                       kind: "guidance_offer",
                       label: "Guidance",
                       ref: "record:guidance_offer:lab",
                       status: :open,
                       summary: "Use current evidence.",
                       title: "Investigation style",
                       url: nil
                     },
                     %{
                       action: :confirm_schedule,
                       choices: [],
                       details: [],
                       kind: "schedule_offer",
                       label: "Schedule",
                       ref: "record:schedule_offer:lab",
                       status: :open,
                       summary: "Review health daily.",
                       title: "Daily health",
                       url: nil
                     },
                     %{
                       action: :confirm_automation,
                       choices: [],
                       details: [],
                       kind: "automation_change_offer",
                       label: "Automation change",
                       ref: "record:automation_change_offer:lab",
                       status: :open,
                       summary: "Pause the exact revision.",
                       title: "Pause automation",
                       url: nil
                     },
                     %{
                       action: :confirm_post,
                       choices: [],
                       details: [
                         {"Destination", "control-plane:lab:018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"}
                       ],
                       kind: "slack_post_offer",
                       label: "Additional message",
                       ref: "record:slack_post_offer:lab",
                       status: :open,
                       summary: "Post this only after confirmation.",
                       title: "Post this in the conversation",
                       url: nil
                     },
                     %{
                       action: :review_publication,
                       choices: [],
                       details: [],
                       kind: "publication_offer",
                       label: "Publication review",
                       ref: "record:publication_offer:lab",
                       status: :open,
                       summary: "Review the exact candidate.",
                       title: "Review change",
                       url: nil
                     },
                     %{
                       action: :approve_publication,
                       choices: [],
                       details: [],
                       kind: "publication_review",
                       label: "Publication review",
                       ref: "record:publication_review:lab",
                       status: :reviewed,
                       summary: "The candidate passed review.",
                       title: "Publish change",
                       url: nil
                     },
                     %{
                       action: :check_publication,
                       choices: [],
                       details: [],
                       kind: "publication_result",
                       label: "Published draft",
                       ref: "record:publication_result:lab",
                       status: :published,
                       summary: "The draft pull request was published.",
                       title: "Published change",
                       url: "https://github.example/pull/42"
                     }
                   ],
                   feedback_reactions: [
                     %{
                       actor_ref: "control-plane:user:local-operator",
                       emoji_name: "heart",
                       occurred_at: ~U[2026-08-28 12:00:01Z]
                     }
                   ],
                   message_ref: "control-plane-message:lab-reply",
                   occurred_at: ~U[2026-08-28 12:00:00Z],
                   ref: "delivery:lab",
                   state: "complete",
                   status: :settled,
                   text: "The durable answer is ready."
                 }
               ],
               pending: 0
             }}

          _id ->
            :not_found
        end,
        lab_index: fn ->
          [
            %{
              id: "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
              message_count: 1,
              ref: "control-plane:lab:018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
              title: "Explain <unsafe> state",
              updated_at: ~U[2026-08-28 12:00:00Z]
            }
          ]
        end,
        behavior: fn
          "behavior:one" ->
            {:ok,
             %{
               kind: :standing_assignment,
               ref: "behavior:one",
               status: "active",
               payload: %{"title" => "Triage deployment alerts"}
             }}

          _ ->
            :not_found
        end,
        learned: fn params ->
          %{
            counts: %{context: 0, knowledge: 1},
            kind: "knowledge",
            q: params["q"] || "",
            page: 1,
            pages: 1,
            total: 1,
            related_to: nil,
            source_parent: nil,
            selected: nil,
            rebuild: nil,
            history: [],
            history_page: 1,
            history_pages: 1,
            learning: nil,
            items: [
              %{
                id: "018f3ef7-1f62-7ee0-a83c-0c12f21d83aa",
                title: "Deploy window",
                conversation: "#infra",
                conversation_path: "/activity?conversation=slack%3AT123%3AC456",
                workspace: nil,
                at: ~U[2026-08-28 12:00:00Z],
                changed_at: ~U[2026-08-28 12:00:00Z],
                source_at: ~U[2026-08-28 11:00:00Z],
                repository: "ryker",
                text: "Deploys happen after 15:00 UTC on weekdays.",
                groups: [],
                source: nil,
                available: true,
                source_count: 0,
                source_path: nil,
                version: 1,
                request_path: nil,
                expires_at: nil
              }
            ]
          }
        end,
        learning: fn _params ->
          %{
            state: :on,
            enabled: true,
            worker_running: true,
            counts: %{queued: 0, running: 0, applied: 0, no_change: 0, deferred: 0, superseded: 0},
            waiting_inputs: 2,
            oldest_waiting_at: ~U[2026-08-28 12:00:00Z],
            attention: %{items: [], page: 1, pages: 1, total: 0},
            recent: %{items: [], page: 1, pages: 1, total: 0, outcome: ""},
            handover_failures: %{total: 0, items: [], page: 1, pages: 1},
            selected: nil,
            receipt: nil
          }
        end,
        memory: fn _params ->
          %{
            behaviors: [
              %{
                kind: :standing_assignment,
                ref: "behavior:one",
                status: :active,
                subject: "Triage deployment alerts"
              }
            ],
            memories: [
              %{
                kind: :repository_binding,
                ref: "memory:one",
                scope: :workspace,
                value: "ryker",
                applicability: nil,
                status: :active,
                subject: "checkout-api"
              }
            ],
            reviews: [
              %{
                "entries" => [
                  %{
                    "kind" => "entity_relationship",
                    "memory_ref" => "memory:one",
                    "scope" => "workspace",
                    "scope_ref" => "slack:T123",
                    "status" => "active",
                    "subject" => "checkout-api",
                    "value" => "payments",
                    "visibility" => "workspace"
                  },
                  %{
                    "kind" => "entity_relationship",
                    "memory_ref" => "memory:duplicate",
                    "scope" => "workspace",
                    "scope_ref" => "slack:T123",
                    "status" => "active",
                    "subject" => "payments-api",
                    "value" => "payments",
                    "visibility" => "workspace"
                  }
                ],
                "kind" => "duplicate",
                "reason" => "Same value",
                "review_ref" => "memory-review:one",
                "status" => "pending"
              },
              %{
                "entries" => [
                  %{
                    "kind" => "repository_binding",
                    "memory_ref" => "memory:two",
                    "scope" => "repository",
                    "scope_ref" => "ryker",
                    "status" => "active",
                    "subject" => "primary_repository",
                    "value" => "ryker",
                    "visibility" => "workspace"
                  }
                ],
                "kind" => "stale",
                "reason" => "Not recently used",
                "review_ref" => "memory-review:two",
                "status" => "pending"
              }
            ],
            schedules: [
              %{
                next_occurrence_at: nil,
                ref: "schedule:one",
                status: :paused,
                title: "Daily health check"
              }
            ]
          }
        end,
        overview: fn ->
          %{
            counts: %{active: 3, blocked: 1, delivery_pending: 1, waiting: 1},
            needs_attention: [%{kind: :blocked_work, ref: "episode:one", title: "Blocked work"}]
          }
        end,
        repositories: fn _params ->
          [
            %{
              channels: 1,
              configured: %{contributor_policy: "ryker-write"},
              environments: ["Production"],
              freshness: %{
                fetched_at: "2026-08-28T11:59:00Z",
                recorded_at: ~U[2026-08-28 12:00:00Z],
                remote_identity: "origin",
                requested_revision: "refs/heads/main",
                resolved_revision: String.duplicate("a", 40),
                stale_base_revision: nil,
                stale_base_status: "current",
                version: 2,
                workspace_base_revision: String.duplicate("a", 40)
              },
              publications: 0,
              ref: "ryker",
              schedules: 1,
              sessions: 2,
              workers: [
                %{
                  last_seen_at: ~U[2026-08-28 12:00:00Z],
                  revision: "commit:abc123",
                  state: :eligible,
                  worker_ref: "coop-worker-one"
                }
              ]
            }
          ]
        end,
        schedules: fn _params ->
          [
            %{
              authority: :read_only,
              destination_conversation_ref: "slack:T123:C456",
              destination_thread_ref: nil,
              destination_transport: "slack",
              expires_at: nil,
              expires_local: nil,
              failures: 0,
              next_local: ~N[2026-08-29 09:00:00],
              next_occurrence_at: ~U[2026-08-29 09:00:00Z],
              now_local: ~N[2026-08-28 12:00:00],
              once_local: nil,
              recurrence: %{"kind" => "daily", "time" => "09:00:00"},
              ref: "schedule:one",
              repository: "ryker",
              status: :active,
              task: "Check current health.",
              timezone: "UTC",
              title: "Daily health",
              updated_at: ~U[2026-08-28 12:00:00Z]
            }
          ]
        end,
        subscriptions: fn _params ->
          [
            %{
              cursor_digest: String.duplicate("c", 64),
              deadline_at: ~U[2026-08-29 12:00:00Z],
              episode_ref: "episode:one",
              last_observation_digest: nil,
              last_observed_at: nil,
              matcher_digest: String.duplicate("m", 64),
              poll_after: ~U[2026-08-29 11:55:00Z],
              ref: "event-subscription:one",
              title: "A matching GitHub update",
              condition: nil,
              episode_title: "Review the deployment",
              episode_href: "/timeline/episode%3Aone",
              place: nil,
              repository: "ryker",
              source_label: "GitHub",
              target_url: nil,
              resolution_kind: nil,
              revision: 1,
              source_kind: "github",
              status: :active,
              trigger_type: "source_event",
              updated_at: ~U[2026-08-28 12:00:00Z]
            }
          ]
        end,
        schedule: fn
          "schedule:one" ->
            {:ok,
             %{
               occurrences: [
                 %{
                   accepted_at: nil,
                   delivered_at: ~U[2026-08-28 09:05:30Z],
                   due_local: ~N[2026-08-28 09:00:00],
                   episode_ref: "episode:one",
                   episode_state: :complete,
                   failure_cause: nil,
                   failure_code: nil,
                   failure_detail: nil,
                   finished_at: ~U[2026-08-28 09:05:24Z],
                   missed_reason: nil,
                   ref: "occurrence:one",
                   scheduled_for: ~U[2026-08-28 09:00:00Z],
                   started_at: ~U[2026-08-28 09:05:05Z],
                   status: :dispatched,
                   trigger: :scheduled,
                   turn_status: :settled,
                   work_attempt_count: 2
                 }
               ],
               schedule: %{
                 authority: :read_only,
                 confirmed_at: ~U[2026-08-27 12:00:00Z],
                 destination_conversation_ref: "slack:T123:C456",
                 destination_thread_ref: "1787832000.001000",
                 destination_transport: "slack",
                 expires_at: nil,
                 expires_local: nil,
                 failure_count: 0,
                 last_error: nil,
                 next_local: ~N[2026-08-29 09:00:00],
                 next_occurrence_at: ~U[2026-08-29 09:00:00Z],
                 now_local: ~N[2026-08-28 12:00:00],
                 once_local: nil,
                 recurrence: %{"kind" => "daily", "time" => "09:00:00"},
                 ref: "schedule:one",
                 repository: "ryker",
                 revision: 1,
                 source_episode_ref: "episode:one",
                 source_request: %{
                   href: "/timeline/episode%3Aone",
                   title: "Set up a daily health check"
                 },
                 status: :active,
                 task: "Check current health.",
                 timezone: "UTC",
                 title: "Daily health",
                 updated_at: ~U[2026-08-28 12:00:00Z]
               }
             }}

          _ref ->
            :not_found
        end,
        usage: fn _params ->
          %{
            channels: [],
            days: [
              %{
                attempts: 1,
                cost_usd: Decimal.new("0.0125"),
                date: ~D[2026-08-28],
                measured: 1,
                tokens: 2_325
              }
            ],
            repositories: [],
            targets: [
              %{
                attempts: 1,
                cost_usd: Decimal.new("0.0125"),
                costed: 1,
                effort: "high",
                measured: 1,
                model: "opus",
                provider: "claude",
                target: "claude:opus/high@work",
                tokens: 2_325
              }
            ],
            totals: %{
              attempts: 1,
              average_host_ms: 250,
              average_provider_ms: 5_000,
              average_queued_ms: 5_000,
              cache_hit_rate: 0.4,
              cached_input_tokens: 800,
              cost_usd: Decimal.new("0.0125"),
              costed: 1,
              input_tokens: 1_200,
              measurement_errors: 0,
              output_tokens: 300,
              reasoning_tokens: 25,
              timed: 1,
              usage_measured: 1
            },
            window: "24h"
          }
        end,
        workspace: fn
          "workspace:blocked" ->
            {:ok,
             %{
               action: :rearm,
               execution_kind: :work,
               kind: "coop_session",
               repository: "ryker",
               ref: "workspace:blocked",
               state: :complete,
               status: :blocked,
               summary: "coop_protocol_error",
               updated_at: ~U[2026-08-28 12:00:00Z]
             }}

          "workspace:unmerged" ->
            {:ok,
             %{
               action: :discard_unmerged,
               execution_kind: :work,
               kind: "coop_session",
               repository: "ryker",
               ref: "workspace:unmerged",
               state: :complete,
               status: :retained,
               summary: "unpublished_unmerged",
               updated_at: ~U[2026-08-28 12:00:00Z]
             }}

          "workspace:dirty" ->
            {:ok,
             %{
               action: nil,
               execution_kind: :work,
               kind: "coop_session",
               repository: "ryker",
               ref: "workspace:dirty",
               state: :complete,
               status: :retained,
               summary: "dirty",
               updated_at: ~U[2026-08-28 12:00:00Z]
             }}

          _ref ->
            :not_found
        end,
        workspace_storage: fn ->
          %{
            budget: %{
              disposable_bytes_limit: 10_737_418_240,
              reclaim_target_seconds: 3_600,
              storage_high_watermark_bytes: 64_424_509_440,
              storage_low_watermark_bytes: 48_318_382_080,
              storage_reserve_bytes: 5_368_709_120
            },
            preview: [
              %{
                eligible_age_seconds: 42,
                kind: :work,
                reason: "grace expired; ask Coop for a discard plan",
                ref: "workspace:blocked",
                repository: "ryker",
                status: :grace,
                target: "coop-session-1"
              }
            ],
            workers: [
              %{
                allocation: "refused",
                bytes: %{
                  "capacity_bytes" => 536_870_912_000,
                  "disposable_bytes" => 9_663_676_416,
                  "free_bytes" => 4_294_967_296,
                  "protected_bytes" => 21_474_836_480,
                  "reserve_bytes" => 5_368_709_120,
                  "unattributed_bytes" => nil
                },
                id: "worker-a",
                last_seen_at: ~U[2026-08-28 12:00:00Z],
                measured_at: "2026-08-28T12:00:00Z",
                measurement: :fresh,
                reclaimed_bytes: 1_073_741_824,
                refusal_reason: "reserve_exhausted",
                state: :busy
              }
            ]
          }
        end,
        workspaces: fn _params ->
          [
            %{
              action: :rearm,
              execution_kind: :work,
              kind: "coop_session",
              repository: "ryker",
              ref: "workspace:blocked",
              state: :complete,
              status: :blocked,
              summary: "coop_protocol_error",
              updated_at: ~U[2026-08-28 12:00:00Z]
            },
            %{
              action: :discard_unmerged,
              execution_kind: :work,
              kind: "coop_session",
              repository: "ryker",
              ref: "workspace:unmerged",
              state: :complete,
              status: :retained,
              summary: "unpublished_unmerged",
              updated_at: ~U[2026-08-28 12:00:00Z]
            },
            %{
              action: nil,
              execution_kind: :work,
              kind: "coop_session",
              repository: "ryker",
              ref: "workspace:dirty",
              state: :complete,
              status: :retained,
              summary: "dirty",
              updated_at: ~U[2026-08-28 12:00:00Z]
            }
          ]
        end
      }
    }
  end

  defp failure_row(kind, ref) do
    case Enum.find(failure_rows(), &(&1.kind == kind and &1.ref == ref)) do
      nil -> :not_found
      row -> {:ok, row}
    end
  end

  # The recorded failures: one of every recoverable kind and one publication,
  # which has no confirmed recovery. The list and a single failure's page read
  # the same rows, as the real projection does.
  defp failure_rows do
    [
      %{
        action: :rearm,
        attempt_count: 3,
        delivery_kind: :message,
        detail: "stored diagnostic sha256:delivery",
        destination: "slack:T123:C456 / 1787832000.001",
        episode_ref: "episode:one",
        kind: "delivery",
        ref: "delivery:one",
        source: "message delivery",
        status: :blocked,
        summary: "provider_unavailable",
        updated_at: ~U[2026-08-28 12:00:00Z]
      },
      %{
        action: :rearm,
        attempt_count: 3,
        detail: "stored diagnostic sha256:admission",
        destination: "github:github-main:repository:99 / github:github-main:pull:42",
        episode_ref: nil,
        kind: "admission",
        ref: "ingress-input:one",
        source: "github:github-main · github-delivery-one",
        status: :blocked,
        summary: "operation_uncertain",
        updated_at: ~U[2026-08-28 11:59:00Z]
      },
      %{
        action: nil,
        attempt_count: 1,
        detail: "stored diagnostic sha256:publication",
        destination: "ryker / symbolicator-deploy",
        episode_ref: "episode:one",
        kind: "publication",
        ref: "publication:one",
        source: nil,
        status: :blocked,
        summary: "publication_repository_not_configured",
        updated_at: ~U[2026-08-28 11:58:00Z]
      },
      %{
        action: :retry,
        attempt_count: 1,
        episode_ref: "episode:blocked",
        kind: "work",
        ref: "episode:blocked",
        status: :blocked,
        summary: "work_execution_blocked",
        updated_at: ~U[2026-08-28 11:58:00Z],
        work_recovery: %{
          action: :retry,
          action_label: "Retry work",
          cause: "The worker did not take or finish one of this task's commands in time.",
          delivery: "This response has not been sent.",
          explained: true,
          fingerprint: String.duplicate("a", 64),
          headline: "The task stopped before it could finish",
          kind: :execution,
          model_output: nil,
          next_step: "Check that the worker is connected and polling, then retry this task.",
          not_started: false,
          resume: nil,
          retry_effect: "Starts a fresh logical turn.",
          setup_href: nil,
          workspace: "Workspace recovery has not been confirmed."
        }
      },
      %{
        action: :rearm,
        kind: "emisar",
        ref: "approval:one",
        status: :blocked,
        summary: "emisar_unavailable",
        updated_at: ~U[2026-08-28 11:57:00Z]
      },
      %{
        action: :rearm,
        kind: "slack_interaction",
        ref: "interaction:one",
        status: :blocked,
        summary: "slack_unavailable",
        updated_at: ~U[2026-08-28 11:56:00Z]
      },
      %{
        action: :rearm,
        kind: "slack_incident",
        ref: "incident-room:one",
        status: :blocked,
        summary: "incident_audience_member_invalid",
        updated_at: ~U[2026-08-28 11:55:00Z]
      },
      %{
        action: :rearm,
        attempt_count: 1,
        cleanup_phase: :plan_pending,
        closed_at: ~U[2026-08-28 11:40:00Z],
        discarded_at: nil,
        episode_ref: "episode:one",
        execution_kind: :work,
        kind: "retention",
        ref: "workspace:blocked",
        request_state: :complete,
        source: "ryker",
        status: :blocked,
        summary: "coop_protocol_error",
        updated_at: ~U[2026-08-28 11:54:00Z]
      }
    ]
  end
end
