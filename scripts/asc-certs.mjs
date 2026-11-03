// Lists the signing certificates on the account, and with REVOKE=true deletes
// the ones automatic signing minted. With the argument "profiles" it instead
// installs the App Store provisioning profiles the release archive signs with.
//
// #515: the release job used to archive with automatic signing plus
// -allowProvisioningUpdates. Automatic signing archives with a Development
// identity, the runner has none, so xcodebuild minted a fresh Apple Development
// certificate every run, and revoking it afterwards made Apple email the owner
// every run. The job now signs manually with the imported Apple Distribution
// identity and the profiles from `profiles` mode, and never passes
// -allowProvisioningUpdates, so nothing mints; REVOKE=true stays as a safety
// net that should find 0.
//
// Reads KEY_ID, ISSUER_ID and KEY_P8 from the environment; `profiles` mode also
// DIST_CERT_SHA1 (the imported identity's SHA-1) and PROFILE_TARGETS, a list of
// target=bundle-id pairs. Never prints a key, a certificate or a profile body.
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

const call = async (path, method = 'GET', body) => {
  const response = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: body && JSON.stringify(body),
  });
  if (!response.ok) {
    console.log(`${method} ${path}: HTTP ${response.status} ${await response.text()}`);
    process.exit(1);
  }
  return response.status === 204 ? null : response.json();
};

const sha1Of = (cert) =>
  crypto.createHash('sha1').update(Buffer.from(cert.attributes.certificateContent || '', 'base64')).digest('hex').toUpperCase();
const { data } = await call('/v1/certificates?limit=200');
if (process.argv[2] === 'match') {
  // #515: whether DIST_CERT_SHA1 (the p12's certificate) is the account's current DISTRIBUTION
  // certificate. Prints only the verdict, never the hash or the certificate's name.
  const want = (process.env.DIST_CERT_SHA1 || '').toUpperCase();
  const hit = want && data.some((c) => c.attributes.certificateType === 'DISTRIBUTION' && sha1Of(c) === want);
  console.log(`the p12 certificate ${hit ? 'matches' : 'does not match'} the account's current DISTRIBUTION certificate`);
  process.exit(0);
}
if (process.argv[2] === 'profiles') {
  await installProfiles(data);
  process.exit(0);
}
const byType = {};
for (const cert of data) {
  const { certificateType: type, displayName, expirationDate } = cert.attributes;
  const name = process.env.CI ? (displayName === 'Created via API' ? displayName : '(named)') : displayName;
  (byType[type] ||= []).push(`  ${expirationDate?.slice(0, 10)}  ${name}`);
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
if (disposable.length && process.env.CI) {
  console.log('::warning::found a certificate automatic signing minted; nothing in the release job should mint one any more (#515)');
}
for (const cert of disposable) {
  await call(`/v1/certificates/${cert.id}`, 'DELETE');
  console.log(`  revoked ${cert.id}  ${cert.attributes.expirationDate?.slice(0, 10)}`);
}

// One App Store profile per signed target, named by us so Xcode-managed profiles
// (which manual signing refuses) are never picked. Reused while it is ACTIVE, holds
// the imported certificate and outlives this run by a day; otherwise replaced.
async function installProfiles(certs) {
  const fs = await import('node:fs');
  const os = await import('node:os');
  const sha1 = (process.env.DIST_CERT_SHA1 || '').toUpperCase();
  const cert = certs.find((c) => c.attributes.certificateContent && sha1Of(c) === sha1);
  if (!sha1 || !cert) {
    console.log('::error::the imported distribution certificate is not on the account (expired or revoked?); renew DIST_CERT_P12 (#515)');
    process.exit(1);
  }
  console.log(`signing identity: ${cert.attributes.certificateType} certificate ${cert.id}, expires ${cert.attributes.expirationDate?.slice(0, 10)}`);
  const dirs = ['Library/Developer/Xcode/UserData/Provisioning Profiles', 'Library/MobileDevice/Provisioning Profiles'].map(
    (d) => `${os.homedir()}/${d}`
  );
  const env = [];
  for (const pair of (process.env.PROFILE_TARGETS || '').split(/\s+/).filter(Boolean)) {
    const [target, bundle] = pair.split('=');
    const ids = await call(`/v1/bundleIds?filter[identifier]=${encodeURIComponent(bundle)}&limit=200`);
    const bundleId = ids.data.find((b) => b.attributes.identifier === bundle);
    if (!bundleId) {
      console.log(`::error::no bundle id ${bundle} on the account (#515)`);
      process.exit(1);
    }
    const name = `Dobby CI App Store ${bundle}`;
    const found = await call(
      `/v1/profiles?filter[name]=${encodeURIComponent(name)}&filter[profileType]=IOS_APP_STORE&include=certificates&limit=200&limit[certificates]=50`
    );
    const ours = found.data.filter((p) => p.attributes.name === name);
    const fresh = ours.find(
      (p) =>
        p.attributes.profileState === 'ACTIVE' &&
        Date.parse(p.attributes.expirationDate) > Date.now() + 86400e3 &&
        p.relationships?.certificates?.data?.some((c) => c.id === cert.id)
    );
    let profile = fresh;
    if (!profile) {
      for (const stale of ours) await call(`/v1/profiles/${stale.id}`, 'DELETE');
      ({ data: profile } = await call('/v1/profiles', 'POST', {
        data: {
          type: 'profiles',
          attributes: { name, profileType: 'IOS_APP_STORE' },
          relationships: {
            bundleId: { data: { type: 'bundleIds', id: bundleId.id } },
            certificates: { data: [{ type: 'certificates', id: cert.id }] },
          },
        },
      }));
    }
    const { uuid, profileContent, expirationDate } = profile.attributes;
    for (const dir of dirs) {
      fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(`${dir}/${uuid}.mobileprovision`, Buffer.from(profileContent, 'base64'));
    }
    console.log(`profile "${name}" ${uuid} for ${target}: ${fresh ? 'reused' : `created (replaced ${ours.length})`}, expires ${expirationDate?.slice(0, 10)}`);
    env.push(`DOBBY_PROFILE_${target}=${uuid}`);
  }
  if (process.env.GITHUB_ENV) fs.appendFileSync(process.env.GITHUB_ENV, env.join('\n') + '\n');
}
