defmodule Responder.GitHub.Input do
  @moduledoc """
  Converts one authenticated GitHub App webhook into canonical ingress.

  The trusted binding fixes installation and repository authority. The signed
  event may select only an item and thread inside that repository.
  """

  @behaviour Responder.Ingress.Adapter

  alias Responder.CanonicalJSON
  alias Responder.GitHub.Binding
  alias Responder.Ingress.Input

  @event_fields [:delivery_ref, :event_name, :event_ref, :payload]
  @reaction_names ~w(+1 -1 confused eyes heart hooray laugh rocket)
  @revision_tie_slots 1_000
  @revision_action_ranks %{message: 0, edit: 1, delete: 2}
  @actions %{
    "issue_comment" => %{"created" => :message, "deleted" => :delete, "edited" => :edit},
    "pull_request_review" => %{
      "dismissed" => :delete,
      "edited" => :edit,
      "submitted" => :message
    },
    "pull_request_review_comment" => %{
      "created" => :message,
      "deleted" => :delete,
      "edited" => :edit
    }
  }

  @impl Responder.Ingress.Adapter
  def source_kind, do: "github"

  @impl Responder.Ingress.Adapter
  def normalize(event, %Binding{} = binding) do
    with :ok <- exact_event(event),
         :ok <- valid_delivery(event.delivery_ref),
         :ok <- valid_delivery(event.event_ref),
         {:ok, event_kind} <- event_kind(event.event_name, event.payload),
         :ok <- Binding.authorize_payload(binding, event.payload),
         {:ok, details} <- event_details(event.event_name, event.payload, event_kind),
         {:ok, actor} <- actor(event.payload, binding),
         {:ok, occurred_at} <- occurred_at(details.item) do
      build_input(event, binding, details, actor, occurred_at)
    end
  end

  def normalize(_event, _binding), do: {:error, {:invalid_github_input, :binding}}

  defp build_input(event, binding, details, actor, occurred_at) do
    Input.new(%{
      actor: actor,
      content: %{
        "delivery_ref" => event.delivery_ref,
        "event_name" => event.event_name,
        "payload" => event.payload
      },
      destination: %{
        conversation_ref: "github:#{binding.name}:repository:#{binding.repository_id}",
        thread_ref: thread_ref(binding, details),
        transport: "github"
      },
      event_kind: details.event_kind,
      event_ref: event.event_ref,
      native_input_id: native_input_id(binding, details),
      occurred_at: occurred_at,
      occurred_at_source: :source,
      revision: revision(occurred_at, details.event_kind),
      source: %{kind: "github", ref: binding.name},
      source_capabilities: source_capabilities(details),
      source_item_ref: "github:#{details.item_kind}:#{details.item_id}"
    })
  end

  defp exact_event(%{} = event) do
    if Map.keys(event) |> Enum.sort() == Enum.sort(@event_fields),
      do: :ok,
      else: {:error, {:invalid_github_input, :fields}}
  end

  defp exact_event(_event), do: {:error, {:invalid_github_input, :fields}}

  defp valid_delivery(value) do
    if reference?(value), do: :ok, else: {:error, {:invalid_github_input, :delivery_ref}}
  end

  defp event_kind(event_name, %{"action" => action}) when is_binary(action) do
    with {:ok, actions} <- Map.fetch(@actions, event_name),
         {:ok, event_kind} <- Map.fetch(actions, action) do
      {:ok, event_kind}
    else
      :error when is_map_key(@actions, event_name) -> {:error, {:invalid_github_input, :action}}
      :error -> {:error, {:invalid_github_input, :event}}
    end
  end

  defp event_kind(event_name, _payload) when is_map_key(@actions, event_name),
    do: {:error, {:invalid_github_input, :action}}

  defp event_kind(_event_name, _payload), do: {:error, {:invalid_github_input, :event}}

  defp event_details("issue_comment", payload, event_kind) do
    with %{"comment" => %{"id" => item_id} = item, "issue" => %{"number" => number} = issue} <-
           payload,
         true <- positive_id?(item_id) and positive_id?(number) do
      {:ok,
       %{
         event_kind: event_kind,
         item: item,
         item_id: item_id,
         item_kind: "issue_comment",
         subject_kind: if(Map.has_key?(issue, "pull_request"), do: "pull", else: "issue"),
         subject_number: number,
         thread_root_id: nil
       }}
    else
      _invalid -> {:error, {:invalid_github_input, :item}}
    end
  end

  defp event_details("pull_request_review", payload, event_kind) do
    with %{
           "pull_request" => %{"number" => number},
           "review" => %{"id" => item_id} = item
         } <- payload,
         true <- positive_id?(item_id) and positive_id?(number) do
      {:ok,
       %{
         event_kind: event_kind,
         item: item,
         item_id: item_id,
         item_kind: "pull_request_review",
         subject_kind: "pull",
         subject_number: number,
         thread_root_id: nil
       }}
    else
      _invalid -> {:error, {:invalid_github_input, :item}}
    end
  end

  defp event_details("pull_request_review_comment", payload, event_kind) do
    with %{
           "comment" => %{"id" => item_id} = item,
           "pull_request" => %{"number" => number}
         } <- payload,
         true <- positive_id?(item_id) and positive_id?(number),
         root_id <- Map.get(item, "in_reply_to_id") || item_id,
         true <- positive_id?(root_id) do
      {:ok,
       %{
         event_kind: event_kind,
         item: item,
         item_id: item_id,
         item_kind: "pull_request_review_comment",
         subject_kind: "pull",
         subject_number: number,
         thread_root_id: root_id
       }}
    else
      _invalid -> {:error, {:invalid_github_input, :item}}
    end
  end

  defp actor(
         %{"sender" => %{"id" => id, "type" => type}},
         %Binding{responder_actor_id: id}
       )
       when is_integer(id) and id > 0 and is_binary(type),
       do: {:error, {:github_input_ignored, :self_authored}}

  defp actor(
         %{"sender" => %{"id" => id, "type" => type}},
         %Binding{authorized_actor_ids: authorized}
       )
       when is_integer(id) and id > 0 and is_binary(type) do
    if id in authorized do
      kind = if type == "Bot", do: :bot, else: :user
      {:ok, %{kind: kind, ref: "github-user:#{id}"}}
    else
      {:error, {:github_input_ignored, :actor_not_authorized}}
    end
  end

  defp actor(_payload, _binding), do: {:error, {:invalid_github_input, :actor}}

  defp occurred_at(item) do
    value = item["updated_at"] || item["submitted_at"] || item["created_at"]

    case DateTime.from_iso8601(value || "") do
      {:ok, datetime, 0} -> {:ok, datetime}
      _invalid -> {:error, {:invalid_github_input, :occurred_at}}
    end
  end

  # GitHub can deliver webhooks out of order and can retain one timestamp across
  # edits. Keep create/edit/delete in disjoint semantic bands, then let the
  # Inbox allocate receipt-order ties only inside the exact action band.
  defp revision(occurred_at, event_kind) do
    action_rank = Map.fetch!(@revision_action_ranks, event_kind)

    DateTime.to_unix(occurred_at, :millisecond) *
      (@revision_tie_slots * map_size(@revision_action_ranks)) +
      action_rank * @revision_tie_slots
  end

  defp thread_ref(binding, %{subject_number: number, thread_root_id: root_id})
       when is_integer(root_id),
       do: "github:#{binding.name}:pull:#{number}:review-thread:#{root_id}"

  defp thread_ref(binding, details),
    do: "github:#{binding.name}:#{details.subject_kind}:#{details.subject_number}"

  defp native_input_id(binding, details) do
    digest = CanonicalJSON.digest([binding.name, details.item_kind, details.item_id])
    "github-item:#{digest}"
  end

  defp source_capabilities(%{event_kind: event_kind, item_kind: item_kind})
       when event_kind != :delete and
              item_kind in ["issue_comment", "pull_request_review_comment"] do
    %{"react" => %{"emoji_names" => @reaction_names}}
  end

  defp source_capabilities(_details), do: %{}

  defp positive_id?(value),
    do: is_integer(value) and value > 0 and value <= 9_223_372_036_854_775_807

  defp reference?(value) do
    is_binary(value) and String.valid?(value) and String.trim(value) != "" and
      :binary.match(value, <<0>>) == :nomatch and byte_size(value) <= 1_024
  end
end
