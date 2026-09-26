import {test} from 'node:test';
import assert from 'node:assert/strict';
import {liveRoutes} from '../../scripts/visual-routes.cjs';

test('the screenshot harness visits the live routes the router declares, never a retired one', () => {
  // Until 2026-09-25 the harness carried its own route list, which named
  // /decisions, /calibration, /card-lab and other pages removed weeks earlier
  // while missing every page added since.
  const routes = liveRoutes();
  for (const route of ['/', '/activity', '/conversations', '/memory/learned', '/integrations/slack', '/settings/models']) {
    assert(routes.includes(route), `${route} is served by the router`);
  }
  assert(routes.every(route => !route.includes(':') && !route.includes('#')), 'parameterised routes are discovered from rows');
  assert.equal(new Set(routes).size, routes.length);
});

test('routes are expanded from the router source, literal and templated', () => {
  const source = `
    live("/", Ryker.ControlPlane.WorkbenchLive)
    for path <-
          ~w(alpha beta) do
      live("/#{path}", Ryker.ControlPlane.WorkbenchLive)
    end
    for page <- ~w(one two) do
      live("/alpha/#{page}", Ryker.ControlPlane.WorkbenchLive)
    end
    live("/alpha/:ref", Ryker.ControlPlane.WorkbenchLive)
  `;
  assert.deepEqual(liveRoutes(source), ['/', '/alpha', '/beta', '/alpha/one', '/alpha/two']);
});
