import {
  changePassword,
  confirmAccount,
  createAccount,
  createPairingInvite,
  deleteAccount,
  getAccount,
  redeemPairingInvite,
} from './accounts';
import { authenticate } from './auth';
import { pullChanges, pushChanges } from './changes';
import { addToInbox, listInbox, removeFromInbox } from './inbox';
import { createMailSender } from './mail';
import { Deps, Env, HttpError } from './types';
import { json } from './util';

function allow(request: Request, ...methods: string[]): void {
  if (!methods.includes(request.method)) {
    throw new HttpError(405, 'method_not_allowed', { Allow: methods.join(', ') });
  }
}

async function route(request: Request, env: Env, deps: Deps): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname.length > 1 ? url.pathname.replace(/\/+$/, '') : url.pathname;

  if (path === '/v1/accounts') {
    allow(request, 'POST');
    return createAccount(request, env, deps);
  }
  if (path === '/v1/accounts/confirm') {
    allow(request, 'POST');
    return confirmAccount(request, env, deps);
  }
  const pairingInvite = /^\/v1\/pairings\/([a-f0-9]{64})$/.exec(path);
  if (pairingInvite) {
    allow(request, 'GET');
    return redeemPairingInvite(pairingInvite[1], env, deps);
  }

  const inboxItem = /^\/v1\/inbox\/([^/]+)$/.exec(path);
  if (path === '/v1/account') {
    allow(request, 'GET', 'PUT', 'DELETE');
  } else if (path === '/v1/account/pairing') {
    allow(request, 'POST');
  } else if (path === '/v1/changes') {
    allow(request, 'GET', 'POST');
  } else if (path === '/v1/inbox') {
    allow(request, 'GET', 'POST');
  } else if (inboxItem) {
    allow(request, 'DELETE');
  } else {
    throw new HttpError(404, 'not_found');
  }

  const email = await authenticate(request, env, {
    allowUnconfirmed: path === '/v1/account' && request.method === 'DELETE',
  });
  switch (path) {
    case '/v1/account':
      if (request.method === 'GET') return getAccount(email, env);
      if (request.method === 'PUT') return changePassword(request, email, env);
      return deleteAccount(email, env);
    case '/v1/account/pairing':
      return createPairingInvite(request, email, env, deps);
    case '/v1/changes':
      return request.method === 'GET' ? pullChanges(url, email, env) : pushChanges(request, email, env, deps);
    case '/v1/inbox':
      return request.method === 'GET' ? listInbox(email, env) : addToInbox(request, email, env, deps);
    default:
      return removeFromInbox(decodeURIComponent(inboxItem![1]), email, env);
  }
}

/** The request handler, with the outside world passed in so tests can fake it. */
export function createHandler(deps: Deps) {
  return async (request: Request, env: Env): Promise<Response> => {
    try {
      return await route(request, env, deps);
    } catch (error) {
      if (error instanceof HttpError) return json({ error: error.code }, error.status, error.headers);
      console.error(error);
      return json({ error: 'internal_error' }, 500);
    }
  };
}

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return createHandler({ sendMail: createMailSender(env), now: Date.now })(request, env);
  },
};
