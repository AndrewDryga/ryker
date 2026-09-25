defmodule Ryker.Publication.Executor do
  @moduledoc """
  Executes one leased publication phase without owning routing or authority.

  Review, notification, and publication are separate durable phases. Every
  retry reuses the frozen Coop review key/revision or the exact reviewed patch;
  an operator approval can therefore never drift to a newer workspace tree.
  """

  alias Ryker.Delivery.Adapters
  alias Ryker.Publication.{Callback, Custody, Request, Review}
  alias Ryker.Work.Session

  @review_states ~w(open exhausted)
  @closed_session_states ~w(closed discarded)

  @spec run(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%{lease_ref: lease_ref, publication: publication, session: _session} = claim, options)
      when is_binary(lease_ref) and is_list(options) do
    with {:ok, settings} <- settings(options) do
      case publication.status do
        :review_pending -> review(claim, settings)
        :review_ready -> deliver(claim, settings)
        :publish_pending -> publish(claim, settings)
        :published_ready -> deliver(claim, settings)
        _other -> {:error, :publication_not_executable}
      end
    end
  end

  def run(_claim, _options), do: {:error, {:invalid_publication_executor, :claim}}

  defp review(claim, settings) do
    publication = claim.publication
    session = claim.session

    with :ok <- review_session_open(session),
         {:ok, remote} <-
           leased_call(claim, settings, fn ->
             settings.api.get_session(settings.client, session.coop_session_id)
           end),
         {:ok, revision} <- exact_review_session(remote, session),
         {:ok, frozen} <-
           settings.custody.freeze_review_revision(publication.ref, claim.lease_ref, revision),
         key <- review_key(frozen),
         {:ok, response} <- run_review(claim, frozen, key, settings),
         {:ok, dossier} <- exact_review_response(response, session.coop_session_id),
         {:ok, patch} <- review_patch(dossier, claim, settings),
         {:ok, stored} <-
           settings.custody.store_review(
             publication.ref,
             claim.lease_ref,
             frozen.review_generation,
             dossier,
             patch
           ) do
      {:ok, %{phase: :reviewed, publication: stored}}
    end
  end

  defp deliver(claim, settings) do
    with {:ok, request} <- settings.custody.delivery_request(claim.publication),
         {:ok, receipt} <-
           leased_call(claim, settings, fn -> Adapters.publish(request, settings.adapters) end),
         {:ok, stored} <-
           settings.custody.confirm_delivery(
             claim.publication.ref,
             claim.lease_ref,
             receipt
           ) do
      {:ok, %{phase: :delivered, publication: stored, receipt: receipt}}
    end
  end

  defp publish(claim, settings) do
    with {:ok, request} <- Request.new(claim.publication),
         result <-
           leased_call(claim, settings, fn ->
             settings.publisher.publish(request, settings.publisher_binding)
           end) do
      store_publish_result(result, claim, settings)
    end
  end

  defp store_publish_result({:ok, receipt}, claim, settings) do
    with {:ok, stored} <-
           settings.custody.store_publication(
             claim.publication.ref,
             claim.lease_ref,
             receipt
           ) do
      {:ok, %{phase: :published, publication: stored, receipt: receipt}}
    end
  end

  defp store_publish_result(
         {:error, {:publication_conflict, code, receipt} = reason},
         claim,
         settings
       ) do
    with {:ok, _stored} <-
           settings.custody.store_conflict(
             claim.publication.ref,
             claim.lease_ref,
             code,
             receipt
           ) do
      {:error, reason}
    end
  end

  defp store_publish_result({:error, _reason} = error, _claim, _settings), do: error

  # Ryker records the close itself when it cleans a session up, and a closed
  # Coop session never reopens: asking the worker about it again would only
  # spend a command to learn what is already on record here.
  defp review_session_open(%Session{discarded_at: %DateTime{}}),
    do: {:error, {:publication_review_session_closed, "discarded"}}

  defp review_session_open(%Session{closed_at: %DateTime{}}),
    do: {:error, {:publication_review_session_closed, "closed"}}

  defp review_session_open(_session), do: :ok

  # A closed or discarded session is an answer, not a protocol error: the
  # review can never run there, and the dispatcher ends the publication on it.
  defp exact_review_session(
         %{
           "external_ref" => _external_ref,
           "id" => _id,
           "policy" => _policy,
           "policy_digest" => _digest,
           "revision" => revision,
           "state" => state
         } = remote,
         session
       ) do
    cond do
      not same_review_session?(remote, session) ->
        {:error, {:publication_coop_identity_mismatch, :session}}

      state in @closed_session_states ->
        {:error, {:publication_review_session_closed, state}}

      state in @review_states and is_integer(revision) and revision > 0 ->
        {:ok, revision}

      true ->
        {:error, {:publication_coop_protocol_error, :session}}
    end
  end

  defp exact_review_session(_remote, _session),
    do: {:error, {:publication_coop_protocol_error, :session}}

  defp same_review_session?(remote, session) do
    remote["id"] == session.coop_session_id and
      remote["external_ref"] == Session.coop_task_ref(session) and
      remote["policy"] == session.policy and remote["policy_digest"] == session.policy_digest
  end

  defp exact_review_response(
         %{
           "operation" => %{
             "id" => operation_id,
             "method" => "RunReview",
             "resource_id" => session_id,
             "resource_type" => "review",
             "state" => "succeeded"
           },
           "review" => %{"operation_id" => operation_id, "session_id" => session_id} = review
         },
         session_id
       )
       when is_binary(operation_id) and operation_id != "",
       do: {:ok, review}

  defp exact_review_response(_response, _session_id),
    do: {:error, {:publication_coop_protocol_error, :review}}

  defp review_patch(dossier, claim, settings) do
    if Review.publishable?(dossier) do
      leased_call(claim, settings, fn -> fetch_review_patch(dossier, claim, settings) end)
    else
      {:ok, nil}
    end
  end

  defp fetch_review_patch(dossier, claim, settings) do
    if function_exported?(settings.api, :get_session_review_patch, 5) do
      settings.api.get_session_review_patch(
        settings.client,
        claim.session.coop_session_id,
        dossier["patch_artifact_id"],
        dossier["patch_digest"],
        dossier["patch_bytes"]
      )
    else
      settings.api.get_review_patch(
        settings.client,
        dossier["patch_artifact_id"],
        dossier["patch_digest"],
        dossier["patch_bytes"]
      )
    end
  end

  defp run_review(claim, frozen, key, settings) do
    result =
      leased_call(claim, settings, fn ->
        settings.api.run_review(
          settings.client,
          claim.session.coop_session_id,
          key,
          frozen.review_expected_revision
        )
      end)

    case result do
      {:error, {:coop_error, 409, "revision_conflict", _detail} = reason} ->
        case settings.custody.advance_review_generation(
               claim.publication.ref,
               claim.lease_ref,
               frozen.review_generation
             ) do
          {:ok, _publication} -> {:error, {:publication_review_generation_spent, reason}}
          {:error, _reason} = error -> error
        end

      other ->
        other
    end
  end

  defp review_key(publication) do
    "ryker:publication:review:#{publication.id}:g#{publication.review_generation}"
  end

  defp leased_call(claim, settings, function) do
    result_ref = make_ref()

    {pid, monitor} =
      Callback.start(result_ref, fn ->
        try do
          function.()
        rescue
          exception -> {:error, {:publication_callback_crashed, Exception.message(exception)}}
        catch
          kind, reason -> {:error, {:publication_callback_crashed, kind, reason}}
        end
      end)

    cadence_ms = max(div(settings.lease_seconds * 1_000, 3), 1)

    try do
      await_call(result_ref, pid, monitor, claim, settings, cadence_ms)
    after
      Callback.finish(pid, monitor, result_ref)
    end
  end

  defp await_call(result_ref, pid, monitor, claim, settings, cadence_ms) do
    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor, [:flush])

        case renew(claim, settings) do
          :ok -> result
          {:error, _reason} = error -> error
        end

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:publication_callback_exit, reason}}
    after
      cadence_ms ->
        case renew(claim, settings) do
          :ok ->
            await_call(result_ref, pid, monitor, claim, settings, cadence_ms)

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp renew(claim, settings) do
    case settings.custody.renew(
           claim.publication.ref,
           claim.lease_ref,
           settings.lease_seconds
         ) do
      {:ok, _publication} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp settings(options) do
    allowed = [
      :adapters,
      :api,
      :client,
      :custody,
      :lease_seconds,
      :publisher,
      :publisher_binding
    ]

    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
         Keyword.keys(options) -- allowed == [] do
      validate_settings(%{
        adapters: Keyword.fetch!(options, :adapters),
        api: Keyword.fetch!(options, :api),
        client: Keyword.fetch!(options, :client),
        custody: Keyword.get(options, :custody, Custody),
        lease_seconds: Keyword.get(options, :lease_seconds, 60),
        publisher: Keyword.fetch!(options, :publisher),
        publisher_binding: Keyword.fetch!(options, :publisher_binding)
      })
    else
      {:error, {:invalid_publication_executor, :options}}
    end
  rescue
    KeyError -> {:error, {:invalid_publication_executor, :options}}
  end

  defp validate_settings(settings) do
    callbacks = [
      {settings.api, [get_session: 2, get_review_patch: 4, run_review: 4], :api},
      {
        settings.custody,
        [
          confirm_delivery: 3,
          delivery_request: 1,
          advance_review_generation: 3,
          freeze_review_revision: 3,
          renew: 3,
          store_publication: 3,
          store_review: 5
        ],
        :custody
      },
      {settings.publisher, [publish: 2], :publisher}
    ]

    with :ok <- validate_callbacks(callbacks),
         true <- is_map(settings.adapters) and map_size(settings.adapters) > 0,
         true <- is_integer(settings.lease_seconds) and settings.lease_seconds > 0 do
      {:ok, settings}
    else
      false -> {:error, {:invalid_publication_executor, :settings}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_callbacks(callbacks) do
    Enum.reduce_while(callbacks, :ok, fn {module, functions, field}, :ok ->
      valid =
        is_atom(module) and Code.ensure_loaded?(module) and
          Enum.all?(functions, fn {function, arity} ->
            function_exported?(module, function, arity)
          end)

      if valid,
        do: {:cont, :ok},
        else: {:halt, {:error, {:invalid_publication_executor, field}}}
    end)
  end
end
