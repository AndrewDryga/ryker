defmodule Responder.ControlPlane.RouterTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Responder.ControlPlane.{HTML, Router}

  @secret String.duplicate("s", 32)

  test "renders an offline overview with hard browser boundaries" do
    conn = request(:get, "/")

    assert conn.status == 200

    assert get_resp_header(conn, "content-security-policy") == [
             "default-src 'none'; style-src 'self'; script-src 'self'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
           ]

    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-responder-version") == ["0.1.0-dev"]
    assert conn.resp_body =~ "Responder control plane"
    assert conn.resp_body =~ "What needs attention"
    assert conn.resp_body =~ "Blocked work"
    refute conn.resp_body =~ "https://"
    refute conn.resp_body =~ "<script"
  end

  test "the conversation lab sends through a CSRF-protected durable action and refreshes locally" do
    index = request(:get, "/lab")
    assert index.status == 200
    assert index.resp_body =~ "Talk to Responder without posting to Slack"
    assert index.resp_body =~ "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"

    fresh = request(:get, "/lab/new")
    assert fresh.status == 303
    [location] = get_resp_header(fresh, "location")
    assert "/lab/" <> generated_id = location
    assert {:ok, _uuid} = Ecto.UUID.cast(generated_id)

    conversation = request(:get, "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6")
    assert conversation.status == 200
    assert conversation.resp_body =~ "Local model conversation"
    assert conversation.resp_body =~ "Explain &lt;unsafe&gt; state"
    assert conversation.resp_body =~ "The durable answer is ready."
    assert conversation.resp_body =~ "data-live=\"true\""
    assert conversation.resp_body =~ "data-lab-status"
    assert conversation.resp_body =~ "data-max-bytes=\"20000\""
    assert conversation.resp_body =~ "src=\"/static/lab.js\""
    refute conversation.resp_body =~ "<unsafe>"

    [_, token] = Regex.run(~r/name="_token" value="([^"]+)"/, conversation.resp_body)

    rejected =
      request(
        :post,
        "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/messages",
        URI.encode_query(%{"_token" => "wrong", "message" => "Follow up"})
      )

    assert rejected.status == 403
    refute_received {:lab_message, _id, _message}

    accepted =
      request(
        :post,
        "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/messages",
        URI.encode_query(%{"_token" => token, "message" => "Follow up"})
      )

    assert accepted.status == 303

    assert get_resp_header(accepted, "location") == [
             "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"
           ]

    assert_received {:lab_message, "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6", "Follow up"}

    assert request(
             :post,
             "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/messages",
             URI.encode_query(%{"_token" => token, "message" => String.duplicate("x", 20_001)})
           ).status == 422

    javascript = request(:get, "/static/lab.js")
    assert javascript.status == 200
    assert javascript.resp_body =~ "data-lab-stream"
    assert javascript.resp_body =~ "data-lab-status"
    assert javascript.resp_body =~ "TextEncoder"
    refute javascript.resp_body =~ "http://"
    refute javascript.resp_body =~ "https://"
  end

  test "the built-in journey guide reflects configured product owners" do
    guide = request(:get, "/manual-tests")
    assert guide.status == 200
    assert guide.resp_body =~ "Slack threads, cards, and emoji"
    assert guide.resp_body =~ "GitHub comments, reviews, and reactions"
    assert guide.resp_body =~ "Universal signed webhook"
    assert guide.resp_body =~ "X-Responder-Signature"
    assert guide.resp_body =~ "X-Responder-Item-ID"
    assert guide.resp_body =~ "RESPONDER_WEBHOOK_SECRET"
    assert guide.resp_body =~ "curl --fail-with-body"
    assert guide.resp_body =~ "Recovery and retention"
    refute guide.resp_body =~ "token="
  end

  test "lists bounded episodes and renders one whitelisted detail record" do
    list = request(:get, "/episodes?state=working&page=2")
    assert list.status == 200
    assert list.resp_body =~ "episode:one"
    assert list.resp_body =~ "working"

    detail = request(:get, "/episodes/episode%3Aone")
    assert detail.status == 200
    assert detail.resp_body =~ "Timeline"
    assert detail.resp_body =~ "input admitted"
    refute detail.resp_body =~ "raw-secret-value"
  end

  test "memory mutations require a local two-step confirmation and exact CSRF token" do
    confirm = request(:get, "/actions/memory/memory%3Aone/forget")
    assert confirm.status == 200
    assert confirm.resp_body =~ "Forget checkout-api memory?"
    [_, token] = Regex.run(~r/name="_token" value="([^"]+)"/, confirm.resp_body)

    refused =
      request(
        :post,
        "/actions/memory/memory%3Aone/forget",
        URI.encode_query(%{"_token" => "wrong"})
      )

    assert refused.status == 403
    refute_received {:forgot_memory, _ref}

    accepted =
      request(
        :post,
        "/actions/memory/memory%3Aone/forget",
        URI.encode_query(%{"_token" => token})
      )

    assert accepted.status == 303
    assert get_resp_header(accepted, "location") == ["/memory"]
    assert_received {:forgot_memory, "memory:one"}
  end

  test "a blocked delivery can be rearmed only from its exact confirmed intent" do
    failures = request(:get, "/failures")
    assert failures.status == 200
    assert failures.resp_body =~ "delivery:one"
    assert failures.resp_body =~ "/episodes/episode%3Aone"
    assert failures.resp_body =~ "/failures/admission/ingress-input%3Aone"
    assert failures.resp_body =~ "slack:T123:C456"
    assert failures.resp_body =~ ">3<"
    assert failures.resp_body =~ "/actions/delivery/delivery%3Aone/rearm"

    admission = request(:get, "/failures/admission/ingress-input%3Aone")
    assert admission.status == 200
    assert admission.resp_body =~ "github:github-main"
    assert admission.resp_body =~ "github-delivery-one"
    assert admission.resp_body =~ "github:github-main:repository:99"
    assert admission.resp_body =~ "Attempts"

    confirm = request(:get, "/actions/delivery/delivery%3Aone/rearm")
    assert confirm.status == 200
    assert confirm.resp_body =~ "Rearm this delivery?"
    assert confirm.resp_body =~ "href=\"/failures\""
    [_, token] = Regex.run(~r/name="_token" value="([^"]+)"/, confirm.resp_body)

    accepted =
      request(
        :post,
        "/actions/delivery/delivery%3Aone/rearm",
        URI.encode_query(%{"_token" => token})
      )

    assert accepted.status == 303
    assert get_resp_header(accepted, "location") == ["/failures"]
    assert_received {:rearmed_delivery, "delivery:one"}

    stale = request(:get, "/actions/delivery/delivery%3Astale/rearm")
    assert stale.status == 404
  end

  test "each recoverable blocked custody has a typed confirmed action" do
    failures = request(:get, "/failures")

    for {kind, ref, action, title, received} <- [
          {"admission", "ingress-input:one", "rearm", "Rearm this admission?",
           {:rearmed_admission, "ingress-input:one"}},
          {"work", "episode:blocked", "retry", "Retry this blocked work?",
           {:retried_work, "episode:blocked"}},
          {"emisar", "approval:one", "rearm", "Rearm this approval monitor?",
           {:rearmed_emisar, "approval:one"}},
          {"slack_interaction", "interaction:one", "rearm", "Rearm this Slack repaint?",
           {:rearmed_slack_interaction, "interaction:one"}},
          {"slack_incident", "incident-room:one", "rearm", "Rearm this incident room?",
           {:rearmed_slack_incident, "incident-room:one"}}
        ] do
      encoded_ref = URI.encode(ref, &URI.char_unreserved?/1)
      path = "/actions/#{kind}/#{encoded_ref}/#{action}"
      assert failures.resp_body =~ path

      confirmation = request(:get, path)
      assert confirmation.status == 200
      assert confirmation.resp_body =~ title
      [_, token] = Regex.run(~r/name="_token" value="([^"]+)"/, confirmation.resp_body)

      accepted = request(:post, path, URI.encode_query(%{"_token" => token}))
      assert accepted.status == 303
      assert get_resp_header(accepted, "location") == ["/failures"]
      assert_received ^received
    end
  end

  test "retention recovery is confirmed from the exact current workspace state" do
    workspaces = request(:get, "/workspaces")
    assert workspaces.status == 200
    assert workspaces.resp_body =~ "workspace:blocked"
    assert workspaces.resp_body =~ "/actions/retention/workspace%3Ablocked/rearm"
    assert workspaces.resp_body =~ "/actions/retention/workspace%3Aunmerged/discard"
    refute workspaces.resp_body =~ "/actions/retention/workspace%3Adirty/discard"

    rearm = request(:get, "/actions/retention/workspace%3Ablocked/rearm")
    assert rearm.status == 200
    assert rearm.resp_body =~ "Rearm this cleanup?"
    [_, rearm_token] = Regex.run(~r/name="_token" value="([^"]+)"/, rearm.resp_body)

    accepted_rearm =
      request(
        :post,
        "/actions/retention/workspace%3Ablocked/rearm",
        URI.encode_query(%{"_token" => rearm_token})
      )

    assert accepted_rearm.status == 303
    assert get_resp_header(accepted_rearm, "location") == ["/workspaces"]
    assert_received {:rearmed_retention, "workspace:blocked"}

    discard = request(:get, "/actions/retention/workspace%3Aunmerged/discard")
    assert discard.status == 200
    assert discard.resp_body =~ "Discard this unmerged workspace?"
    assert discard.resp_body =~ "fresh exact Coop discard plan"
    [_, discard_token] = Regex.run(~r/name="_token" value="([^"]+)"/, discard.resp_body)

    accepted_discard =
      request(
        :post,
        "/actions/retention/workspace%3Aunmerged/discard",
        URI.encode_query(%{"_token" => discard_token})
      )

    assert accepted_discard.status == 303
    assert_received {:discarded_retention, "workspace:unmerged"}

    assert request(:get, "/actions/retention/workspace%3Adirty/discard").status == 404
  end

  test "rejects DNS-rebinding hosts and non-loopback peers" do
    assert request(:get, "/", "evil.example", {127, 0, 0, 1}).status == 421
    assert request(:get, "/", "localhost", {10, 0, 0, 2}).status == 403
  end

  test "serves no external assets and names missing routes" do
    css = request(:get, "/static/app.css")
    assert css.status == 200
    assert get_resp_header(css, "content-type") |> hd() =~ "text/css"
    assert css.resp_body =~ "font-family"

    assert request(:get, "/missing").status == 404
  end

  test "serves payload-free health readiness and Prometheus metrics on loopback" do
    health = request(:get, "/healthz")
    assert health.status == 200
    assert health.resp_body == "ok\n"

    ready = request(:get, "/readyz")
    assert ready.status == 200
    assert ready.resp_body == "ready\n"

    metrics = request(:get, "/metrics")
    assert metrics.status == 200
    assert get_resp_header(metrics, "content-type") |> hd() =~ "text/plain"
    assert metrics.resp_body =~ "responder_queue_claimable"
    refute metrics.resp_body =~ "raw-secret"

    unavailable =
      options()
      |> put_in([:observability, :ready], fn -> {:error, :stalled} end)
      |> then(&request_with_options(:get, "/readyz", nil, &1))

    assert unavailable.status == 503
    assert unavailable.resp_body == "not ready\n"

    assert request(:get, "/metrics", "evil.example", {127, 0, 0, 1}).status == 421
  end

  test "renders every bounded read-only operator view without external assets" do
    for {path, marker} <- [
          {"/memory", "Operational memory"},
          {"/configuration", "Effective host configuration"},
          {"/workspaces", "Workspaces"},
          {"/decisions", "Decisions"},
          {"/findings", "Findings"},
          {"/audit", "Audit"}
        ] do
      conn = request(:get, path)
      assert conn.status == 200
      assert conn.resp_body =~ marker
      refute conn.resp_body =~ "<script"
    end

    usage = request(:get, "/usage?window=24h")
    assert usage.status == 200
    assert usage.resp_body =~ "Usage and timing"
    assert usage.resp_body =~ "Provider measured"
    assert usage.resp_body =~ "claude:opus/high@work"

    memory = request(:get, "/memory")
    assert memory.resp_body =~ "Disable…"
    assert memory.resp_body =~ "Resume…"
    assert memory.resp_body =~ "Delete…"
    assert memory.resp_body =~ "—"
  end

  test "behavior and schedule changes require their own current typed confirmation" do
    for {kind, ref, action, expected} <- [
          {"behavior", "behavior:one", "disabled", {:behavior_status, :disabled}},
          {"behavior", "behavior:one", "deleted", {:behavior_status, :deleted}},
          {"schedule", "schedule:one", "active", {:schedule_status, :active}},
          {"schedule", "schedule:one", "deleted", {:schedule_status, :deleted}}
        ] do
      path = "/actions/#{kind}/#{URI.encode(ref, &URI.char_unreserved?/1)}/#{action}"
      confirmation = request(:get, path)
      assert confirmation.status == 200
      [_, token] = Regex.run(~r/name="_token" value="([^"]+)"/, confirmation.resp_body)

      accepted = request(:post, path, URI.encode_query(%{"_token" => token}))
      assert accepted.status == 303
      assert get_resp_header(accepted, "location") == ["/memory"]
      assert_received {^expected, ^ref}
    end

    assert request(:get, "/actions/behavior/missing/active").status == 404
    assert request(:get, "/actions/schedule/missing/paused").status == 404
    assert request(:get, "/actions/unknown/ref/delete").status == 404
  end

  test "malformed, stale, and unsupported mutations fail closed" do
    confirmation = request(:get, "/actions/memory/memory%3Aone/forget")
    [_, token] = Regex.run(~r/name="_token" value="([^"]+)"/, confirmation.resp_body)

    missing_content_type =
      conn(:post, "/actions/memory/memory%3Aone/forget", URI.encode_query(%{"_token" => token}))
      |> Map.put(:host, "localhost")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> then(&Router.call(&1, Router.init(options())))

    assert missing_content_type.status == 400

    extra_form =
      request(
        :post,
        "/actions/memory/memory%3Aone/forget",
        URI.encode_query(%{"_token" => token, "extra" => "no"})
      )

    assert extra_form.status == 400

    too_large = String.duplicate("x", 4_097)
    assert request(:post, "/actions/memory/memory%3Aone/forget", too_large).status == 400

    unavailable =
      options()
      |> put_in([:actions, :forget_memory], fn _ref -> {:error, :stale} end)
      |> then(fn opts ->
        request_with_options(
          :post,
          "/actions/memory/memory%3Aone/forget",
          URI.encode_query(%{"_token" => token}),
          opts
        )
      end)

    assert unavailable.status == 409
    assert request(:put, "/").status == 405
    assert request(:get, "/", "::1", {0, 0, 0, 0, 0, 0, 0, 1}).status == 200
  end

  test "episode details distinguish missing and unavailable projections" do
    assert request(:get, "/episodes/missing").status == 404

    unavailable =
      options()
      |> put_in([:projection, :episode], fn _ref -> {:error, :database_unavailable} end)
      |> then(&request_with_options(:get, "/episodes/episode%3Aone", nil, &1))

    assert unavailable.status == 503

    invalid_ref = "/episodes/" <> String.duplicate("a", 3_073)
    assert request(:get, invalid_ref).status == 404
  end

  test "usage rendering distinguishes missing prices measurements and destination ownership" do
    snapshot = %{
      channels: [
        %{
          attempts: 2,
          conversation_ref: "channel/with spaces",
          cost_usd: Decimal.new("0.25"),
          costed: 1,
          measured: 1,
          tokens: 1_000,
          transport: "github"
        }
      ],
      days: [%{attempts: 2, date: ~D[2026-08-29], measured: 1, tokens: 1_000}],
      repositories: [
        %{
          attempts: 1,
          cost_usd: Decimal.new("0"),
          costed: 0,
          measured: 0,
          repository_ref: nil,
          tokens: 0
        },
        %{
          attempts: 1,
          cost_usd: Decimal.new("0.25"),
          costed: 1,
          measured: 1,
          repository_ref: "responder",
          tokens: 1_000
        }
      ],
      targets: [
        %{
          attempts: 1,
          cost_usd: Decimal.new("0.25"),
          costed: 1,
          effort: "high",
          measured: 1,
          model: "opus",
          provider: "claude",
          target: "claude:opus/high@work",
          tokens: 1_000
        },
        %{
          attempts: 1,
          cost_usd: Decimal.new("0"),
          costed: 0,
          effort: nil,
          measured: 0,
          model: nil,
          provider: nil,
          target: nil,
          tokens: 0
        }
      ],
      totals: %{
        attempts: 2,
        average_host_ms: nil,
        average_provider_ms: 5_000,
        average_queued_ms: 1_000,
        cache_hit_rate: nil,
        cached_input_tokens: 0,
        cost_usd: Decimal.new("0.25"),
        costed: 1,
        input_tokens: 800,
        measurement_errors: 1,
        output_tokens: 200,
        reasoning_tokens: 0,
        timed: 1,
        usage_measured: 1
      },
      window: "24h"
    }

    html = snapshot |> HTML.usage() |> IO.iodata_to_binary()
    assert html =~ "github:channel/with spaces"
    assert html =~ "claude:opus/high@work"
    assert html =~ "no repository"
    assert html =~ "unreported"
    assert html =~ "unmeasured"
    assert html =~ "$0.25"
    assert html =~ "Daily measured token trend"

    assert HTML.failures([]) =~ "No durable failures"
    assert HTML.workspaces([]) |> IO.iodata_to_binary() =~ "No durable workspaces"

    assert HTML.overview(%{counts: %{}, needs_attention: []}) |> IO.iodata_to_binary() =~
             "Nothing needs attention"

    assert HTML.generic("Unknown", [nil]) |> IO.iodata_to_binary() =~ "Unknown"
  end

  defp request(method, path, body \\ nil) do
    request(method, path, body, "localhost", {127, 0, 0, 1})
  end

  defp request(method, path, host, remote_ip) when is_binary(host) and is_tuple(remote_ip) do
    request(method, path, nil, host, remote_ip)
  end

  defp request(method, path, body, host, remote_ip) do
    request_with_options(method, path, body, options(), host, remote_ip)
  end

  defp request_with_options(
         method,
         path,
         body,
         options,
         host \\ "localhost",
         remote_ip \\ {127, 0, 0, 1}
       ) do
    conn =
      method
      |> conn(path, body || "")
      |> Map.put(:host, host)
      |> Map.put(:remote_ip, remote_ip)

    conn =
      if method == :post,
        do: put_req_header(conn, "content-type", "application/x-www-form-urlencoded"),
        else: conn

    Router.call(conn, Router.init(options))
  end

  defp options do
    parent = self()

    %{
      actions: %{
        discard_retention: fn ref ->
          send(parent, {:discarded_retention, ref})
          {:ok, %{ref: ref}}
        end,
        forget_memory: fn ref ->
          send(parent, {:forgot_memory, ref})
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
        rearm_slack_incident: fn ref ->
          send(parent, {:rearmed_slack_incident, ref})
          {:ok, %{ref: ref}}
        end,
        retry_work: fn ref ->
          send(parent, {:retried_work, ref})
          {:ok, %{key: ref}}
        end,
        send_lab_message: fn conversation_id, message ->
          if byte_size(message) <= 20_000 do
            send(parent, {:lab_message, conversation_id, message})
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
        end
      },
      csrf_secret: @secret,
      observability: %{
        health: fn -> {:ok, %{database: :ok}} end,
        metrics: fn ->
          {:ok,
           "responder_queue_claimable{queue=\"ingress\"} 0\nresponder_queue_oldest_age_seconds{queue=\"ingress\"} 0\n"}
        end,
        ready: fn -> {:ok, %{stalled_queues: []}} end
      },
      projection: %{
        admission: fn
          "ingress-input:one" ->
            {:ok,
             %{
               action: :rearm,
               attempt_count: 3,
               destination: "github:github-main:repository:99 / github:github-main:pull:42",
               episode_ref: nil,
               kind: "admission",
               ref: "ingress-input:one",
               source: "github:github-main · github-delivery-one",
               status: :blocked,
               summary: "operation_uncertain",
               updated_at: ~U[2026-08-28 11:59:00Z]
             }}

          _ref ->
            :not_found
        end,
        audit: fn _params -> [] end,
        configuration: fn -> [%{key: "runtime", value: "configured"}] end,
        decisions: fn _params -> [] end,
        delivery: fn
          "delivery:one" ->
            {:ok,
             %{
               kind: :message,
               ref: "delivery:one",
               status: :blocked,
               summary: "provider_unavailable",
               updated_at: ~U[2026-08-28 12:00:00Z]
             }}

          _ref ->
            :not_found
        end,
        emisar: fn
          "approval:one" ->
            {:ok, %{action: :rearm, kind: "emisar", status: :blocked}}

          _ref ->
            :not_found
        end,
        episode: fn
          "episode:one" ->
            {:ok,
             %{
               episode: %{
                 destination: "slack:T123:C456",
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
               secret: "raw-secret-value"
             }}

          _ref ->
            :not_found
        end,
        episodes: fn params ->
          send(parent, {:episode_filters, params})

          %{
            items: [
              %{
                destination: "slack:T123:C456",
                next_action: "continue_work",
                ref: "episode:one",
                state: :working,
                updated_at: ~U[2026-08-28 12:00:00Z]
              }
            ],
            page: 2,
            pages: 2
          }
        end,
        failures: fn _params ->
          [
            %{
              action: :rearm,
              attempt_count: 3,
              destination: "slack:T123:C456 / 1787832000.001",
              episode_ref: "episode:one",
              kind: "delivery",
              ref: "delivery:one",
              source: nil,
              status: :blocked,
              summary: "provider_unavailable",
              updated_at: ~U[2026-08-28 12:00:00Z]
            },
            %{
              action: :rearm,
              attempt_count: 3,
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
              action: :retry,
              kind: "work",
              ref: "episode:blocked",
              status: :blocked,
              summary: "work_execution_blocked",
              updated_at: ~U[2026-08-28 11:58:00Z]
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
            }
          ]
        end,
        findings: fn _params -> [] end,
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
                   actor: :operator,
                   artifact_refs: [],
                   occurred_at: ~U[2026-08-28 11:59:00Z],
                   record_refs: [],
                   ref: "lab:event:one",
                   state: nil,
                   status: :decided,
                   text: "Explain <unsafe> state"
                 },
                 %{
                   actor: :responder,
                   artifact_refs: [],
                   occurred_at: ~U[2026-08-28 12:00:00Z],
                   record_refs: ["evidence:one"],
                   ref: "delivery:lab",
                   state: "complete",
                   status: :delivery_pending,
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
              updated_at: ~U[2026-08-28 12:00:00Z]
            }
          ]
        end,
        memory: fn ->
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
                status: :active,
                subject: "checkout-api"
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
        slack_interaction: fn
          "interaction:one" ->
            {:ok, %{action: :rearm, kind: "slack_interaction", status: :blocked}}

          _ref ->
            :not_found
        end,
        slack_incident: fn
          "incident-room:one" ->
            {:ok, %{action: :rearm, kind: "slack_incident", status: :blocked}}

          _ref ->
            :not_found
        end,
        work: fn
          "episode:blocked" ->
            {:ok, %{action: :retry, kind: "work", status: :blocked}}

          _ref ->
            :not_found
        end,
        workspace: fn
          "workspace:blocked" ->
            {:ok,
             %{
               action: :rearm,
               kind: "coop_session",
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
               kind: "coop_session",
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
               kind: "coop_session",
               ref: "workspace:dirty",
               state: :complete,
               status: :retained,
               summary: "dirty",
               updated_at: ~U[2026-08-28 12:00:00Z]
             }}

          _ref ->
            :not_found
        end,
        workspaces: fn _params ->
          [
            %{
              action: :rearm,
              kind: "coop_session",
              ref: "workspace:blocked",
              state: :complete,
              status: :blocked,
              summary: "coop_protocol_error",
              updated_at: ~U[2026-08-28 12:00:00Z]
            },
            %{
              action: :discard_unmerged,
              kind: "coop_session",
              ref: "workspace:unmerged",
              state: :complete,
              status: :retained,
              summary: "unpublished_unmerged",
              updated_at: ~U[2026-08-28 12:00:00Z]
            },
            %{
              action: nil,
              kind: "coop_session",
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
end
