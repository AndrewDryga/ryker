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

  alias Ryker.Crypto
  alias Ryker.Delivery.Request
  alias Ryker.Slack.Client.Messages
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
         {:ok, api, client} <- client(binding, target.workspace_ref) do
      api.update_message(client, target.channel_ref, message_ref, document, request.ref)
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
        if function_exported?(api, :remove_reaction, 4) do
          api.remove_reaction(
            client,
            target.channel_ref,
            target.message_ref,
            document["emoji_name"]
          )
        else
          {:error, {:slack_reaction_removal_not_supported, :adapter}}
        end
    end
  end

  defp reconcile_message(api, client, request, target) do
    if request.artifacts == [],
      do: reconcile_plain_message(api, client, request, target),
      else: reconcile_file_message(api, client, request, target)
  end

  defp reconcile_plain_message(api, client, request, target) do
    case find_message(api, client, request, target) do
      {:ok, message_ref} ->
        {:ok, message_ref}

      :not_found ->
        post_message(api, client, request, target)

      {:error, reason} ->
        {:error, {:delivery_reconciliation_failed, reason}}
    end
  end

  # A request its custody froze at a known moment cannot have been posted
  # before then, so the walk for an earlier copy starts an hour before it,
  # a margin for Slack's clock, instead of at the channel's first message.
  defp find_message(api, client, %Request{frozen_at: %DateTime{} = frozen_at} = request, target) do
    if function_exported?(api, :find_message, 5) do
      api.find_message(
        client,
        target.channel_ref,
        target.thread_ref,
        request.ref,
        Messages.oldest(frozen_at)
      )
    else
      api.find_message(client, target.channel_ref, target.thread_ref, request.ref)
    end
  end

  defp find_message(api, client, request, target),
    do: api.find_message(client, target.channel_ref, target.thread_ref, request.ref)

  # Slack shares uploaded files a moment after the upload completes. An
  # attempt that uploaded them without seeing the share yet left their ids in
  # the request, so this one waits for that share: a retry that found no share
  # uploaded the images a second time (2026-10-04 review).
  defp reconcile_file_message(api, client, request, target) do
    files = prepare_files(request)
    filenames = Enum.map(files, & &1.filename)

    oldest = if request.frozen_at, do: Messages.oldest(request.frozen_at)

    case api.find_files(client, target.channel_ref, target.thread_ref, filenames, oldest) do
      {:ok, message_ref} ->
        {:ok, message_ref}

      :not_found when request.upload_refs != [] ->
        {:error, {:delivery_share_pending, request.upload_refs}}

      :not_found ->
        upload_files(api, client, request, target, files)

      {:error, reason} ->
        {:error, {:delivery_reconciliation_failed, reason}}
    end
  end

  defp upload_files(api, client, request, target, files) do
    client
    |> api.upload_files(
      target.channel_ref,
      target.thread_ref,
      request.document,
      request.ref,
      files
    )
    |> settle()
  end

  defp prepare_files(request) do
    suffix = request.ref |> digest() |> binary_part(0, 12)
    # Slack bounds a file's description at 1,000 bytes and its title at 200.
    alt_text = Ryker.Text.cut("Rendered output for: " <> request.document["message"], 1_000)

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
        title: Ryker.Text.cut(artifact["name"], 200)
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
    do: value |> Crypto.sha256_hex()

  defp post_message(api, client, request, target) do
    client
    |> api.post_message(target.channel_ref, target.thread_ref, request.document, request.ref)
    |> settle()
  end

  # Slack answering is definite: an API error or a 4xx means nothing was
  # posted, and a request the client refused to send never reached Slack. Only
  # a call Slack did not answer (a lost socket, an unreadable reply, a 5xx) may
  # have landed, and only the metadata walk on the next attempt can say. An
  # upload Slack completed has landed, and the next attempt waits for its share.
  defp settle({:ok, message_ref}), do: {:ok, message_ref}

  defp settle({:error, {:slack_file_share_pending, [_ | _] = upload_refs}}),
    do: {:error, {:delivery_share_pending, upload_refs}}

  defp settle({:error, {:delivery_rate_limited, _delay, _error}} = error), do: error
  defp settle({:error, {:slack_api_error, _error}} = error), do: error
  defp settle({:error, {:invalid_slack_api_request, _field}} = error), do: error
  defp settle({:error, {:slack_upload_unavailable, _reason}} = error), do: error

  defp settle({:error, {:slack_http_error, status, _error}} = error)
       when is_integer(status) and status < 500,
       do: error

  defp settle({:error, reason}), do: {:error, {:delivery_uncertain, reason}}

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
      function_exported?(api, :post_message, 5) and function_exported?(api, :find_files, 5) and
      function_exported?(api, :upload_files, 6) and function_exported?(api, :add_reaction, 4) and
      function_exported?(api, :update_message, 5)
  end
end
