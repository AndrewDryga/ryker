async def gate_api_response(
    rpc_api: str,
    rpc_data: Any,
    rpc_timeout: float | None = None,
) -> Any:
    try:
        if rpc_timeout is None:
            return await client.gate_api(rpc_api, rpc_data)
        return await client.gate_api(rpc_api, rpc_data, rpc_timeout=rpc_timeout)
    except asyncio.TimeoutError:
        client.logger.warning(f"Gate API timeout: {rpc_api}", extra={'server_type': 'GATE'})
        return error_response("Timeout", 504)
    except RuntimeError as error:
        client.logger.error(f"Gate API unavailable: {rpc_api}: {error}", extra={'server_type': 'GATE'})
        return error_response("Service Unavailable", 503)
