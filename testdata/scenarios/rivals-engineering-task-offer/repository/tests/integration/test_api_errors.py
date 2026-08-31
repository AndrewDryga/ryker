import pytest
import scraper_app


@pytest.mark.integration
def test_match_summary_uses_configured_rpc_timeout(client_app, marvel_client, monkeypatch):
    observed = {}

    async def capture_gate_api(rpc_api, rpc_data, rpc_timeout):
        observed["rpc_api"] = rpc_api
        observed["rpc_timeout"] = rpc_timeout
        return {"match_info": []}

    monkeypatch.setattr(scraper_app, "MATCH_SUMMARY_RPC_TIMEOUT_SECONDS", 10.0)
    monkeypatch.setattr(marvel_client, "gate_api", capture_gate_api)

    response = client_app.get(
        "/query_match_summary",
        params={
            "player_uid": 1602282958,
            "zone_id": 11001,
            "page": 0,
            "page_size": 10,
            "device_type": "pc",
        },
    )

    assert response.status_code == 200
    assert observed == {
        "rpc_api": "query_match_summary",
        "rpc_timeout": 10.0,
    }
