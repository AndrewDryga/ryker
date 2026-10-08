defmodule Ryker.Publication.DeploymentSignalTest do
  use ExUnit.Case, async: true
  alias Ryker.Publication.DeploymentSignal

  test "accepts only the exact bounded lifecycle contract" do
    signal = %{
      "event_type" => "responder.publication_lifecycle.v1",
      "payload" => %{
        "environment" => "production",
        "kind" => "deployment",
        "references" => ["https://github.com/acme/ryker/pull/91", String.duplicate("a", 40)],
        "repository" => "ryker",
        "run_ref" => "deploy:provider:123",
        "state" => "succeeded",
        "target" => "ryker-web"
      }
    }

    assert DeploymentSignal.prepare(signal) == {:ok, signal}

    assert DeploymentSignal.authorize(signal, %{
             "environments" => ["production"],
             "kinds" => ["deployment", "terraform"],
             "repositories" => ["ryker"],
             "targets" => ["ryker-web"]
           }) == :ok

    assert DeploymentSignal.authorize(
             signal,
             %{
               "environments" => ["staging"],
               "kinds" => ["deployment"],
               "repositories" => ["ryker"],
               "targets" => ["ryker-web"]
             }
           ) == {:error, :publication_lifecycle_source_unauthorized}

    assert DeploymentSignal.prepare(put_in(signal, ["extra"], true)) ==
             {:error, {:invalid_publication_deployment_signal, :fields}}

    assert DeploymentSignal.prepare(put_in(signal, ["payload", "extra"], true)) ==
             {:error, {:invalid_publication_deployment_signal, :fields}}

    assert DeploymentSignal.prepare(put_in(signal, ["payload", "state"], "complete")) ==
             {:error, {:invalid_publication_deployment_signal, :state}}

    assert DeploymentSignal.prepare(
             put_in(signal, ["payload", "references"], ["duplicate", "duplicate"])
           ) == {:error, {:invalid_publication_deployment_signal, :references}}

    assert DeploymentSignal.prepare(put_in(signal, ["payload", "references"], [])) ==
             {:error, {:invalid_publication_deployment_signal, :references}}

    assert DeploymentSignal.prepare(put_in(signal, ["payload", "references"], [42])) ==
             {:error, {:invalid_publication_deployment_signal, :references}}

    assert DeploymentSignal.prepare(put_in(signal, ["payload", "environment"], " \t")) ==
             {:error, {:invalid_publication_deployment_signal, :environment}}

    assert DeploymentSignal.prepare(put_in(signal, ["payload", "run_ref"], nil)) ==
             {:error, {:invalid_publication_deployment_signal, :run_ref}}

    assert DeploymentSignal.prepare(
             put_in(signal, ["payload", "target"], String.duplicate("x", 1_025))
           ) == {:error, {:invalid_publication_deployment_signal, :target}}
  end
end
