defmodule Responder.ControlPlane.ProviderMessage do
  @moduledoc """
  Recognizable presentation for known notification formats.

  A Terraform run notification and a Grafana alert are not prose, and reading
  them as a flattened paragraph hides the three facts an operator needs first:
  which run or alert, in what state, from where. This is a pure projection over
  the retained content and source identity. It recognizes only shapes with a
  harvested example behind them, promotes a few labelled facts, and leaves
  everything else to the generic card. It never touches engagement, routing,
  identity, authority or prompts, and it never fetches anything.

  Recognition proves a format, not a sender: a human quoting an alert keeps
  human attribution, and the author on a Terraform notification is the
  notification's author field, not proof of who triggered the run.
  """

  @terraform_host "app.terraform.io"

  @type t :: %{
          provider: :terraform | :grafana,
          name: String.t(),
          state: String.t() | nil,
          tone: :planning | :confirmation | :failure | :applied | :firing | :resolved | nil,
          subject: String.t() | nil,
          facts: [%{label: String.t(), value: String.t()}],
          links: [%{label: String.t(), href: String.t()}]
        }

  @doc "Recognizes a retained input's content, or returns nil for the generic card."
  @spec recognize(String.t() | nil, map() | nil) :: t() | nil
  def recognize("slack", %{"attachments" => attachments}) when is_list(attachments) do
    case Enum.find(attachments, &terraform_attachment?/1) do
      nil -> nil
      run -> terraform(run, attachments)
    end
  end

  def recognize("webhook", %{"payload" => %{"adapter" => "grafana"} = payload}),
    do: grafana(payload)

  def recognize(_source_kind, _content), do: nil

  defp terraform_attachment?(%{"footer" => "HCP Terraform", "title_link" => link})
       when is_binary(link),
       do: terraform_url?(link)

  defp terraform_attachment?(_attachment), do: false

  defp terraform(run, attachments) do
    state = attachments |> Enum.map(& &1["title"]) |> Enum.find(&terraform_state?/1)
    description = string(run["text"])
    parsed = parse_terraform_description(description)

    facts =
      [
        {"Branch", parsed[:branch]},
        {"Commit", parsed[:commit]},
        {"Author", string(run["author_name"])},
        {"GitHub run", parsed[:github_run]},
        {"Run", terraform_run_id(run)},
        {"Description", if(parsed == %{}, do: description)}
      ]
      |> facts()

    %{
      provider: :terraform,
      name: "HCP Terraform",
      state: state && String.replace_prefix(state, "Run ", ""),
      tone: terraform_tone(state),
      subject: terraform_workspace(run["pretext"]),
      facts: facts,
      links:
        links([
          {"Open run", run["title_link"]},
          {"Open workspace", terraform_workspace_url(run["pretext"])}
        ])
    }
  end

  # "Run Planning" is a state; "Run run-k9Cp…" is the run itself.
  defp terraform_state?("Run run-" <> _id), do: false
  defp terraform_state?("Run " <> _rest), do: true
  defp terraform_state?(_title), do: false

  defp terraform_run_id(%{"title" => "Run " <> id}) when byte_size(id) > 0, do: id
  defp terraform_run_id(_run), do: nil

  # "main 3376639b... (@AndrewDryga, gh run 34306095502)" is the one description
  # format the harvested fixture shows. Anything else is kept whole.
  defp parse_terraform_description(nil), do: %{}

  defp parse_terraform_description(text) do
    case Regex.run(~r/\A(\S+) ([0-9a-f]{7,40}) \(@([^,\s)]+)(?:, gh run (\d+))?\)\z/, text) do
      [_, branch, commit, _author, run] ->
        %{branch: branch, commit: commit, github_run: present(run)}

      [_, branch, commit, _author] ->
        %{branch: branch, commit: commit}

      _no_match ->
        %{}
    end
  end

  defp terraform_tone(nil), do: nil

  defp terraform_tone(state) do
    cond do
      state =~ ~r/Errored|Failed|Canceled|Cancelled|Discarded/i -> :failure
      state =~ ~r/Applied/i -> :applied
      state =~ ~r/Needs Confirmation|Confirmation/i -> :confirmation
      state =~ ~r/Plann|Apply|Pending|Queued/i -> :planning
      true -> nil
    end
  end

  defp terraform_workspace(pretext) when is_binary(pretext) do
    case Regex.run(~r/<https:\/\/#{@terraform_host}\/app\/([^|>]+)\|([^>]+)>/, pretext) do
      [_, _path, label] -> label
      _ -> nil
    end
  end

  defp terraform_workspace(_pretext), do: nil

  defp terraform_workspace_url(pretext) when is_binary(pretext) do
    case Regex.run(~r/<(https:\/\/#{@terraform_host}\/app\/[^|>]+)\|/, pretext) do
      [_, url] -> url
      _ -> nil
    end
  end

  defp terraform_workspace_url(_pretext), do: nil

  defp terraform_url?(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: @terraform_host} -> true
      _ -> false
    end
  end

  defp grafana(payload) do
    labels = map(payload["labels"])
    status = string(payload["status"])

    %{
      provider: :grafana,
      name: "Grafana",
      state: status && String.capitalize(status),
      tone: grafana_tone(status),
      subject: string(payload["title"]),
      facts:
        facts([
          {"Summary", string(payload["summary"])},
          {"Service", labels["service"] || labels["job"]},
          {"Instance", labels["instance"]},
          {"Severity", string(payload["severity"])},
          {"Started", string(payload["starts_at"])},
          {"Ended", if(status == "resolved", do: string(payload["ends_at"]))}
        ]),
      links: links([{"Open alert", payload["source_url"]}])
    }
  end

  defp grafana_tone("firing"), do: :firing
  defp grafana_tone("resolved"), do: :resolved
  defp grafana_tone(_status), do: nil

  defp facts(pairs) do
    for {label, value} <- pairs, is_binary(value), value != "" do
      %{label: label, value: value}
    end
  end

  defp links(pairs) do
    for {label, href} <- pairs, is_binary(href), safe_link?(href), do: %{label: label, href: href}
  end

  defp safe_link?(href) do
    case URI.parse(href) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> true
      _ -> false
    end
  end

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil
  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}
  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value
end
