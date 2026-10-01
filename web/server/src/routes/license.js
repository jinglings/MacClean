import { enforceLimit, sendJson } from '../http.js';
import { licenseActivate, licenseDeactivate, licenseValidate } from '../store.js';

/** LemonSqueezy-compatible License API (form-encoded or JSON). */
export function licenseRoutes({ db, limiters }) {
  const endpoint = (flag, fn) => ({ res, body, ip }) => {
    enforceLimit(limiters.license, ip, { [flag]: false });
    const { status, body: out } = fn(db, body, ip);
    sendJson(res, status, out);
  };
  return [
    ['POST', '/api/licenses/activate', endpoint('activated', licenseActivate)],
    ['POST', '/api/licenses/validate', endpoint('valid', licenseValidate)],
    ['POST', '/api/licenses/deactivate', endpoint('deactivated', licenseDeactivate)],
  ];
}
