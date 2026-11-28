#!/usr/bin/env node
// This fixture substitutes the provider, while using Coop's real native broker.
import readline from 'node:readline';
import {spawnSync} from 'node:child_process';
const sessionId = 'guarded-provider-session';
const selected = new Map([['model', 'fixture-default']]);
const write = value => process.stdout.write(JSON.stringify(value) + '\n');
for await (const line of readline.createInterface({input:process.stdin})) {
  const request = JSON.parse(line);
  if (request.id === undefined) continue;
  let result;
  try {
    switch (request.method) {
      case 'initialize': result={protocolVersion:1,agentCapabilities:{},authMethods:[]};break;
      case 'session/load': result={configOptions:[]};break;
      case 'session/new': result={sessionId,configOptions:[]};break;
      case 'session/set_config_option':
        selected.set(request.params.configId, request.params.value);
        result = {configOptions: [...selected].map(([id, currentValue]) => ({id, currentValue}))};
        break;
      case 'session/prompt': {
        if (process.env.FLEET_PROVIDER === 'codex') {
          const response = spawnSync('/opt/fleet-proof/native-socket', [selected.get('model')], {encoding:'utf8'});
          if (response.error) throw Error('native socket could not start: ' + response.error.code);
          if (response.status !== 0) throw Error('native socket failed: ' + response.stderr);
          write({jsonrpc:'2.0',method:'session/update',params:{sessionId,update:{sessionUpdate:'agent_message_chunk',content:{type:'text',text:'guarded controller reply'}}}});
          result={stopReason:'end_turn'};break;
        }
        if (!(process.env.HTTPS_PROXY || process.env.https_proxy)) throw Error('native proxy is missing');
        const marker = process.env.ANTHROPIC_API_KEY;
        if (marker !== 'coop-native-claude-v1') throw Error('unsafe credential projection');
        const response=spawnSync('curl',['--silent','--show-error','--fail-with-body','--max-time','180',
          '--cacert',process.env.SSL_CERT_FILE,'https://api.anthropic.com/v1/messages?beta=true',
          '-H','content-type: application/json','-H','anthropic-version: 2023-06-01',
          '-H','x-api-key: '+marker,'--data-binary',JSON.stringify({model:selected.get('model') === 'sonnet' ? 'claude-sonnet-5-5' : selected.get('model'),max_tokens:32,messages:[{role:'user',content:'hello'}]})],{encoding:'utf8'});
        if(response.status!==0 || !response.stdout.includes('guarded controller reply')) throw Error('native request failed: '+response.status+' '+response.stderr+' '+response.stdout);
        write({jsonrpc:'2.0',method:'session/update',params:{sessionId,update:{sessionUpdate:'agent_message_chunk',content:{type:'text',text:'guarded controller reply'}}}});
        result={stopReason:'end_turn'};break;
      }
      default: throw Error('unsupported fixture method: '+request.method);
    }
    write({jsonrpc:'2.0',id:request.id,result});
  } catch(error) {write({jsonrpc:'2.0',id:request.id,error:{code:-32603,message:error.message}});}
}
