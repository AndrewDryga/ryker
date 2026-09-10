defmodule Responder.ControlPlane.RouterTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test
  import Phoenix.LiveViewTest

  alias Responder.ControlPlane.{CSRF, EpisodePage, HTML, Router}

  @secret String.duplicate("s", 32)

  test "removed admission pages are not redirects or compatibility aliases" do
    id = Ecto.UUID.generate()
    options = options()

    options = %{
      options
      | projection:
          Map.put(options.projection, :admission_request, fn ^id, _ ->
            {:ok, %{episode_ref: "existing:conversation"}}
          end)
    }

    response = request_with_options(:get, "/admission/#{id}", nil, options)
    assert response.status == 404
    assert get_resp_header(response, "location") == []
    response = request_with_options(:get, "/admission/#{id}?generation=2", nil, options)
    assert response.status == 404
    assert get_resp_header(response, "location") == []
  end

  test "operator actions are buttons while inspection remains navigation" do
    # Text links made recovery actions look like more inspection pages.
    for path <- [
          "/failures",
          "/failures/delivery/delivery%3Aone",
          "/workspaces",
          "/memory",
          "/schedules/schedule%3Aone"
        ] do
      conn = request(:get, path)
      assert conn.status == 200
      document = LazyHTML.from_document(conn.resp_body)
      assert LazyHTML.query(document, "a[href^='/actions/']") |> LazyHTML.to_tree() == []

      buttons =
        LazyHTML.query(document, "form[method='get'][action^='/actions/'] button[type='submit']")

      assert LazyHTML.to_tree(buttons) != [], "#{path} must expose native action buttons"
      refute LazyHTML.text(buttons) =~ "…"
    end

    failures = request(:get, "/failures").resp_body |> LazyHTML.from_document()
    assert LazyHTML.query(failures, "a[href^='/failures/']") |> LazyHTML.text() =~ "Inspect cause"
  end

  test "retry confirmation names the frozen specimen rather than the currently browsed state" do
    id = Ecto.UUID.generate()
    options = options()

    options = %{
      options
      | projection:
          Map.put(options.projection, :card_lab_post, fn ^id ->
            {:ok,
             %{
               id: id,
               card_id: "incident-room",
               state_id: "provisioning",
               revision: 1,
               workspace_ref: "T123",
               channel_ref: "C123"
             }}
          end),
        actions:
          Map.put(options.actions, :describe_card_slack_target, fn "T123", "C123" ->
            {:ok, %{workspace_ref: "T123", channel_ref: "C123", channel_name: "test"}}
          end)
    }

    page =
      request_with_options(
        :get,
        "/card-lab/incident-room/resolved/slack/#{id}/retry",
        nil,
        options
      )

    assert page.status == 200
    assert page.resp_body =~ "Provisioning"
    refute page.resp_body =~ "· Resolved"
  end

  test "Card Lab requires destination review and a bound confirmation before posting to Slack" do
    parent = self()
    options = options()

    options = %{
      options
      | actions:
          Map.merge(options.actions, %{
            describe_card_slack_target: fn "T123", "C123" ->
              {:ok,
               %{workspace_ref: "T123", channel_ref: "C123", channel_name: "responder-testing"}}
            end,
            post_card_to_slack: fn card, state, workspace, channel, id ->
              send(parent, {:native_card_post, card, state, workspace, channel, id})
              {:ok, %{id: id}}
            end
          }),
        projection:
          Map.put(options.projection, :card_lab_slack, fn _card ->
            %{available: true, workspace_ref: "T123", channels: ["C123"], posts: []}
          end)
    }

    path = "/card-lab/incident-room/provisioning"
    page = request_with_options(:get, path, nil, options)
    assert page.status == 200
    assert page.resp_body =~ "Post to Slack"
    assert page.resp_body =~ "Browser approximation"
    refute_received {:native_card_post, _, _, _, _, _}

    token = CSRF.token(@secret, "card_lab:prepare_slack", "incident-room:provisioning")

    review =
      request_with_options(
        :post,
        path <> "/slack/preview",
        URI.encode_query(%{
          "_token" => token,
          "workspace_ref" => "T123",
          "channel_ref" => "C123"
        }),
        options
      )

    assert review.status == 200
    assert review.resp_body =~ "responder-testing"
    assert review.resp_body =~ "Post test message"
    refute_received {:native_card_post, _, _, _, _, _}

    fields =
      Regex.scan(~r/<input type="hidden" name="([^"]+)" value="([^"]*)"/, review.resp_body)
      |> Map.new(fn [_, key, value] -> {key, value} end)

    denied =
      request_with_options(
        :post,
        path <> "/slack/post",
        URI.encode_query(Map.put(fields, "channel_ref", "C999")),
        options
      )

    assert denied.status == 403
    refute_received {:native_card_post, _, _, _, _, _}

    posted = request_with_options(:post, path <> "/slack/post", URI.encode_query(fields), options)
    assert posted.status == 303
    assert_received {:native_card_post, "incident-room", "provisioning", "T123", "C123", _id}
  end

  test "the Slack Card Lab previews and transitions exact specimens with durable feedback" do
    index = request(:get, "/card-lab")

    assert index.status == 200
    assert index.resp_body =~ "Slack Card Lab"
    assert index.resp_body =~ "Every production Slack surface"
    assert index.resp_body =~ "Task card"
    assert index.resp_body =~ "Production renderer"
    assert index.resp_body =~ "Raw Block Kit JSON"

    state = request(:get, "/card-lab/task-card/working")
    assert state.status == 200
    assert state.resp_body =~ "Bump the pinned admin runner release to 0.20.0"
    assert state.resp_body =~ "Stop current run"
    assert state.resp_body =~ "Transition without Slack"

    transition_resource = "task-card:working:wait-input"
    transition_token = CSRF.token(@secret, "card_lab:transition", transition_resource)

    transitioned =
      request(
        :post,
        "/card-lab/task-card/working/transitions/wait-input",
        URI.encode_query(%{"_token" => transition_token})
      )

    assert transitioned.status == 303

    assert get_resp_header(transitioned, "location") == [
             "/card-lab/task-card/waiting-for-input"
           ]

    rejected =
      request(
        :post,
        "/card-lab/task-card/working/transitions/wait-input",
        URI.encode_query(%{"_token" => "wrong"})
      )

    assert rejected.status == 403

    feedback_resource = "task-card:working"
    feedback_token = CSRF.token(@secret, "card_lab:feedback", feedback_resource)

    feedback =
      request(
        :post,
        "/card-lab/task-card/working/feedback",
        URI.encode_query(%{
          "_token" => feedback_token,
          "note" => "Make the progress line more prominent.",
          "verdict" => "needs_work"
        })
      )

    assert feedback.status == 303
    assert get_resp_header(feedback, "location") == ["/card-lab/task-card/working#feedback"]

    assert_received {:card_lab_feedback, "task-card", "working", "needs_work",
                     "Make the progress line more prominent."}

    assert request(:get, "/card-lab/missing/state").status == 404
  end

  test "renders an offline overview with hard browser boundaries" do
    conn = request(:get, "/")

    assert conn.status == 200

    assert get_resp_header(conn, "content-security-policy") == [
             "default-src 'none'; style-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
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
    assert index.resp_body =~ "Conversation inputs"
    assert index.resp_body =~ "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"

    fresh = request(:get, "/lab/new")
    assert fresh.status == 303
    [location] = get_resp_header(fresh, "location")
    assert "/lab/" <> generated_id = location
    assert {:ok, _uuid} = Ecto.UUID.cast(generated_id)

    conversation = request(:get, "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6")
    assert conversation.status == 200
    assert conversation.resp_body =~ "Local model conversation"
    assert conversation.resp_body =~ "Same conversational product as Slack"
    assert conversation.resp_body =~ "state and Emisar tools"
    assert conversation.resp_body =~ "tasks, local incidents, publication cards"
    assert conversation.resp_body =~ "message integration"
    assert conversation.resp_body =~ "<strong>Integration</strong>"
    assert conversation.resp_body =~ "Webhook universal · manual.unknown · revision 1"
    assert conversation.resp_body =~ "Explain &lt;unsafe&gt; state"
    assert conversation.resp_body =~ "The durable answer is ready."
    assert conversation.resp_body =~ ":eyes:"
    assert conversation.resp_body =~ "status.yaml"
    assert conversation.resp_body =~ "application/yaml"
    assert conversation.resp_body =~ "generated-chart.png"
    assert conversation.resp_body =~ "<img"
    assert conversation.resp_body =~ "Engineering task"
    assert conversation.resp_body =~ "Repair &lt;unsafe&gt; Lab flow"
    assert conversation.resp_body =~ "Repository"

    assert conversation.resp_body =~
             "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Alab/confirm-task"

    assert conversation.resp_body =~ ">Start task<"

    assert conversation.resp_body =~
             "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Aincident/open-incident"

    assert conversation.resp_body =~ ">Open local incident<"

    assert conversation.resp_body =~
             "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Aconfirmed/diff"

    assert conversation.resp_body =~ ">View diff<"
    assert conversation.resp_body =~ ">Timeline<"
    assert conversation.resp_body =~ ">Evidence<"
    assert conversation.resp_body =~ ">Handoff<"
    assert conversation.resp_body =~ "data-live=\"true\""
    assert conversation.resp_body =~ "data-lab-status"
    assert conversation.resp_body =~ "data-max-bytes=\"20000\""
    assert conversation.resp_body =~ "enctype=\"multipart/form-data\""
    assert conversation.resp_body =~ "name=\"attachments[]\""
    assert conversation.resp_body =~ ">Edit<"
    assert conversation.resp_body =~ ">Delete<"
    assert conversation.resp_body =~ "React to this reply"

    assert conversation.resp_body =~
             "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/messages/018f3ef7-1f62-7ee0-a83c-0c12f21d83e7/edit"

    assert conversation.resp_body =~
             "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/messages/018f3ef7-1f62-7ee0-a83c-0c12f21d83e7/delete"

    assert conversation.resp_body =~ "src=\"/static/lab.js\""
    assert length(Regex.scan(~r/>Staging</, conversation.resp_body)) == 1
    assert length(Regex.scan(~r/>Production</, conversation.resp_body)) == 1
    refute conversation.resp_body =~ "<unsafe>"
    refute conversation.resp_body =~ "Repair <unsafe> Lab flow"

    artifact_path =
      "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/turns/018f3ef7-1f62-7ee0-a83c-0c12f21d83e9/artifacts/artifact_chart"

    artifact = request(:get, artifact_path)
    assert artifact.status == 200
    assert artifact.resp_body == <<137, 80, 78, 71, 13, 10, 26, 10, "chart">>
    assert get_resp_header(artifact, "content-type") == ["image/png"]

    assert get_resp_header(artifact, "content-disposition") == [
             "inline; filename*=UTF-8''generated-chart.png"
           ]

    assert request(:get, String.replace(artifact_path, "artifact_chart", "missing")).status == 404

    [_, token] =
      Regex.run(
        ~r/action="\/lab\/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6\/messages".*?name="_token" value="([^"]+)"/,
        conversation.resp_body
      )

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

    receipt =
      conn(
        :post,
        "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/messages",
        URI.encode_query(%{"_token" => token, "message" => "Live draft receipt"})
      )
      |> Map.put(:host, "localhost")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_req_header("accept", "application/json")
      |> Router.call(Router.init(options()))

    assert receipt.status == 202
    assert Jason.decode!(receipt.resp_body) == %{"accepted" => true}
    assert_received {:lab_message, "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6", "Live draft receipt"}

    attachment = "service: emisar\nstatus: healthy\n"

    uploaded =
      multipart_request(
        "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/messages",
        token,
        "Read the attached status.",
        "status.yaml",
        "application/yaml",
        attachment
      )

    assert uploaded.status == 303

    assert_received {:lab_message, "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
                     "Read the attached status.",
                     [
                       %{
                         data: ^attachment,
                         media_type: "application/yaml",
                         name: "status.yaml"
                       }
                     ]}

    edit_resource =
      "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6:018f3ef7-1f62-7ee0-a83c-0c12f21d83e7:edit"

    edit_token = CSRF.token(@secret, "conversation_lab:message", edit_resource)

    rejected_edit =
      request(
        :post,
        "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/messages/018f3ef7-1f62-7ee0-a83c-0c12f21d83e7/edit",
        URI.encode_query(%{"_token" => "wrong", "message" => "Corrected request"})
      )

    assert rejected_edit.status == 403
    refute_received {:lab_message_edit, _conversation, _item, _message}

    accepted_edit =
      request(
        :post,
        "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/messages/018f3ef7-1f62-7ee0-a83c-0c12f21d83e7/edit",
        URI.encode_query(%{"_token" => edit_token, "message" => "Corrected request"})
      )

    assert accepted_edit.status == 303

    assert_received {:lab_message_edit, "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
                     "018f3ef7-1f62-7ee0-a83c-0c12f21d83e7", "Corrected request"}

    delete_resource =
      "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6:018f3ef7-1f62-7ee0-a83c-0c12f21d83e7:delete"

    delete_token = CSRF.token(@secret, "conversation_lab:message", delete_resource)

    accepted_delete =
      request(
        :post,
        "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/messages/018f3ef7-1f62-7ee0-a83c-0c12f21d83e7/delete",
        URI.encode_query(%{"_token" => delete_token})
      )

    assert accepted_delete.status == 303

    assert_received {:lab_message_delete, "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
                     "018f3ef7-1f62-7ee0-a83c-0c12f21d83e7"}

    reaction_message_ref = "control-plane-message:lab-reply"

    reaction_resource =
      "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6:#{reaction_message_ref}"

    reaction_token = CSRF.token(@secret, "conversation_lab:reaction", reaction_resource)

    rejected_reaction =
      request(
        :post,
        "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/replies/control-plane-message%3Alab-reply/reactions",
        URI.encode_query(%{"_token" => "wrong", "action" => "add", "emoji" => "heart"})
      )

    assert rejected_reaction.status == 403
    refute_received {:lab_reaction, _conversation, _message, _action, _emoji}

    accepted_reaction =
      request(
        :post,
        "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/replies/control-plane-message%3Alab-reply/reactions",
        URI.encode_query(%{
          "_token" => reaction_token,
          "action" => "add",
          "emoji" => "heart"
        })
      )

    assert accepted_reaction.status == 303

    assert_received {:lab_reaction, "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
                     "control-plane-message:lab-reply", :add, "heart"}

    [_, task_token] =
      Regex.run(
        ~r/action="\/lab\/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6\/records\/record%3Atask_offer%3Alab\/confirm-task".*?name="_token" value="([^"]+)"/,
        conversation.resp_body
      )

    expected_task_token =
      CSRF.token(
        @secret,
        "conversation_lab:record",
        "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6:record:task_offer:lab:confirm_task:none"
      )

    assert task_token == expected_task_token

    refused_task =
      request(
        :post,
        "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Alab/confirm-task",
        URI.encode_query(%{"_token" => "wrong"})
      )

    assert refused_task.status == 403
    refute_received {:lab_record_action, _conversation, _record, _action, _choice}

    accepted_task =
      request(
        :post,
        "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Alab/confirm-task",
        URI.encode_query(%{"_token" => task_token})
      )

    assert accepted_task.status == 303

    assert get_resp_header(accepted_task, "location") == [
             "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"
           ]

    assert_received {:lab_record_action, "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
                     "record:task_offer:lab", :confirm_task, nil}

    [_, choice_token] =
      Regex.run(
        ~r/action="\/lab\/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6\/records\/record%3Ainput_request%3Alab\/answer"><input type="hidden" name="_token" value="([^"]+)"><input type="hidden" name="choice_index" value="1">/,
        conversation.resp_body
      )

    crossed_choice =
      request(
        :post,
        "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Ainput_request%3Alab/answer",
        URI.encode_query(%{"_token" => choice_token, "choice_index" => "0"})
      )

    assert crossed_choice.status == 403

    accepted_choice =
      request(
        :post,
        "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Ainput_request%3Alab/answer",
        URI.encode_query(%{"_token" => choice_token, "choice_index" => "1"})
      )

    assert accepted_choice.status == 303

    assert_received {:lab_record_action, "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
                     "record:input_request:lab", :answer_input, 1}

    [_, stop_token] =
      Regex.run(
        ~r/action="\/lab\/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6\/records\/record%3Atask_offer%3Aconfirmed\/stop-task".*?name="_token" value="([^"]+)"/,
        conversation.resp_body
      )

    stopped =
      request(
        :post,
        "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Aconfirmed/stop-task",
        URI.encode_query(%{"_token" => stop_token})
      )

    assert stopped.status == 303

    assert_received {:lab_record_action, "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
                     "record:task_offer:confirmed", :stop_task, nil}

    task_view =
      request(
        :get,
        "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Aconfirmed/timeline"
      )

    assert task_view.status == 200
    assert task_view.resp_body =~ "Durable timeline"
    assert task_view.resp_body =~ "Input admitted"

    assert_received {:lab_task_view, "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
                     "record:task_offer:confirmed", :timeline, %{}}

    for {view_name, view} <- [
          {"evidence", :evidence},
          {"handoff", :handoff},
          {"postmortem", :postmortem}
        ] do
      rendered =
        request(
          :get,
          "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Aconfirmed/#{view_name}"
        )

      assert rendered.status == 200

      assert_received {:lab_task_view, "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
                       "record:task_offer:confirmed", ^view, %{}}
    end

    assert request(
             :get,
             "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Aconfirmed/unknown"
           ).status == 404

    assert request(
             :get,
             "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Aconfirmed/timeline?unexpected=true"
           ).status == 400

    assert request(
             :get,
             "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Aconfirmed/diff?offset=2400"
           ).status == 400

    refute_received {:lab_task_view, _conversation, _record, :diff, _params}

    digest = String.duplicate("a", 64)

    diff_view =
      request(
        :get,
        "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Aconfirmed/diff"
      )

    assert diff_view.status == 200
    assert diff_view.resp_body =~ "Workspace diff"
    assert diff_view.resp_body =~ "Patch page"

    assert diff_view.resp_body =~
             "diff?offset=2400&amp;snapshot=#{digest}"

    assert_received {:lab_task_view, "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
                     "record:task_offer:confirmed", :diff, %{offset: 0, snapshot_digest: nil}}

    next_diff =
      request(
        :get,
        "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Aconfirmed/diff?offset=2400&snapshot=#{digest}"
      )

    assert next_diff.status == 200

    assert_received {:lab_task_view, "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
                     "record:task_offer:confirmed", :diff,
                     %{offset: 2400, snapshot_digest: ^digest}}

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
    assert javascript.resp_body =~ "nearConversationEnd"
    assert javascript.resp_body =~ "scrollIntoView"
    assert javascript.resp_body =~ "requestAnimationFrame"
    refute javascript.resp_body =~ "http://"
    refute javascript.resp_body =~ "https://"
  end

  test "a blocked Lab conversation stops polling and links its recovery action" do
    body =
      HTML.lab_conversation(
        %{
          blocked: true,
          conversation_id: "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
          episodes: [
            %{
              next_action: "operator_recovery",
              ref: "episode:blocked",
              state: :working,
              work_status: :blocked
            }
          ],
          live: false,
          messages: [],
          pending: 0
        },
        "csrf-token"
      )
      |> IO.iodata_to_binary()

    assert body =~ "Needs attention"
    assert body =~ ~s(data-live="false")
    assert body =~ "/failures/work/episode%3Ablocked"
    assert body =~ "Review failure"
    refute body =~ "Working ·"
  end

  test "new and malformed Lab routes fail closed without creating hidden authority" do
    empty_id = "018f3ef7-1f62-7ee0-a83c-0c12f21d83ff"
    empty = request(:get, "/lab/#{empty_id}")
    assert empty.status == 200
    assert empty.resp_body =~ empty_id
    assert empty.resp_body =~ "Send the first message to begin this durable conversation."

    assert request(:get, "/lab/not-a-uuid").status == 404

    invalid_path =
      request(
        :post,
        "/lab/not-a-uuid/messages",
        URI.encode_query(%{"_token" => "none", "message" => "Do not persist me"})
      )

    assert invalid_path.status == 404

    unsupported =
      :post
      |> conn("/lab/#{empty_id}/messages", ~s({"message":"no"}))
      |> put_req_header("content-type", "application/json")
      |> Map.put(:host, "localhost")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> Router.call(Router.init(options()))

    assert unsupported.status == 400

    unavailable_projection =
      options()
      |> put_in([:projection, :lab_conversation], fn _id ->
        {:error, :database_unavailable}
      end)
      |> then(&request_with_options(:get, "/lab/#{empty_id}", nil, &1))

    assert unavailable_projection.status == 503

    message_token = CSRF.token(@secret, "conversation_lab:send", empty_id)

    unavailable_message =
      options()
      |> put_in([:actions, :send_lab_message], fn _id, _message, _attachments ->
        {:error, :admission_unavailable}
      end)
      |> then(fn opts ->
        request_with_options(
          :post,
          "/lab/#{empty_id}/messages",
          URI.encode_query(%{"_token" => message_token, "message" => "Keep me durable"}),
          opts
        )
      end)

    assert unavailable_message.status == 409

    record_ref = "record:memory_offer:unavailable"
    resource = "#{empty_id}:#{record_ref}:confirm_memory:none"
    record_token = CSRF.token(@secret, "conversation_lab:record", resource)

    unavailable_record =
      options()
      |> put_in([:actions, :act_on_lab_record], fn _id, _ref, _action, _choice ->
        {:error, :record_stale}
      end)
      |> then(fn opts ->
        request_with_options(
          :post,
          "/lab/#{empty_id}/records/#{record_ref}/confirm-memory",
          URI.encode_query(%{"_token" => record_token}),
          opts
        )
      end)

    assert unavailable_record.status == 409
  end

  test "every native Lab card action round-trips one exact CSRF-bound control" do
    conversation_id = "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"

    actions = [
      {"record:task_offer:incident", "open-incident", :open_incident},
      {"record:memory_offer:lab", "confirm-memory", :confirm_memory},
      {"record:guidance_offer:lab", "confirm-behavior", :confirm_behavior},
      {"record:schedule_offer:lab", "confirm-schedule", :confirm_schedule},
      {"record:automation_change_offer:lab", "confirm-automation", :confirm_automation},
      {"record:slack_post_offer:lab", "confirm-post", :confirm_post},
      {"record:publication_offer:lab", "review-publication", :review_publication},
      {"record:publication_review:lab", "publish-draft", :approve_publication},
      {"record:publication_result:lab", "check-publication", :check_publication},
      {"record:task_offer:confirmed", "close-task", :close_task}
    ]

    conversation = request(:get, "/lab/#{conversation_id}")

    for {record_ref, action_name, action} <- actions do
      encoded_ref = URI.encode(record_ref, &URI.char_unreserved?/1)
      path = "/lab/#{conversation_id}/records/#{encoded_ref}/#{action_name}"
      assert conversation.resp_body =~ path

      resource = "#{conversation_id}:#{record_ref}:#{action}:none"
      token = CSRF.token(@secret, "conversation_lab:record", resource)
      accepted = request(:post, path, URI.encode_query(%{"_token" => token}))

      assert accepted.status == 303
      assert_received {:lab_record_action, ^conversation_id, ^record_ref, ^action, nil}
    end

    for {action_name, action, field, value} <- [
          {"task-readiness", :request_task_readiness, "review_offer_ref",
           "record:publication_offer:ready"},
          {"task-publish", :approve_task_publication, "publication_ref",
           "publication:confirmed-task"},
          {"task-check", :check_task_publication, "publication_ref", "publication:confirmed-task"}
        ] do
      record_ref = "record:task_offer:confirmed"
      encoded_ref = URI.encode(record_ref, &URI.char_unreserved?/1)
      path = "/lab/#{conversation_id}/records/#{encoded_ref}/#{action_name}"
      assert conversation.resp_body =~ path

      resource = "#{conversation_id}:#{record_ref}:#{action}:#{value}"
      token = CSRF.token(@secret, "conversation_lab:record", resource)
      accepted = request(:post, path, URI.encode_query(%{"_token" => token, field => value}))

      assert accepted.status == 303

      expected_context =
        case field do
          "publication_ref" -> %{publication_ref: value}
          "review_offer_ref" -> %{review_offer_ref: value}
        end

      assert_received {:lab_record_action, ^conversation_id, ^record_ref, ^action,
                       ^expected_context}
    end

    for {action_name, action} <- [
          {"task-retry", :retry_task_publication},
          {"task-update", :update_task_publication},
          {"task-discard", :discard_task_publication}
        ] do
      record_ref = "record:task_offer:confirmed"
      encoded_ref = URI.encode(record_ref, &URI.char_unreserved?/1)
      path = "/lab/#{conversation_id}/records/#{encoded_ref}/#{action_name}"
      assert conversation.resp_body =~ path

      publication_ref = "publication:confirmed-task"
      resource = "#{conversation_id}:#{record_ref}:#{action}:4:#{publication_ref}"
      token = CSRF.token(@secret, "conversation_lab:record", resource)

      accepted =
        request(
          :post,
          path,
          URI.encode_query(%{
            "_token" => token,
            "choice_index" => "4",
            "publication_ref" => publication_ref
          })
        )

      assert accepted.status == 303

      assert_received {:lab_record_action, ^conversation_id, ^record_ref, ^action,
                       %{generation: 4, publication_ref: ^publication_ref}}
    end

    invalid = request(:post, "/lab/#{conversation_id}/records/record:one/unknown", "")
    assert invalid.status == 404
  end

  test "the built-in journey guide reflects configured product owners" do
    guide = request(:get, "/manual-tests")
    assert guide.status == 200
    assert guide.resp_body =~ "Slack threads, cards, and emoji"
    assert guide.resp_body =~ "across completed episode boundaries"
    assert guide.resp_body =~ "generated image"
    assert guide.resp_body =~ "GitHub comments, reviews, and reactions"
    assert guide.resp_body =~ "Local operator workbench"
    assert guide.resp_body =~ "Universal signed webhook"
    assert guide.resp_body =~ "X-Responder-Signature"
    assert guide.resp_body =~ "X-Responder-Item-ID"
    assert guide.resp_body =~ "RESPONDER_WEBHOOK_SECRET"
    assert guide.resp_body =~ "Report the exact observed fields without inferring vendor meaning"
    assert guide.resp_body =~ "curl --fail-with-body"
    assert guide.resp_body =~ "Recovery and retention"
    refute guide.resp_body =~ "token="
  end

  test "the native episode renders recovery and confirmed action controls without exposing extra fields" do
    {:ok, detail} = options().projection.episode.("episode:one")

    trace =
      Map.merge(detail.trace, %{
        case_file: %{
          title: "Episode one",
          repository: nil,
          conversation: [],
          awaiting_reply: false
        },
        received_at: detail.episode.created_at,
        history: %{truncated: false},
        steps: Enum.map(hd(detail.trace.chapters).steps, &Map.put(&1, :band, :input))
      })

    html =
      render_component(&EpisodePage.render/1,
        snapshot: %{detail | trace: trace},
        requests: nil,
        params: %{}
      )

    assert html =~ "Execution timeline"
    assert html =~ "Input admitted"
    assert html =~ "Work needs operator recovery"
    assert html =~ "3 candidate attempts"
    assert html =~ "/failures/work/episode%3Aone"
    assert html =~ "Open source message"
    assert html =~ "https://slack.com/archives/C456/p1787832000001000"
    assert html =~ "/actions/episode/episode%3Aone/resolve"
    assert html =~ "/actions/episode/episode%3Aone/review"
    refute html =~ "raw-secret-value"
    document = LazyHTML.from_document(html)
    assert LazyHTML.query(document, "a[href^='/actions/']") |> LazyHTML.to_tree() == []

    assert LazyHTML.query(
             document,
             "form[method='get'][action^='/actions/'] button[type='submit']"
           )
           |> Enum.count() == 2
  end

  test "episode resolution and review use exact confirmed local actions" do
    for {action, title, received} <- [
          {"resolve", "Close this episode as no longer needed?",
           {:resolved_episode, "episode:one"}},
          {"review", "Mark this ending reviewed?", {:reviewed_episode, "episode:one"}}
        ] do
      path = "/actions/episode/episode%3Aone/#{action}"
      confirmation = request(:get, path)
      assert confirmation.status == 200
      assert confirmation.resp_body =~ title
      assert confirmation.resp_body =~ "href=\"/episodes/episode%3Aone\""
      [_, token] = Regex.run(~r/name="_token" value="([^"]+)"/, confirmation.resp_body)

      accepted = request(:post, path, URI.encode_query(%{"_token" => token}))
      assert accepted.status == 303
      assert get_resp_header(accepted, "location") == ["/episodes/episode%3Aone"]
      assert_received ^received
    end
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

  test "memory reviews support confirmed keep merge forget and an explicit edit form" do
    for action <- ["keep", "merge", "forget"] do
      path = "/actions/memory-review/memory-review%3Aone/#{action}"
      confirm = request(:get, path)
      assert confirm.status == 200
      [_, token] = Regex.run(~r/name="_token" value="([^"]+)"/, confirm.resp_body)
      accepted = request(:post, path, URI.encode_query(%{"_token" => token}))
      assert accepted.status == 303
      assert_received {:memory_review, "memory-review:one", resolved, nil}
      assert Atom.to_string(resolved) == action
    end

    edit_path = "/actions/memory-review/memory-review%3Atwo/edit"
    edit = request(:get, edit_path)
    assert edit.status == 200
    assert edit.resp_body =~ "Edit reviewed memory"
    [_, token] = Regex.run(~r/name="_token" value="([^"]+)"/, edit.resp_body)

    accepted =
      request(
        :post,
        edit_path,
        URI.encode_query(%{
          "_token" => token,
          "subject" => "primary_codebase",
          "value" => "responder-elixir"
        })
      )

    assert accepted.status == 303

    assert_received {:memory_review, "memory-review:two", :edit,
                     %{"subject" => "primary_codebase", "value" => "responder-elixir"}}
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
    assert admission.resp_body =~ "3 attempts"
    assert admission.resp_body =~ "stored diagnostic sha256:"
    refute admission.resp_body =~ "Frozen validation result was uncertain"

    delivery = request(:get, "/failures/delivery/delivery%3Aone")
    assert delivery.status == 200
    assert delivery.resp_body =~ "stored diagnostic sha256:"
    refute delivery.resp_body =~ "Slack returned HTTP 503"

    confirm = request(:get, "/actions/delivery/delivery%3Aone/rearm")
    assert confirm.status == 200
    assert confirm.resp_body =~ "Retry this delivery?"
    assert confirm.resp_body =~ "href=\"/failures\""
    document = LazyHTML.from_document(confirm.resp_body)
    assert LazyHTML.query(document, "h2") |> LazyHTML.to_tree() == []
    assert LazyHTML.query(document, "a.button") |> LazyHTML.to_tree() == []

    assert LazyHTML.query(document, "button.ui-button[type='submit']") |> LazyHTML.text() ==
             "Confirm"

    refute_received {:rearmed_delivery, "delivery:one"}
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

  test "failure collection errors remain unavailable instead of appearing empty" do
    unavailable =
      options()
      |> put_in([:projection, :failures], fn _params -> {:error, :database_unavailable} end)

    assert request_with_options(:get, "/failures", nil, unavailable).status == 503

    assert request_with_options(
             :get,
             "/failures/delivery/delivery%3Aone",
             nil,
             unavailable
           ).status == 503
  end

  test "a completed-result confirmation cannot authorize a different stopped turn" do
    # An old recovery tab must never turn a save-only action into fresh model work.
    path = "/actions/work/episode%3Ablocked/retry"
    initial = options()
    {:ok, row} = initial.projection.work.("episode:blocked")

    recovery = %{
      kind: :completion,
      fingerprint: String.duplicate("a", 64),
      retry_effect: "Save only"
    }

    initial =
      put_in(initial, [:projection, :work], fn _ ->
        {:ok, Map.put(row, :work_recovery, recovery)}
      end)

    confirmation = request_with_options(:get, path, nil, initial)
    assert confirmation.status == 200
    [_, token] = Regex.run(~r/name="_token" value="([^"]+)"/, confirmation.resp_body)
    changed = %{recovery | kind: :execution, fingerprint: String.duplicate("b", 64)}

    current =
      put_in(initial, [:projection, :work], fn _ ->
        {:ok, Map.put(row, :work_recovery, changed)}
      end)

    response = request_with_options(:post, path, URI.encode_query(%{"_token" => token}), current)
    assert response.status == 403
    refute_received {:retried_work, _}
  end

  test "each recoverable blocked custody has a typed confirmed action" do
    failures = request(:get, "/failures")

    for {kind, ref, action, title, received} <- [
          {"admission", "ingress-input:one", "rearm", "Retry routing this message?",
           {:rearmed_admission, "ingress-input:one"}},
          {"work", "episode:blocked", "retry", "Retry this blocked work?",
           {:retried_work, "episode:blocked"}},
          {"emisar", "approval:one", "rearm", "Resume approval checks?",
           {:rearmed_emisar, "approval:one"}},
          {"slack_interaction", "interaction:one", "rearm", "Refresh this Slack message?",
           {:rearmed_slack_interaction, "interaction:one"}},
          {"slack_incident", "incident-room:one", "rearm", "Resume incident room setup?",
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
    assert rearm.resp_body =~ "Resume workspace cleanup?"
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

    health_unavailable =
      options()
      |> put_in([:observability, :health], fn -> {:error, :database_unavailable} end)
      |> then(&request_with_options(:get, "/healthz", nil, &1))

    assert health_unavailable.status == 503
    assert health_unavailable.resp_body == "unavailable\n"

    metrics_unavailable =
      options()
      |> put_in([:observability, :metrics], fn -> {:error, :database_unavailable} end)
      |> then(&request_with_options(:get, "/metrics", nil, &1))

    assert metrics_unavailable.status == 503
    assert metrics_unavailable.resp_body == "metrics unavailable\n"

    assert request(:get, "/metrics", "evil.example", {127, 0, 0, 1}).status == 421
  end

  test "the removed audit page cannot be opened through HTTP or live snapshots" do
    assert request(:get, "/audit").status == 404
    assert Router.snapshot("/audit", "", options()).status == 404
  end

  test "incident rooms have one canonical route with their actual room-only scope" do
    conn = request(:get, "/incident-rooms")
    assert conn.status == 200
    assert conn.resp_body =~ "Incident rooms"

    assert conn.resp_body =~
             "Track Slack incident rooms from setup through closure, with channel status and linked investigation work."

    assert conn.resp_body =~ "href=\"/incident-rooms/incident%3Aone\""
    refute conn.resp_body =~ "Incident rooms and local incidents"
    assert request(:get, "/incident-rooms/incident%3Aone").status == 200
    assert Router.snapshot("/incident-rooms", "q=room&status=blocked", options()).status == 200

    for path <- ["/incidents", "/incidents/incident%3Aone"] do
      removed = request(:get, path)
      assert removed.status == 404
      assert get_resp_header(removed, "location") == []
      assert Router.snapshot(path, "", options()).status == 404
    end
  end

  test "renders every bounded read-only operator view without external assets" do
    channel = request(:get, "/channels/T123/C456")
    assert channel.resp_body =~ "<h1>Slack channel</h1>"
    refute channel.resp_body =~ "<h1>C456</h1>"

    for {path, marker} <- [
          {"/memory", "Operational memory"},
          {"/configuration", "Effective host configuration"},
          {"/incident-rooms", "Track Slack incident rooms"},
          {"/incident-rooms/incident%3Aone", "Room lifecycle"},
          {"/schedules", "Recurring and one-shot work"},
          {"/schedules/schedule%3Aone", "Execution history"},
          {"/subscriptions", "Wait subscriptions"},
          {"/channels", "Slack conversation roster"},
          {"/channels/T123/C456", "Conversation continuity"},
          {"/repositories", "Where Responder can work"},
          {"/workspaces", "Workspaces"},
          {"/findings", "Findings"}
        ] do
      conn = request(:get, path)
      assert conn.status == 200
      assert conn.resp_body =~ marker
      refute conn.resp_body =~ "<script"
    end

    usage = request(:get, "/usage?window=24h")
    assert usage.status == 200
    assert usage.resp_body =~ "Usage &amp; cost"
    assert usage.resp_body =~ "Total tokens"
    assert usage.resp_body =~ "claude:opus/high@work"

    memory = request(:get, "/memory")
    assert memory.resp_body =~ "href=\"/rules\""
    assert memory.resp_body =~ "href=\"/preferences\""
    assert memory.resp_body =~ "href=\"/guidance\""
    assert memory.resp_body =~ "scope workspace (slack:T123); visibility workspace"
    assert memory.resp_body =~ "Keep separate"
  end

  test "superseded decisions and calibration pages are removed without redirects" do
    for path <- ["/decisions", "/calibration"] do
      conn = request(:get, path)
      assert conn.status == 404
      assert get_resp_header(conn, "location") == []
    end
  end

  test "behavior and schedule changes require their own current typed confirmation" do
    for {kind, ref, action, expected, return_path} <- [
          {"behavior", "behavior:one", "disabled", {:behavior_status, :disabled}, "/rules"},
          {"behavior", "behavior:one", "deleted", {:behavior_status, :deleted}, "/rules"},
          {"schedule", "schedule:one", "active", {:schedule_status, :active}, "/schedules"},
          {"schedule", "schedule:one", "deleted", {:schedule_status, :deleted}, "/schedules"},
          {"schedule", "schedule:one", "run-now", :schedule_run_now, "/schedules"}
        ] do
      path = "/actions/#{kind}/#{URI.encode(ref, &URI.char_unreserved?/1)}/#{action}"
      confirmation = request(:get, path)
      assert confirmation.status == 200
      [_, token] = Regex.run(~r/name="_token" value="([^"]+)"/, confirmation.resp_body)

      accepted = request(:post, path, URI.encode_query(%{"_token" => token}))
      assert accepted.status == 303
      assert get_resp_header(accepted, "location") == [return_path]
      assert_received {^expected, ^ref}
    end

    assert request(:get, "/actions/behavior/missing/active").status == 404
    assert request(:get, "/actions/schedule/missing/paused").status == 404
    assert request(:get, "/actions/unknown/ref/delete").status == 404
  end

  test "schedule lifecycle controls stay discoverable after leaving Memory" do
    # Moving schedules to their own page must not remove the only pause,
    # resume and delete controls from the console.
    {:ok, detail} = options().projection.schedule.("schedule:one")

    for {status, label, action} <- [{:active, "Pause", "paused"}, {:paused, "Resume", "active"}] do
      html =
        HTML.schedule(%{
          detail
          | schedule: %{detail.schedule | status: status}
        })
        |> IO.iodata_to_binary()

      document = LazyHTML.from_fragment(html)

      assert document
             |> LazyHTML.query("form[action='/actions/schedule/schedule%3Aone/#{action}'] button")
             |> LazyHTML.text() == label

      assert html =~ "/actions/schedule/schedule%3Aone/deleted"
    end

    for status <- [:deleted, :expired] do
      html =
        HTML.schedule(%{
          detail
          | schedule: %{detail.schedule | status: status}
        })
        |> IO.iodata_to_binary()

      refute html =~ "/actions/schedule/"
    end
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

  test "native episode pages have no parallel static routes or snapshots" do
    for path <- ["/episodes", "/episodes/episode%3Aone", "/episodes/episode%3Aone/requests"] do
      response = request(:get, path)
      assert response.status == 404
      assert get_resp_header(response, "location") == []
      assert Router.snapshot(path, "", options()).status == 404
    end
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
    assert html =~ "No repository"
    assert html =~ "Not measured"
    assert html =~ "1 execution has no token report"
    assert html =~ "$0.25"
    assert html =~ "Daily measured token trend"
    # Hover-only SVG titles left the shipped chart as unexplained green bars.
    assert html =~ "data-date=\"2026-08-29\""
    assert html =~ "aria-label=\"29 Aug: 1,000 tokens\""
    assert html =~ "<strong>1,000</strong>"

    # Changing the date previously silently reset a shadow audit to live traffic.
    shadow = snapshot |> Map.put(:mode, "shadow") |> HTML.usage() |> IO.iodata_to_binary()
    assert shadow =~ "mode=shadow&amp;window=7d"
    refute shadow =~ "<h2>Measurement coverage"
    assert shadow =~ "Where the time went"
    refute shadow =~ "Token pricing"
    refute shadow =~ "Rates used for estimates"
    assert shadow =~ "Evaluation runs: replies and reactions are suppressed."
    # Scope defines every total, so it belongs above the figures, not inside
    # a footnote below two panels (and below both panels on narrow screens).
    {scope_at, _} = :binary.match(shadow, "Execution scope")
    {metrics_at, _} = :binary.match(shadow, "class=\"usage-summary\"")
    assert scope_at < metrics_at

    assert HTML.failures([]) =~ "Nothing needs attention"
    assert HTML.workspaces([]) |> IO.iodata_to_binary() =~ "No durable workspaces"

    assert HTML.overview(%{counts: %{}, needs_attention: []}) |> IO.iodata_to_binary() =~
             "Nothing needs attention"

    fleet_overview =
      HTML.overview(%{
        counts: %{},
        fleet: %{
          capacity: %{turn: %{free: 3}},
          current_placements: 2,
          eligible_workers: 1,
          required: true
        },
        needs_attention: []
      })
      |> IO.iodata_to_binary()

    assert fleet_overview =~ "Eligible Coop workers"
    assert fleet_overview =~ "Free turn slots"
    assert fleet_overview =~ "Current placements"

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
        record_card_feedback: fn card_id, state_id, verdict, note ->
          send(parent, {:card_lab_feedback, card_id, state_id, verdict, note})
          {:ok, %{id: Ecto.UUID.generate()}}
        end,
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
           "responder_queue_claimable{queue=\"ingress\"} 0\nresponder_queue_oldest_age_seconds{queue=\"ingress\"} 0\n"}
        end,
        ready: fn -> {:ok, %{stalled_queues: []}} end
      },
      projection: %{
        card_lab_feedback: fn
          "task-card", "working" ->
            [
              %{
                actor_ref: "control-plane:local",
                inserted_at: ~U[2026-09-04 12:00:00Z],
                note: "Existing review note",
                verdict: "good"
              }
            ]

          _card_id, _state_id ->
            []
        end,
        admission: fn
          "ingress-input:one" ->
            {:ok,
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
             }}

          _ref ->
            :not_found
        end,
        configuration: fn -> [%{key: "runtime", value: "configured"}] end,
        operator_configuration: fn ->
          %{
            grants: [
              %{kind: "MCP tool", name: "search_slack", source: "/etc/responder.yaml"}
            ],
            rows: [
              %{key: "runtime.mode", source: "/etc/responder.yaml", value: "product"}
            ],
            source: "/etc/responder.yaml"
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
              repository_ref: "responder",
              workspace_ref: "T123"
            }
          ]
        end,
        channel: fn
          "T123", "C456" ->
            {:ok,
             %{
               channel: %{
                 alert_policy: :offer,
                 channel_ref: "C456",
                 channel_state: nil,
                 configuration_revision: 2,
                 configuration_saved_at: ~U[2026-08-28 12:00:00Z],
                 incident_room: false,
                 membership: :joined,
                 participation: :mentions,
                 private: true,
                 repository_ref: "responder",
                 workspace_ref: "T123"
               },
               episodes: [
                 %{
                   ref: "episode:one",
                   state: :working,
                   thread_ref: "1787832000.001000",
                   updated_at: ~U[2026-08-28 12:00:00Z]
                 }
               ],
               overrides: [
                 %{
                   revision: 2,
                   scope: :channel,
                   setting: :proactive,
                   updated_at: ~U[2026-08-28 12:00:00Z],
                   value: true
                 }
               ],
               schedules: [
                 %{
                   next_occurrence_at: ~U[2026-08-29 09:00:00Z],
                   ref: "schedule:one",
                   status: :active,
                   title: "Daily health"
                 }
               ],
               summaries: [
                 %{
                   ref: "summary:one",
                   repository_ref: "responder",
                   thread_ref: "1787832000.001000",
                   updated_at: ~U[2026-08-28 12:00:00Z]
                 }
               ]
             }}

          _workspace, _channel ->
            :not_found
        end,
        delivery: fn
          "delivery:one" ->
            {:ok,
             %{
               detail: "stored diagnostic sha256:delivery",
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

          _ref ->
            :not_found
        end,
        failures: fn _params ->
          {:ok,
           [
             %{
               action: :rearm,
               attempt_count: 3,
               detail: "stored diagnostic sha256:delivery",
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
           ]}
        end,
        findings: fn _params -> %{items: [], total: 0, page: 1, pages: 1} end,
        incidents: fn _params ->
          [
            %{
              channel_ref: "CINCIDENT",
              channel_state: :active,
              episode_ref: "episode:incident",
              private: true,
              publication_ref: nil,
              publication_status: nil,
              ref: "incident:one",
              repository_ref: "responder",
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
                 branch_ref: "responder/operator-incident",
                 commit_sha: String.duplicate("a", 40),
                 last_error: "stored diagnostic sha256:abc123",
                 pr_number: 42,
                 pr_url: "https://github.example/emisar/responder/pull/42",
                 ref: "publication:incident",
                 repository: "responder",
                 status: :blocked,
                 updated_at: ~U[2026-08-28 12:00:00Z]
               },
               records: [],
               room: %{
                 channel_ref: "CINCIDENT",
                 channel_state: :active,
                 episode_ref: "episode:incident",
                 private: true,
                 ref: "incident:one",
                 repository_ref: "responder",
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
                   artifact_refs: [],
                   attachments: [],
                   cards: [],
                   editable: false,
                   event_kind: :event,
                   item_id: nil,
                   occurred_at: ~U[2026-08-28 11:58:00Z],
                   reactions: [],
                   record_refs: [],
                   ref: "webhook:event:one",
                   revision: 1,
                   state: nil,
                   status: :decided,
                   text: "Webhook universal · manual.unknown · revision 1"
                 },
                 %{
                   actor: :operator,
                   artifact_refs: [],
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
                   record_refs: [],
                   ref: "lab:event:one",
                   revision: 1,
                   state: nil,
                   status: :decided,
                   text: "Explain <unsafe> state"
                 },
                 %{
                   actor: :responder,
                   artifact_refs: [],
                   attachments: [
                     %{
                       bytes: 13,
                       media_type: "image/png",
                       name: "generated-chart.png",
                       path:
                         "/lab/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/turns/018f3ef7-1f62-7ee0-a83c-0c12f21d83e9/artifacts/artifact_chart",
                       ref: "artifact_chart",
                       status: "available"
                     }
                   ],
                   cards: [
                     %{
                       action: :confirm_task,
                       choices: [],
                       details: [{"Repository", "responder"}],
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
                         :request_task_readiness,
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
                       review_offer_ref: "record:publication_offer:ready",
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
                       title: "Post this in Conversation Lab",
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
                   record_refs: ["evidence:one"],
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
                    "scope_ref" => "responder",
                    "status" => "active",
                    "subject" => "primary_repository",
                    "value" => "responder",
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
              configured: %{contributor_policy: "responder-write"},
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
              ref: "responder",
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
              catch_up: :latest,
              destination_conversation_ref: "slack:T123:C456",
              destination_transport: "slack",
              failures: 0,
              next_occurrence_at: ~U[2026-08-29 09:00:00Z],
              ref: "schedule:one",
              repository: "responder",
              status: :active,
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
              title: "Matching GitHub update",
              condition: "Next matching GitHub update",
              episode_title: "Review the deployment",
              episode_href: "/episodes/episode%3Aone",
              context_label: "GitHub",
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
                   episode_ref: "episode:one",
                   missed_reason: nil,
                   ref: "occurrence:one",
                   scheduled_for: ~U[2026-08-28 09:00:00Z],
                   status: :dispatched
                 }
               ],
               schedule: %{
                 authority: :read_only,
                 catch_up: :latest,
                 confirmed_at: ~U[2026-08-27 12:00:00Z],
                 destination_conversation_ref: "slack:T123:C456",
                 destination_thread_ref: "1787832000.001000",
                 destination_transport: "slack",
                 expires_at: nil,
                 failure_count: 0,
                 last_error: nil,
                 next_occurrence_at: ~U[2026-08-29 09:00:00Z],
                 recurrence: "daily at 09:00:00",
                 ref: "schedule:one",
                 repository: "responder",
                 revision: 1,
                 source_episode_ref: "episode:one",
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
            {:ok,
             %{
               action: :retry,
               kind: "work",
               status: :blocked,
               work_recovery: %{
                 kind: :execution,
                 fingerprint: String.duplicate("a", 64),
                 retry_effect: "Starts a fresh logical turn."
               }
             }}

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

  defp multipart_request(path, token, message, filename, media_type, data) do
    boundary = "responder-lab-boundary"

    body =
      IO.iodata_to_binary([
        multipart_field(boundary, "_token", token),
        multipart_field(boundary, "message", message),
        "--#{boundary}\r\n",
        "content-disposition: form-data; name=\"attachments[]\"; filename=\"#{filename}\"\r\n",
        "content-type: #{media_type}\r\n\r\n",
        data,
        "\r\n--#{boundary}--\r\n"
      ])

    :post
    |> conn(path, body)
    |> put_req_header("content-type", "multipart/form-data; boundary=#{boundary}")
    |> Map.put(:host, "localhost")
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> Router.call(Router.init(options()))
  end

  defp multipart_field(boundary, name, value) do
    [
      "--#{boundary}\r\n",
      "content-disposition: form-data; name=\"#{name}\"\r\n\r\n",
      value,
      "\r\n"
    ]
  end
end
