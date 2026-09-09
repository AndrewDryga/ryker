defmodule Responder.Work.Result do
  @moduledoc """
  The host-owned delivery decision for one validated model candidate.

  The model candidate remains exact bytes. This small value only tells the
  episode kernel whether those bytes produce a visible reply or a deliberate
  no-delivery result.
  """

  alias Responder.CanonicalJSON

  @enforce_keys [:continuation, :delivery]
  defstruct [:continuation, :delivery, :decision_reason, :delivery_document]

  @complete %{"kind" => "complete"}
  @fields ~w(continuation decision_reason delivery delivery_document)

  @type t :: %__MODULE__{
          continuation: map(),
          delivery: :reply | :none,
          decision_reason: String.t() | nil,
          delivery_document: map() | nil
        }

  @spec new(:reply | :none, map() | nil, String.t() | nil, map()) ::
          {:ok, t()} | {:error, term()}
  def new(delivery, delivery_document \\ nil, decision_reason \\ nil, continuation \\ @complete)

  def new(:reply, delivery_document, nil, continuation) when is_map(delivery_document) do
    with :ok <- CanonicalJSON.validate(delivery_document, max_bytes: 512 * 1_024),
         {:ok, continuation} <- prepare_continuation(continuation) do
      {:ok,
       %__MODULE__{
         continuation: continuation,
         delivery: :reply,
         decision_reason: nil,
         delivery_document: delivery_document
       }}
    else
      {:error, {:invalid_work_result, _field}} = error -> error
      {:error, _reason} -> {:error, {:invalid_work_result, :delivery_document}}
    end
  end

  def new(:none, nil, decision_reason, @complete) do
    if valid_text?(decision_reason, 240, 960) do
      {:ok,
       %__MODULE__{
         continuation: @complete,
         delivery: :none,
         decision_reason: decision_reason,
         delivery_document: nil
       }}
    else
      {:error, {:invalid_work_result, :decision_reason}}
    end
  end

  def new(:none, nil, decision_reason, %{"kind" => "wait", "wait_kind" => "event"} = continuation) do
    with {:ok, result} <- new(:none, nil, decision_reason, @complete),
         {:ok, continuation} <- prepare_continuation(continuation) do
      {:ok, %{result | continuation: continuation}}
    end
  end

  def new(delivery, _delivery_document, _decision_reason, _continuation),
    do: {:error, {:invalid_work_result, delivery}}

  @spec prepare(term()) :: {:ok, t()} | {:error, term()}
  def prepare(%__MODULE__{} = result) do
    new(
      result.delivery,
      result.delivery_document,
      result.decision_reason,
      result.continuation
    )
  end

  def prepare(_result), do: {:error, {:invalid_work_result, :value}}

  @spec document(t()) :: map()
  def document(%__MODULE__{} = result) do
    %{
      "continuation" => result.continuation,
      "decision_reason" => result.decision_reason,
      "delivery" => Atom.to_string(result.delivery),
      "delivery_document" => result.delivery_document
    }
  end

  @spec prepare_document(term()) :: {:ok, t()} | {:error, term()}
  def prepare_document(%{} = document) do
    if Map.keys(document) |> Enum.sort() == @fields do
      case document["delivery"] do
        "reply" ->
          new(
            :reply,
            document["delivery_document"],
            document["decision_reason"],
            document["continuation"]
          )

        "none" ->
          new(
            :none,
            document["delivery_document"],
            document["decision_reason"],
            document["continuation"]
          )

        _delivery ->
          {:error, {:invalid_work_result, :delivery}}
      end
    else
      {:error, {:invalid_work_result, :fields}}
    end
  end

  def prepare_document(_document), do: {:error, {:invalid_work_result, :document}}

  @spec validate_at(t(), DateTime.t()) :: :ok | {:error, term()}
  def validate_at(%__MODULE__{continuation: continuation}, %DateTime{} = now) do
    case continuation do
      %{"kind" => "complete"} ->
        :ok

      %{"deadline_at" => nil, "kind" => "wait", "wait_kind" => kind}
      when kind in ~w(input event) ->
        :ok

      %{"deadline_at" => deadline_at, "kind" => "wait", "wait_kind" => "event"} ->
        validate_event_deadline(deadline_at, now)

      _invalid ->
        {:error, {:invalid_work_result, :continuation}}
    end
  end

  defp validate_event_deadline(deadline_at, now) do
    case normalize_deadline(deadline_at) do
      {:ok, deadline} -> deadline_comparison(DateTime.compare(deadline, now))
      _elapsed_or_invalid -> {:error, :work_continuation_deadline_elapsed}
    end
  end

  defp deadline_comparison(:gt), do: :ok
  defp deadline_comparison(_not_future), do: {:error, :work_continuation_deadline_elapsed}

  defp prepare_continuation(%{"kind" => "complete"} = continuation)
       when map_size(continuation) == 1,
       do: {:ok, continuation}

  defp prepare_continuation(
         %{
           "deadline_at" => nil,
           "kind" => "wait",
           "wait_kind" => kind,
           "wait_ref" => wait_ref
         } = continuation
       )
       when map_size(continuation) == 4 and kind in ~w(input event) do
    if valid_text?(wait_ref, 1_024, 1_024),
      do: {:ok, continuation},
      else: {:error, {:invalid_work_result, :continuation}}
  end

  defp prepare_continuation(
         %{
           "deadline_at" => deadline_at,
           "kind" => "wait",
           "wait_kind" => "event",
           "wait_ref" => wait_ref
         } = continuation
       )
       when map_size(continuation) == 4 do
    with true <- valid_text?(wait_ref, 1_024, 1_024),
         {:ok, deadline_at} <- normalize_deadline(deadline_at) do
      {:ok, %{continuation | "deadline_at" => DateTime.to_iso8601(deadline_at)}}
    else
      _invalid -> {:error, {:invalid_work_result, :continuation}}
    end
  end

  defp prepare_continuation(_continuation),
    do: {:error, {:invalid_work_result, :continuation}}

  defp valid_text?(value, maximum_characters, maximum_bytes) do
    is_binary(value) and String.valid?(value) and
      String.length(value) in 1..maximum_characters and byte_size(value) <= maximum_bytes and
      :binary.match(value, <<0>>) == :nomatch and String.trim(value) != ""
  end

  defp utc_datetime?(%DateTime{} = value),
    do: value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0

  defp utc_datetime?(_value), do: false

  defp normalize_datetime(%DateTime{microsecond: {microsecond, _precision}} = value),
    do: %{value | microsecond: {microsecond, 6}}

  defp normalize_deadline(%DateTime{} = deadline_at) do
    if utc_datetime?(deadline_at),
      do: {:ok, normalize_datetime(deadline_at)},
      else: :error
  end

  defp normalize_deadline(deadline_at) when is_binary(deadline_at) do
    case DateTime.from_iso8601(deadline_at) do
      {:ok, parsed, 0} -> normalize_deadline(parsed)
      _invalid -> :error
    end
  end

  defp normalize_deadline(_deadline_at), do: :error
end
