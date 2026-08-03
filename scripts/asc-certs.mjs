// Lists the signing certificates on the account, and with REVOKE=true deletes
// the ones CI minted.
//
// Automatic signing plus -allowProvisioningUpdates mints a fresh Apple
// Development certificate on every release run, and the account holds a finite
// number of them. Left alone they accumulate until archiving fails with
// "Choose a certificate to revoke", which no code change can clear.
//
// Reads KEY_ID, ISSUER_ID and KEY_P8 from the environment.
import crypto from 'node:crypto';

// ES256 JWT, per Apple's "Generating Tokens for API Requests".
const b64 = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
const now = Math.floor(Date.now() / 1000);
const header = b64({ alg: 'ES256', kid: process.env.KEY_ID, typ: 'JWT' });
const payload = b64({
  iss: process.env.ISSUER_ID,
  iat: now,
  exp: now + 300,
  aud: 'appstoreconnect-v1',
});
const signature = crypto
  .createSign('SHA256')
  .update(`${header}.${payload}`)
  .sign({ key: process.env.KEY_P8, dsaEncoding: 'ieee-p1363' })
  .toString('base64url');
const token = `${header}.${payload}.${signature}`;

const call = async (path, method = 'GET') => {
  const response = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!response.ok) {
    console.log(`${method} ${path}: HTTP ${response.status} ${await response.text()}`);
    process.exit(1);
  }
  return response.status === 204 ? null : response.json();
};

const { data } = await call('/v1/certificates?limit=200');
const byType = {};
for (const cert of data) {
  const { certificateType: type, displayName, expirationDate } = cert.attributes;
  (byType[type] ||= []).push(`  ${expirationDate?.slice(0, 10)}  ${displayName}`);
}
console.log(`${data.length} certificate(s) on the account\n`);
for (const [type, rows] of Object.entries(byType)) {
  console.log(`${type}  (${rows.length})`);
  console.log(rows.sort().join('\n'));
  console.log('');
}

if (process.env.REVOKE !== 'true') process.exit(0);

// Only the ones CI made. A certificate named after a person is installed on a
// real Mac, and revoking it breaks signing there.
const disposable = data.filter(
  (cert) =>
    cert.attributes.certificateType === 'DEVELOPMENT' &&
    cert.attributes.displayName === 'Created via API'
);
console.log(`revoking ${disposable.length} CI certificate(s)`);
for (const cert of disposable) {
  await call(`/v1/certificates/${cert.id}`, 'DELETE');
  console.log(`  revoked ${cert.id}  ${cert.attributes.expirationDate?.slice(0, 10)}`);
}
