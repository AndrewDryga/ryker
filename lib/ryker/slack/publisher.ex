defmodule Ryker.Slack.Publisher do
  @moduledoc """
  Translates host-routed delivery intents into Slack message and reaction API calls.

  Message retries search for the stable delivery metadata before posting. A
  response loss therefore returns to durable custody and reconciles the
  already-visible message instead of posting a duplicate.
  """

  @behaviour Ryker.Delivery.Platform
  @behaviour Ryker.Delivery.MessagePublisher
  @behaviour Ryker.Delivery.ReactionPublisher

  alias Ryker.Delivery.Request
  alias Ryker.Slack.{Mentions, Target}
  alias Ryker.Work.DeliveryReceipt

  @impl true
  def transport, do: "slack"

  @impl true
  def publish_message(%Request{kind: :message} = request, binding) do
    with {:ok, request} <- materialize_mentions(request, binding),
         {:ok, target} <- Target.parse(request),
         :ok <- destination_allowed(binding, target),
         {:ok, api, client} <- client(binding, target.workspace_ref),
         {:ok, message_ref} <- reconcile_message(api, client, request, target) do
      DeliveryReceipt.new(
        request.ref,
        request.transport,
        request.conversation_ref,
        request.thread_ref,
        message_ref
      )
    end
  end

  def publish_message(_request, _binding),
    do: {:error, {:invalid_slack_delivery, :message}}

  defp materialize_mentions(
         %Request{document: %{"message" => message}} = request,
         binding
       ) do
    if Mentions.typed?(message) do
      with %{mention_authority: callback} when is_function(callback, 1) <- binding,
           {:ok, authority} <- callback.(request.ref),
           {:ok, _prepared} <- Mentions.prepare_authority(authority),
           [] <- Mentions.violations(message, authority) do
        {:ok, %{request | document: Map.put(request.document, "slack_mentions", authority)}}
      else
        %{} -> {:error, {:slack_mention_authority_not_configured, :delivery}}
        [_first | _rest] -> {:error, {:invalid_slack_mentions, :unauthorized}}
        {:error, _reason} = error -> error
        _invalid -> {:error, {:slack_mention_authority_not_configured, :delivery}}
      end
    else
      {:ok, request}
    end
  end

  @impl Ryker.Delivery.MessagePublisher
  def update_message(%Request{kind: :message} = request, message_ref, document, binding) do
    with {:ok, target} <- Target.parse(request),
         :ok <- destination_allowed(binding, target),
         {:ok, api, client} <- client(binding, target.workspace_ref),
         true <- function_exported?(api, :update_message, 5),
         :ok <-
           api.update_message(
             client,
             target.channel_ref,
             message_ref,
             document,
             request.ref
           ) do
      :ok
    else
      false -> {:error, {:slack_message_update_not_supported, :adapter}}
      {:error, _reason} = error -> error
    end
  end

  def update_message(_request, _message_ref, _document, _binding),
    do: {:error, {:invalid_slack_delivery, :message_update}}

  @impl true
  def publish_reaction(%Request{kind: :reaction} = request, binding) do
    with {:ok, target} <- Target.parse(request),
         :ok <- destination_allowed(binding, target),
         {:ok, api, client} <- client(binding, target.workspace_ref),
         :ok <- publish_reaction_action(api, client, target, request.document) do
      DeliveryReceipt.new(
        request.ref,
        request.transport,
        request.conversation_ref,
        request.thread_ref,
        target.message_ref
      )
    end
  end

  def publish_reaction(_request, _binding),
    do: {:error, {:invalid_slack_delivery, :reaction}}

  defp publish_reaction_action(api, client, target, document) do
    case Map.get(document, "action", "add") do
      "add" ->
        api.add_reaction(client, target.channel_ref, target.message_ref, document["emoji_name"])

      "remove" ->
        if function_exported?(api, :remove_reaction, 4),
          do:
            api.remove_reaction(
              client,
              target.channel_ref,
              target.message_ref,
              document["emoji_name"]
            ),
          else: {:error, {:slack_reaction_removal_not_supported, :adapter}}
    end
  end

  defp reconcile_message(api, client, request, target) do
    if request.artifacts == [],
      do: reconcile_plain_message(api, client, request, target),
      else: reconcile_file_message(api, client, request, target)
  end

  defp reconcile_plain_message(api, client, request, target) do
    case api.find_message(client, target.channel_ref, target.thread_ref, request.ref) do
      {:ok, message_ref} ->
        {:ok, message_ref}

      :not_found ->
        post_message(api, client, request, target)

      {:error, reason} ->
        {:error, {:delivery_reconciliation_failed, reason}}
    end
  end

  defp reconcile_file_message(api, client, request, target) do
    files = prepare_files(request)
    filenames = Enum.map(files, & &1.filename)

    case api.find_files(client, target.channel_ref, target.thread_ref, filenames) do
      {:ok, message_ref} ->
        {:ok, message_ref}

      :not_found ->
        upload_files(api, client, request, target, files)

      {:error, reason} ->
        {:error, {:delivery_reconciliation_failed, reason}}
    end
  end

  defp upload_files(api, client, request, target, files) do
    case api.upload_files(
           client,
           target.channel_ref,
           target.thread_ref,
           request.document,
           request.ref,
           files
         ) do
      {:ok, message_ref} -> {:ok, message_ref}
      {:error, {:delivery_rate_limited, _delay, _error} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:delivery_uncertain, reason}}
    end
  end

  defp prepare_files(request) do
    suffix = request.ref |> digest() |> binary_part(0, 12)
    alt_text = request.document["message"] |> String.slice(0, 960)
    alt_text = "Rendered output for: " <> alt_text

    request.artifacts
    |> Enum.with_index(1)
    |> Enum.map(fn {artifact, index} ->
      extension = extension(artifact["media_type"])
      base = artifact["name"] |> Path.rootname() |> safe_base()
      ordinal = index |> Integer.to_string() |> String.pad_leading(2, "0")
      fixed = "--#{suffix}-#{ordinal}.#{extension}"
      maximum_base = 255 - byte_size(fixed)
      filename = binary_part(base, 0, min(byte_size(base), maximum_base)) <> fixed

      %{
        alt_text: alt_text,
        data: artifact["data"],
        filename: filename,
        media_type: artifact["media_type"],
        title: artifact["name"] |> String.slice(0, 200)
      }
    end)
  end

  defp safe_base(value) do
    value =
      value
      |> String.replace(~r/[^A-Za-z0-9_-]+/u, "-")
      |> String.downcase()
      |> String.trim("-")

    if value == "", do: "generated-image", else: value
  end

  defp extension("image/png"), do: "png"
  defp extension("image/jpeg"), do: "jpg"
  defp extension("image/gif"), do: "gif"
  defp extension("image/webp"), do: "webp"

  defp digest(value),
    do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp post_message(api, client, request, target) do
    case api.post_message(
           client,
           target.channel_ref,
           target.thread_ref,
           request.document,
           request.ref
         ) do
      {:ok, message_ref} -> {:ok, message_ref}
      {:error, {:delivery_rate_limited, _delay, _error} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:delivery_uncertain, reason}}
    end
  end

  defp client(%{workspaces: workspaces}, workspace_ref) when is_map(workspaces) do
    with {:ok, %{api: api, client: client}} <- Map.fetch(workspaces, workspace_ref),
         true <- valid_api?(api) do
      {:ok, api, client}
    else
      _invalid -> {:error, {:slack_workspace_not_configured, workspace_ref}}
    end
  end

  defp client(_binding, workspace_ref),
    do: {:error, {:slack_workspace_not_configured, workspace_ref}}

  defp destination_allowed(%{destination_allowed: callback}, target)
       when is_function(callback, 2),
       do: callback.(target.workspace_ref, target.channel_ref)

  defp destination_allowed(_binding, _target), do: :ok

  defp valid_api?(api) do
    is_atom(api) and Code.ensure_loaded?(api) and function_exported?(api, :find_message, 4) and
      function_exported?(api, :post_message, 5) and function_exported?(api, :find_files, 4) and
      function_exported?(api, :upload_files, 6) and function_exported?(api, :add_reaction, 4) and
      function_exported?(api, :update_message, 5)
  end
end
