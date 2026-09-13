defmodule Ryker.ControlPlane.RouterTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{CSRF, EpisodePage, HTML, LabPage, Pages, Router}
  alias Ryker.Fixtures.ControlPlaneOptions

  @secret ControlPlaneOptions.secret()

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

  test "retired Card Lab and Test journeys routes answer like any other unknown page" do
    # The runtime Slack Card Lab and the static Test journeys checklist were
    # retired on 2026-09-13 as a clean cut. A stale bookmark or an old link in a
    # Slack thread must get the ordinary unknown-page answer: no redirect, no
    # compatibility alias, and no path left that could queue a specimen post or
    # record feedback on a catalog that no longer exists.
    unknown_page = request(:get, "/never-a-page")
    assert unknown_page.status == 404

    for path <- [
          "/card-lab",
          "/card-lab/task-card/working",
          "/card-lab/behavior-offer/preference",
          "/card-lab/incident-room/provisioning/slack/#{Ecto.UUID.generate()}/retry",
          "/manual-tests"
        ] do
      removed = request(:get, path)
      assert removed.status == unknown_page.status, path
      assert get_resp_header(removed, "location") == []
      refute removed.resp_body =~ "specimen"
      refute removed.resp_body =~ "journey"
      assert Pages.page(String.split(path, "/", trim: true), %{}, options()).status == 404
    end

    unknown_post = request(:post, "/never-a-page", "_token=stale")

    for path <- [
          "/card-lab/task-card/working/transitions/wait-input",
          "/card-lab/task-card/working/feedback",
          "/card-lab/incident-room/provisioning/slack/preview",
          "/card-lab/incident-room/provisioning/slack/post",
          "/card-lab/incident-room/provisioning/slack/#{Ecto.UUID.generate()}/update"
        ] do
      removed = request(:post, path, "_token=stale&verdict=good&note=late")
      assert removed.status == unknown_post.status, path
      assert get_resp_header(removed, "location") == []
    end
  end

  test "the retired /lab route family answers like any other unknown page and sends nothing" do
    # The surface was renamed to Conversations on 2026-09-13 as a clean cut.
    # /lab links live in old Slack threads, bookmarks and browser history; a
    # compatibility route would keep two URL families alive for one identity,
    # and a stale composer posting to /lab/:id/messages must not be accepted
    # as a message on the renamed route without the operator resubmitting it.
    id = "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"
    unknown_page = request(:get, "/never-a-page")
    unknown_post = request(:post, "/never-a-page", "_token=stale")

    for path <- [
          "/lab",
          "/lab/new",
          "/lab/#{id}",
          "/lab/#{id}/records/record%3Atask_offer%3Aconfirmed/timeline",
          "/lab/#{id}/turns/018f3ef7-1f62-7ee0-a83c-0c12f21d83e9/artifacts/artifact_chart"
        ] do
      removed = request(:get, path)
      assert removed.status == unknown_page.status, path
      assert get_resp_header(removed, "location") == []
      assert Pages.page(String.split(path, "/", trim: true), %{}, options()).status == 404
    end

    token = CSRF.token(@secret, "conversation_lab:send", id)

    for path <- [
          "/lab/#{id}/messages",
          "/lab/#{id}/messages/018f3ef7-1f62-7ee0-a83c-0c12f21d83e7/edit",
          "/lab/#{id}/messages/018f3ef7-1f62-7ee0-a83c-0c12f21d83e7/delete",
          "/lab/#{id}/replies/control-plane-message%3Alab-reply/reactions",
          "/lab/#{id}/records/record%3Atask_offer%3Alab/confirm-task"
        ] do
      removed = request(:post, path, URI.encode_query(%{"_token" => token, "message" => "Hello"}))
      assert removed.status == unknown_post.status, path
      assert get_resp_header(removed, "location") == []
    end

    refute_received {:lab_message, _conversation, _message}
    refute_received {:lab_message_edit, _conversation, _item, _message}
    refute_received {:lab_message_delete, _conversation, _item}
    refute_received {:lab_reaction, _conversation, _message, _action, _emoji}
    refute_received {:lab_record_action, _conversation, _record, _action, _choice}
  end

  test "a new conversation is an unsaved identity until its first message" do
    # The index at /conversations is the new-conversation draft, so the old
    # /conversations/new redirect is gone as a clean cut: it answers like any
    # unknown conversation, without a location header. A fresh identity page
    # still writes nothing until the operator sends, and an invalid identity
    # is a 404, not a fresh chat. The page itself is live only: the HTTP
    # router serves the conversation's actions and downloads, never a copy.
    retired = request(:get, "/conversations/new")
    assert retired.status == 404
    assert get_resp_header(retired, "location") == []
    refute_received {:lab_message, _conversation, _message}

    unsent = Ecto.UUID.generate()
    assert request(:get, "/conversations/#{unsent}").status == 404
    {:ok, snapshot, _token} = Router.lab_snapshot(unsent, options())
    assert snapshot.messages == []
    assert conversation_html(unsent) =~ "action=\"/conversations/#{unsent}/messages\""
    refute_received {:lab_message, _conversation, _message}

    assert request(:get, "/conversations/not-a-uuid").status == 404
    assert request(:get, "/conversations/new/extra").status == 404
    refute conversation_html(unsent) =~ "/conversations/new"
  end

  test "a confirmed-action page renders in the static shell with hard browser boundaries" do
    conn = request(:get, "/actions/memory/memory%3Aone/forget")

    assert conn.status == 200

    assert get_resp_header(conn, "content-security-policy") == [
             "default-src 'none'; style-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self'; font-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
           ]

    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-ryker-version") == ["0.1.0-dev"]

    assert conn.resp_body =~
             ~r/<a [^>]*class="app-brand"[^>]*aria-label="Ryker"|<a [^>]*aria-label="Ryker"[^>]*class="app-brand"/

    assert conn.resp_body =~ "<title>Forget checkout-api memory? · Ryker</title>"
    refute conn.resp_body =~ "https://"
    refute conn.resp_body =~ "<script"

    # The root of the workspace is a live page; the HTTP router does not keep
    # a static overview behind it.
    assert request(:get, "/").status == 404
  end

  test "a conversation sends through a CSRF-protected durable action and refreshes locally" do
    # The page is the live LabPage, rendered here from the same decorated
    # snapshot the shell loads, so every control it carries is posted to the
    # exact route and token the HTTP router validates.
    conversation = %{resp_body: conversation_html("018f3ef7-1f62-7ee0-a83c-0c12f21d83e6")}
    assert conversation.resp_body =~ "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6\""
    # The fixture message text says "Lab flow"; retained content keeps its words.
    refute conversation.resp_body =~ "Conversation Lab"
    refute conversation.resp_body =~ "this Lab"
    assert conversation.resp_body =~ "actor-integration"
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
             "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Alab/confirm-task"

    assert conversation.resp_body =~ ">Start task<"

    assert conversation.resp_body =~
             "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Aincident/open-incident"

    assert conversation.resp_body =~ ">Open local incident<"

    assert conversation.resp_body =~
             "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Aconfirmed/diff"

    assert conversation.resp_body =~ ">View diff<"
    assert conversation.resp_body =~ ">Timeline<"
    assert conversation.resp_body =~ ">Evidence<"
    assert conversation.resp_body =~ ">Handoff<"
    assert conversation.resp_body =~ "data-max-bytes=\"20000\""
    assert conversation.resp_body =~ "enctype=\"multipart/form-data\""
    assert conversation.resp_body =~ "name=\"attachments[]\""
    assert conversation.resp_body =~ ">Edit<"
    assert conversation.resp_body =~ ">Delete<"
    # The fixture reply carries one recorded heart from the local operator: a
    # pressed pill that removes, and a picker whose custom form is aligned.
    refute conversation.resp_body =~ "React to this reply"
    refute conversation.resp_body =~ "Custom emoji</summary>"
    assert conversation.resp_body =~ "class=\"lab-reaction-form lab-reaction-pill\""
    assert conversation.resp_body =~ "aria-pressed=\"true\""
    assert conversation.resp_body =~ "name=\"action\" value=\"remove\""
    assert conversation.resp_body =~ "class=\"lab-reaction-picker\""
    assert conversation.resp_body =~ "aria-label=\"Add reaction\""

    assert conversation.resp_body =~
             "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/messages/018f3ef7-1f62-7ee0-a83c-0c12f21d83e7/edit"

    assert conversation.resp_body =~
             "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/messages/018f3ef7-1f62-7ee0-a83c-0c12f21d83e7/delete"

    refute conversation.resp_body =~ "<script"
    assert length(Regex.scan(~r/>Staging</, conversation.resp_body)) == 1
    assert length(Regex.scan(~r/>Production</, conversation.resp_body)) == 1
    refute conversation.resp_body =~ "<unsafe>"
    refute conversation.resp_body =~ "Repair <unsafe> Lab flow"

    artifact_path =
      "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/turns/018f3ef7-1f62-7ee0-a83c-0c12f21d83e9/artifacts/artifact_chart"

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
        ~r/action="\/conversations\/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6\/messages".*?name="_token" value="([^"]+)"/s,
        conversation.resp_body
      )

    rejected =
      request(
        :post,
        "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/messages",
        URI.encode_query(%{"_token" => "wrong", "message" => "Follow up"})
      )

    assert rejected.status == 403
    refute_received {:lab_message, _id, _message}

    accepted =
      request(
        :post,
        "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/messages",
        URI.encode_query(%{"_token" => token, "message" => "Follow up"})
      )

    assert accepted.status == 303

    assert get_resp_header(accepted, "location") == [
             "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"
           ]

    assert_received {:lab_message, "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6", "Follow up"}

    receipt =
      conn(
        :post,
        "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/messages",
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
        "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/messages",
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
        "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/messages/018f3ef7-1f62-7ee0-a83c-0c12f21d83e7/edit",
        URI.encode_query(%{"_token" => "wrong", "message" => "Corrected request"})
      )

    assert rejected_edit.status == 403
    refute_received {:lab_message_edit, _conversation, _item, _message}

    accepted_edit =
      request(
        :post,
        "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/messages/018f3ef7-1f62-7ee0-a83c-0c12f21d83e7/edit",
        URI.encode_query(%{"_token" => edit_token, "message" => "Corrected request"})
      )

    assert accepted_edit.status == 303

    assert_received {:lab_message_edit, "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
                     "018f3ef7-1f62-7ee0-a83c-0c12f21d83e7", "Corrected request"}

    # The inline editor saves without leaving the page: it asks for JSON and
    # gets the same 202 receipt as the composer, one revision per request.
    live_edit =
      json_request(
        "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/messages/018f3ef7-1f62-7ee0-a83c-0c12f21d83e7/edit",
        URI.encode_query(%{"_token" => edit_token, "message" => "Corrected again"})
      )

    assert live_edit.status == 202
    assert Jason.decode!(live_edit.resp_body) == %{"accepted" => true}
    assert get_resp_header(live_edit, "location") == []

    assert_received {:lab_message_edit, "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
                     "018f3ef7-1f62-7ee0-a83c-0c12f21d83e7", "Corrected again"}

    refute_received {:lab_message_edit, _conversation, _item, _message}

    rejected_live_edit =
      json_request(
        "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/messages/018f3ef7-1f62-7ee0-a83c-0c12f21d83e7/edit",
        URI.encode_query(%{"_token" => "wrong", "message" => "Corrected again"})
      )

    assert rejected_live_edit.status == 403
    refute_received {:lab_message_edit, _conversation, _item, _message}

    delete_resource =
      "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6:018f3ef7-1f62-7ee0-a83c-0c12f21d83e7:delete"

    delete_token = CSRF.token(@secret, "conversation_lab:message", delete_resource)

    accepted_delete =
      request(
        :post,
        "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/messages/018f3ef7-1f62-7ee0-a83c-0c12f21d83e7/delete",
        URI.encode_query(%{"_token" => delete_token})
      )

    assert accepted_delete.status == 303

    assert_received {:lab_message_delete, "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
                     "018f3ef7-1f62-7ee0-a83c-0c12f21d83e7"}

    live_delete =
      json_request(
        "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/messages/018f3ef7-1f62-7ee0-a83c-0c12f21d83e7/delete",
        URI.encode_query(%{"_token" => delete_token})
      )

    assert live_delete.status == 202
    assert Jason.decode!(live_delete.resp_body) == %{"accepted" => true}

    assert_received {:lab_message_delete, "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
                     "018f3ef7-1f62-7ee0-a83c-0c12f21d83e7"}

    reaction_message_ref = "control-plane-message:lab-reply"

    reaction_resource =
      "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6:#{reaction_message_ref}"

    reaction_token = CSRF.token(@secret, "conversation_lab:reaction", reaction_resource)

    rejected_reaction =
      request(
        :post,
        "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/replies/control-plane-message%3Alab-reply/reactions",
        URI.encode_query(%{"_token" => "wrong", "action" => "add", "emoji" => "heart"})
      )

    assert rejected_reaction.status == 403
    refute_received {:lab_reaction, _conversation, _message, _action, _emoji}

    accepted_reaction =
      request(
        :post,
        "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/replies/control-plane-message%3Alab-reply/reactions",
        URI.encode_query(%{
          "_token" => reaction_token,
          "action" => "add",
          "emoji" => "heart"
        })
      )

    assert accepted_reaction.status == 303

    assert_received {:lab_reaction, "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
                     "control-plane-message:lab-reply", :add, "heart"}

    # A pill or picker submission from the page gets the 202 receipt; the
    # exact reply target and the normalized name still reach the action.
    live_reaction =
      json_request(
        "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/replies/control-plane-message%3Alab-reply/reactions",
        URI.encode_query(%{"_token" => reaction_token, "action" => "remove", "emoji" => "heart"})
      )

    assert live_reaction.status == 202
    assert Jason.decode!(live_reaction.resp_body) == %{"accepted" => true}

    assert_received {:lab_reaction, "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
                     "control-plane-message:lab-reply", :remove, "heart"}

    [_, task_token] =
      Regex.run(
        ~r/action="\/conversations\/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6\/records\/record%3Atask_offer%3Alab\/confirm-task".*?name="_token" value="([^"]+)"/s,
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
        "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Alab/confirm-task",
        URI.encode_query(%{"_token" => "wrong"})
      )

    assert refused_task.status == 403
    refute_received {:lab_record_action, _conversation, _record, _action, _choice}

    accepted_task =
      request(
        :post,
        "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Alab/confirm-task",
        URI.encode_query(%{"_token" => task_token})
      )

    assert accepted_task.status == 303

    assert get_resp_header(accepted_task, "location") == [
             "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"
           ]

    assert_received {:lab_record_action, "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
                     "record:task_offer:lab", :confirm_task, nil}

    [_, choice_token] =
      Regex.run(
        ~r/action="\/conversations\/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6\/records\/record%3Ainput_request%3Alab\/answer"><input type="hidden" name="_token" value="([^"]+)"><input type="hidden" name="choice_index" value="1">/,
        conversation.resp_body
      )

    crossed_choice =
      request(
        :post,
        "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Ainput_request%3Alab/answer",
        URI.encode_query(%{"_token" => choice_token, "choice_index" => "0"})
      )

    assert crossed_choice.status == 403

    accepted_choice =
      request(
        :post,
        "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Ainput_request%3Alab/answer",
        URI.encode_query(%{"_token" => choice_token, "choice_index" => "1"})
      )

    assert accepted_choice.status == 303

    assert_received {:lab_record_action, "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
                     "record:input_request:lab", :answer_input, 1}

    [_, stop_token] =
      Regex.run(
        ~r/action="\/conversations\/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6\/records\/record%3Atask_offer%3Aconfirmed\/stop-task".*?name="_token" value="([^"]+)"/s,
        conversation.resp_body
      )

    stopped =
      request(
        :post,
        "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Aconfirmed/stop-task",
        URI.encode_query(%{"_token" => stop_token})
      )

    assert stopped.status == 303

    assert_received {:lab_record_action, "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
                     "record:task_offer:confirmed", :stop_task, nil}

    task_view =
      request(
        :get,
        "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Aconfirmed/timeline"
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
          "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Aconfirmed/#{view_name}"
        )

      assert rendered.status == 200

      assert_received {:lab_task_view, "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
                       "record:task_offer:confirmed", ^view, %{}}
    end

    assert request(
             :get,
             "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Aconfirmed/unknown"
           ).status == 404

    assert request(
             :get,
             "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Aconfirmed/timeline?unexpected=true"
           ).status == 400

    assert request(
             :get,
             "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Aconfirmed/diff?offset=2400"
           ).status == 400

    refute_received {:lab_task_view, _conversation, _record, :diff, _params}

    digest = String.duplicate("a", 64)

    diff_view =
      request(
        :get,
        "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Aconfirmed/diff"
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
        "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Aconfirmed/diff?offset=2400&snapshot=#{digest}"
      )

    assert next_diff.status == 200

    assert_received {:lab_task_view, "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
                     "record:task_offer:confirmed", :diff,
                     %{offset: 2400, snapshot_digest: ^digest}}

    assert request(
             :post,
             "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/messages",
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

  test "new and malformed Lab routes fail closed without creating hidden authority" do
    empty_id = "018f3ef7-1f62-7ee0-a83c-0c12f21d83ff"

    assert {:ok, %{conversation_id: ^empty_id, messages: []}, _token} =
             Router.lab_snapshot(empty_id, options())

    assert conversation_html(empty_id) =~ empty_id
    assert request(:get, "/conversations/not-a-uuid").status == 404

    invalid_path =
      request(
        :post,
        "/conversations/not-a-uuid/messages",
        URI.encode_query(%{"_token" => "none", "message" => "Do not persist me"})
      )

    assert invalid_path.status == 404

    unsupported =
      :post
      |> conn("/conversations/#{empty_id}/messages", ~s({"message":"no"}))
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
      |> then(&Router.lab_snapshot(empty_id, &1))

    assert unavailable_projection == {:error, :projection_unavailable}
    assert Router.lab_snapshot("not-a-uuid", options()) == {:error, :path_ref}

    message_token = CSRF.token(@secret, "conversation_lab:send", empty_id)

    unavailable_message =
      options()
      |> put_in([:actions, :send_lab_message], fn _id, _message, _attachments ->
        {:error, :admission_unavailable}
      end)
      |> then(fn opts ->
        request_with_options(
          :post,
          "/conversations/#{empty_id}/messages",
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
          "/conversations/#{empty_id}/records/#{record_ref}/confirm-memory",
          URI.encode_query(%{"_token" => record_token}),
          opts
        )
      end)

    assert unavailable_record.status == 409
  end

  test "the superseded task readiness action has no route or handler" do
    conversation_id = "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"
    record_ref = "record:task_offer:confirmed"
    path = "/conversations/#{conversation_id}/records/#{record_ref}/task-readiness"

    assert request(:post, path, URI.encode_query(%{"_token" => "obsolete"})).status == 404
    refute conversation_html(conversation_id) =~ "task-readiness"
    refute_received {:lab_record_action, _, _, :request_task_readiness, _}
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

    conversation = %{resp_body: conversation_html(conversation_id)}

    for {record_ref, action_name, action} <- actions do
      encoded_ref = URI.encode(record_ref, &URI.char_unreserved?/1)
      path = "/conversations/#{conversation_id}/records/#{encoded_ref}/#{action_name}"
      assert conversation.resp_body =~ path

      resource = "#{conversation_id}:#{record_ref}:#{action}:none"
      token = CSRF.token(@secret, "conversation_lab:record", resource)
      accepted = request(:post, path, URI.encode_query(%{"_token" => token}))

      assert accepted.status == 303
      assert_received {:lab_record_action, ^conversation_id, ^record_ref, ^action, nil}
    end

    for {action_name, action, field, value} <- [
          {"task-publish", :approve_task_publication, "publication_ref",
           "publication:confirmed-task"},
          {"task-check", :check_task_publication, "publication_ref", "publication:confirmed-task"}
        ] do
      record_ref = "record:task_offer:confirmed"
      encoded_ref = URI.encode(record_ref, &URI.char_unreserved?/1)
      path = "/conversations/#{conversation_id}/records/#{encoded_ref}/#{action_name}"
      assert conversation.resp_body =~ path

      resource = "#{conversation_id}:#{record_ref}:#{action}:#{value}"
      token = CSRF.token(@secret, "conversation_lab:record", resource)
      accepted = request(:post, path, URI.encode_query(%{"_token" => token, field => value}))

      assert accepted.status == 303

      assert_received {:lab_record_action, ^conversation_id, ^record_ref, ^action,
                       %{publication_ref: ^value}}
    end

    for {action_name, action} <- [
          {"task-retry", :retry_task_publication},
          {"task-update", :update_task_publication},
          {"task-discard", :discard_task_publication}
        ] do
      record_ref = "record:task_offer:confirmed"
      encoded_ref = URI.encode(record_ref, &URI.char_unreserved?/1)
      path = "/conversations/#{conversation_id}/records/#{encoded_ref}/#{action_name}"
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

    invalid = request(:post, "/conversations/#{conversation_id}/records/record:one/unknown", "")
    assert invalid.status == 404
  end

  test "the native episode renders recovery and confirmed action controls without exposing extra fields" do
    {:ok, detail} = options().projection.episode.("episode:one", %{})

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
      assert confirmation.resp_body =~ "href=\"/timeline/episode%3Aone\""
      [_, token] = Regex.run(~r/name="_token" value="([^"]+)"/, confirmation.resp_body)

      accepted = request(:post, path, URI.encode_query(%{"_token" => token}))
      assert accepted.status == 303
      assert get_resp_header(accepted, "location") == ["/timeline/episode%3Aone"]
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
          "value" => "ryker-elixir"
        })
      )

    assert accepted.status == 303

    assert_received {:memory_review, "memory-review:two", :edit,
                     %{"subject" => "primary_codebase", "value" => "ryker-elixir"}}
  end

  test "a blocked delivery can be rearmed only from its exact confirmed intent" do
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

  test "a resumable blocked task says where its saved work is going" do
    # The confirmation is the last thing an operator reads before pressing, so
    # it has to name the resume rather than a fresh retry that would restart
    # from the repository with the saved working copy left behind.
    path = "/actions/work/episode%3Ablocked/retry"
    initial = options()
    {:ok, row} = initial.projection.work.("episode:blocked")

    recovery = %{
      fingerprint: String.duplicate("a", 64),
      kind: :execution,
      resume: %{byte_size: 4_096, checkpoint_ref: "checkpoint:one", repository_ref: "ryker"},
      retry_effect: "Restores the saved working copy of ryker (4096 bytes)."
    }

    resumable =
      put_in(initial, [:projection, :work], fn _ ->
        {:ok, Map.put(row, :work_recovery, recovery)}
      end)

    confirmation = request_with_options(:get, path, nil, resumable)
    assert confirmation.status == 200
    assert confirmation.resp_body =~ "Resume this work in another workspace?"
    assert confirmation.resp_body =~ "Restores the saved working copy of ryker"

    plain =
      put_in(initial, [:projection, :work], fn _ ->
        {:ok, Map.put(row, :work_recovery, %{recovery | resume: nil})}
      end)

    assert request_with_options(:get, path, nil, plain).resp_body =~ "Retry this blocked work?"
  end

  test "each recoverable blocked custody has a typed confirmed action" do
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

  test "rejects DNS-rebinding hosts and non-loopback peers before routing anything" do
    assert request(:get, "/", "evil.example", {127, 0, 0, 1}).status == 421
    assert request(:get, "/", "localhost", {10, 0, 0, 2}).status == 403
    assert request(:get, "/healthz", "localhost", {10, 0, 0, 1}).status == 403
    assert request(:get, "/healthz?probe=1", "example.com", {127, 0, 0, 1}).status == 421
    assert request(:get, "/healthz", "::1", {0, 0, 0, 0, 0, 0, 0, 1}).status == 200
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
    assert metrics.resp_body =~ "ryker_queue_claimable"
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

  test "the removed audit page cannot be opened through HTTP or as a live page" do
    assert request(:get, "/audit").status == 404
    assert Pages.page(["audit"], %{}, options()).status == 404
  end

  test "the superseded incidents routes are removed without redirects" do
    for path <- ["/incidents", "/incidents/incident%3Aone"] do
      removed = request(:get, path)
      assert removed.status == 404
      assert get_resp_header(removed, "location") == []
    end
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

  test "a lifecycle action against a stale, foreign or unknown target is refused before it runs" do
    # Delete moved behind an overflow control on 2026-09-13. A control that
    # is harder to see is easier to leave open across a refresh, so the
    # confirmation it opens must still be bound to the exact row and state:
    # a rule deleted meanwhile answers 404 to its own confirmation and 409 to
    # a stale POST, a token minted for another row or another action is 403,
    # and none of these reach set_behavior_status.
    options = options()

    options = %{
      options
      | projection:
          Map.put(options.projection, :behavior, fn
            "behavior:one" ->
              {:ok,
               %{
                 kind: :standing_assignment,
                 ref: "behavior:one",
                 status: "active",
                 payload: %{"title" => "Triage deployment alerts"}
               }}

            "behavior:gone" ->
              {:ok,
               %{
                 kind: :standing_assignment,
                 ref: "behavior:gone",
                 status: "deleted",
                 payload: %{"title" => "Retired rule"}
               }}

            _ ->
              :not_found
          end)
    }

    live = "/actions/behavior/behavior%3Aone/disabled"
    confirmation = request_with_options(:get, live, nil, options)
    assert confirmation.status == 200
    [_, token] = Regex.run(~r/name="_token" value="([^"]+)"/, confirmation.resp_body)

    # The row was deleted after the menu was opened: no confirmation, no action.
    for action <- ["active", "disabled", "deleted"] do
      stale = "/actions/behavior/behavior%3Agone/#{action}"
      assert request_with_options(:get, stale, nil, options).status == 404

      rejected =
        request_with_options(:post, stale, URI.encode_query(%{"_token" => token}), options)

      assert rejected.status == 409
    end

    # A token for Pause cannot delete, and a token for one row cannot touch another.
    crossed = "/actions/behavior/behavior%3Aone/deleted"

    assert request_with_options(:post, crossed, URI.encode_query(%{"_token" => token}), options).status ==
             403

    foreign =
      CSRF.token(@secret, "behavior:disabled", "behavior:two")

    assert request_with_options(:post, live, URI.encode_query(%{"_token" => foreign}), options).status ==
             403

    assert request_with_options(:get, "/actions/behavior/behavior%3Aone/expired", nil, options).status ==
             404

    refute_received {{:behavior_status, _}, _}

    accepted = request_with_options(:post, live, URI.encode_query(%{"_token" => token}), options)
    assert accepted.status == 303
    assert_received {{:behavior_status, :disabled}, "behavior:one"}
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
    assert request(:put, "/healthz").status == 405
  end

  test "native pages have no parallel static routes or secondary bodies" do
    for path <- ["/activity", "/timeline/episode%3Aone", "/timeline/episode%3Aone/model-calls"] do
      response = request(:get, path)
      assert response.status == 404
      assert get_resp_header(response, "location") == []
      assert Pages.page(String.split(path, "/", trim: true), %{}, options()).status == 404
    end
  end

  test "the HTTP router serves nothing the live router already answers" do
    # Until 2026-09-13 the HTTP router kept a full static GET clause for every
    # secondary page, each unreachable in production because the live route
    # matched first, and each still tested as if it were the page. With every
    # projection here answering, a surviving clause would answer 200; the
    # fallback answers the one not-found body. The reverse holds too: every
    # GET contract the HTTP router keeps is forwarded to it, not shadowed.
    live_paths =
      for %{plug: Phoenix.LiveView.Plug, verb: :get, path: path} <-
            Phoenix.Router.routes(Ryker.ControlPlane.WebRouter),
          do: path

    assert length(live_paths) > 20

    for path <- live_paths do
      sample =
        path
        |> String.split("/", trim: true)
        |> Enum.map_join("/", &sample_segment/1)

      response = request(:get, "/" <> sample)
      assert response.status == 404, "#{path} is answered by both routers (/#{sample})"
      assert response.resp_body =~ "This page does not exist"
    end

    for path <- [
          "/healthz",
          "/readyz",
          "/metrics",
          "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/records/record%3Atask_offer%3Aconfirmed/timeline",
          "/conversations/018f3ef7-1f62-7ee0-a83c-0c12f21d83e6/turns/018f3ef7-1f62-7ee0-a83c-0c12f21d83e9/artifacts/artifact_chart",
          "/actions/memory/memory%3Aone/forget",
          "/actions/memory-review/memory-review%3Atwo/edit"
        ] do
      assert request(:get, path).status == 200, path

      assert %{plug: Ryker.ControlPlane.LegacyPlug} =
               Phoenix.Router.route_info(Ryker.ControlPlane.WebRouter, "GET", path, "localhost"),
             "#{path} is not forwarded to the HTTP router"
    end
  end

  defp sample_segment(":id"), do: "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"
  defp sample_segment(":ref"), do: "episode%3Aone"
  defp sample_segment(":workspace"), do: "T123"
  defp sample_segment(":channel"), do: "C456"
  defp sample_segment(":kind"), do: "delivery"
  defp sample_segment(":" <> name), do: flunk("no sample value for :#{name}")
  defp sample_segment(segment), do: segment

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
          repository_ref: "ryker",
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

    assert HTML.workspaces([], %{budget: %{}, preview: [], workers: []}) |> IO.iodata_to_binary() =~
             "No working copies right now"

    assert HTML.not_found("Unknown") |> IO.iodata_to_binary() =~ "This unknown does not exist"
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

  defp options, do: ControlPlaneOptions.options(self())

  # The live conversation page as the shell renders it: the snapshot decorated
  # with the exact edit, reaction and record controls the HTTP router accepts.
  defp conversation_html(conversation_id) do
    options = options()
    {:ok, snapshot, token} = Router.lab_snapshot(conversation_id, options)

    render_component(&LabPage.render/1,
      snapshot: snapshot,
      token: token,
      items: options.projection.lab_index.(),
      messages: Enum.map(snapshot.messages, &{"lab-message-#{&1.ref}", &1}),
      history: %{before: nil, exhausted: true, failed: false, loaded: 0, page_size: 50},
      announcement: "",
      placeholder: LabPage.example_for(conversation_id),
      now: ~U[2026-08-28 12:30:00Z]
    )
  end

  # A form post from the page's own JavaScript: it asks for a JSON receipt
  # instead of the redirect a plain browser submission gets.
  defp json_request(path, body) do
    :post
    |> conn(path, body)
    |> Map.put(:host, "localhost")
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> put_req_header("accept", "application/json")
    |> Router.call(Router.init(options()))
  end

  defp multipart_request(path, token, message, filename, media_type, data) do
    boundary = "ryker-lab-boundary"

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
