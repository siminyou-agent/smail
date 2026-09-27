#!/usr/bin/env node
// Owner-operated release helper. Secret material is loaded locally, never printed.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { parseEnv } from 'node:util';
import { createPrivateKey, sign } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
process.chdir(root);
const config = fs.readFileSync('project.yml', 'utf8');
const setting = name => {
  const value = config.match(new RegExp(`${name}: ['"]?([^'"\\n]+)`))?.[1]?.trim();
  if (!value) throw new Error(`Missing ${name}`);
  return value;
};
const bundleID = setting('PRODUCT_BUNDLE_IDENTIFIER');
const version = setting('MARKETING_VERSION');
const buildNumber = setting('CURRENT_PROJECT_VERSION');
const archivePath = `DerivedData/Archives/Smail-${version}-${buildNumber}.xcarchive`;
const envFile = process.env.SMAIL_RELEASE_ENV ?? path.join(root, '.env');
const env = { ...(fs.existsSync(envFile) ? parseEnv(fs.readFileSync(envFile, 'utf8')) : {}), ...process.env };
const names = Object.keys(env).filter(name => /ASC|APP_?STORE/i.test(name));
function required(name) {
  if (!env[name]?.trim()) throw new Error(`Missing ${name}`);
  return env[name].trim();
}
const groupName = env.SMAIL_TESTFLIGHT_GROUP ?? 'Internal Testing';
function credential(known, pattern, label) {
  for (const name of known) if (env[name]) return env[name];
  const found = names.filter(name => pattern.test(name));
  if (found.length !== 1) throw new Error(`Missing or ambiguous ${label}`);
  return env[found[0]];
}
const keyID = credential(['ASC_KEY_ID', 'APP_STORE_CONNECT_KEY_ID'], /KEY_?ID$/i, 'ASC key ID');
const issuerID = credential(['ASC_ISSUER_ID', 'APP_STORE_CONNECT_ISSUER_ID'], /ISSUER(?:_?ID)?$/i, 'ASC issuer ID');
const keyPath = credential(['ASC_KEY_PATH', 'ASC_P8_PATH', 'APP_STORE_CONNECT_KEY_PATH'], /(?:P8|KEY).*(?:PATH|FILE)$/i, 'ASC signing key path');
function token() {
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const input = `${encode({ alg: 'ES256', kid: keyID, typ: 'JWT' })}.${encode({ iss: issuerID, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' })}`;
  return `${input}.${sign('sha256', Buffer.from(input), { key: createPrivateKey(fs.readFileSync(keyPath)), dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
}
async function api(route, method = 'GET', body) {
  const response = await fetch(`https://api.appstoreconnect.apple.com${route}`, {
    method, headers: { Authorization: `Bearer ${token()}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(30000),
  });
  if (response.status === 204) return [];
  const result = await response.json();
  if (!response.ok) throw new Error(JSON.stringify({ status: response.status, errors: result.errors?.map(({ code, title, detail }) => ({ code, title, detail })) }));
  return Array.isArray(result.data) ? result.data : result.data ? [result.data] : [];
}
async function app() {
  const record = (await api(`/v1/apps?filter[bundleId]=${bundleID}&limit=10`))[0];
  if (!record) throw new Error('Create the Smail app record in App Store Connect first.');
  return record;
}
async function group(appID) {
  return (await api(`/v1/apps/${appID}/betaGroups?limit=100`)).find(x => x.attributes.name === groupName && x.attributes.isInternalGroup);
}
async function build(appID) {
  const result = (await api(`/v1/builds?filter[app]=${appID}&filter[version]=${buildNumber}&limit=10`)).find(x => x.attributes.processingState === 'VALID');
  if (!result) throw new Error(`Build ${buildNumber} has not reached VALID.`);
  return result;
}
function run(command, args) {
  const result = spawnSync(command, args, { stdio: 'inherit' });
  if (result.status !== 0) throw new Error(`${command} failed (${result.status})`);
}
const command = process.argv[2] ?? 'status';
if (command === 'status') {
  console.log(JSON.stringify({ apps: await api(`/v1/apps?filter[bundleId]=${bundleID}&limit=10`), identifiers: await api(`/v1/bundleIds?filter[identifier]=${bundleID}&limit=10`) }, null, 2));
} else if (command === 'provision') {
  let identifier = (await api(`/v1/bundleIds?filter[identifier]=${bundleID}&limit=10`))[0];
  if (!identifier) identifier = (await api('/v1/bundleIds', 'POST', { data: { type: 'bundleIds', attributes: { identifier: bundleID, name: 'Smail', platform: 'IOS' } } }))[0];
  const certs = await api('/v1/certificates?limit=200&fields[certificates]=name,serialNumber,expirationDate,certificateType');
  const serial = required('ASC_DISTRIBUTION_SERIAL').toUpperCase();
  const cert = certs.find(x => x.attributes.serialNumber?.toUpperCase() === serial);
  if (!cert) throw new Error('Installed Apple Distribution certificate not found in team.');
  const profiles = await api('/v1/profiles?filter[profileType]=IOS_APP_STORE&limit=200&fields[profiles]=name,uuid,profileState');
  const existing = profiles.find(x => x.attributes.name === 'Smail App Store' && x.attributes.profileState === 'ACTIVE');
  const [profile] = existing ? await api(`/v1/profiles/${existing.id}`) : await api('/v1/profiles', 'POST', { data: {
    type: 'profiles', attributes: { name: 'Smail App Store', profileType: 'IOS_APP_STORE' },
    relationships: { bundleId: { data: { type: 'bundleIds', id: identifier.id } }, certificates: { data: [{ type: 'certificates', id: cert.id }] } },
  } });
  const { uuid, profileContent, expirationDate } = profile.attributes;
  if (!uuid || !profileContent) throw new Error('Provisioning profile content missing.');
  const directory = path.join(os.homedir(), 'Library/Developer/Xcode/UserData/Provisioning Profiles');
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  fs.writeFileSync(path.join(directory, `${uuid}.mobileprovision`), Buffer.from(profileContent, 'base64'), { mode: 0o600 });
  console.log(JSON.stringify({ installed: true, uuid, expirationDate }));
} else if (command === 'archive') {
  run('xcodebuild', ['archive', '-project', 'Smail.xcodeproj', '-scheme', 'Smail', '-configuration', 'Release', '-destination', 'generic/platform=iOS', '-archivePath', archivePath,
    `DEVELOPMENT_TEAM=${required('APPLE_TEAM_ID')}`, '-quiet']);
} else if (command === 'export') {
  run('xcodebuild', ['-exportArchive', '-archivePath', archivePath, '-exportPath', 'DerivedData/TestFlight', '-exportOptionsPlist', 'Config/ExportOptions.plist', '-quiet']);
} else if (command === 'upload') {
  await app();
  run('xcrun', ['altool', '--upload-app', '--type', 'ios', '--file', 'DerivedData/TestFlight/Smail.ipa', '--apiKey', keyID, '--apiIssuer', issuerID, '--p8-file-path', keyPath]);
} else if (command === 'testflight') {
  const record = await app();
  console.log(JSON.stringify({ app: record.id, builds: await api(`/v1/builds?filter[app]=${record.id}&sort=-uploadedDate&limit=5`), groups: await api(`/v1/apps/${record.id}/betaGroups?limit=100`) }, null, 2));
} else if (command === 'prepare-testflight') {
  const record = await app();
  const existing = await group(record.id);
  console.log(JSON.stringify(existing ?? (await api('/v1/betaGroups', 'POST', { data: {
    type: 'betaGroups', attributes: { name: groupName, isInternalGroup: true }, relationships: { app: { data: { type: 'apps', id: record.id } } },
  } }))[0], null, 2));
} else if (command === 'release-notes') {
  const record = await app(); const release = await build(record.id);
  const section = fs.readFileSync('RELEASE_NOTES.md', 'utf8').split(/^## /m).find(text => text.startsWith(`${version} (${buildNumber})`));
  if (!section) throw new Error('Release notes do not match version/build.');
  const existing = await api(`/v1/builds/${release.id}/betaBuildLocalizations?limit=100`);
  for (const [locale, heading] of [['en-US', 'English'], ['zh-Hans', '中文']]) {
    const whatsNew = section.split(`### ${heading}`)[1]?.split('### ')[0]?.trim();
    if (!whatsNew || whatsNew.length > 4000) throw new Error(`Invalid notes: ${locale}`);
    const current = existing.find(x => x.attributes.locale === locale);
    if (current) await api(`/v1/betaBuildLocalizations/${current.id}`, 'PATCH', { data: { type: 'betaBuildLocalizations', id: current.id, attributes: { whatsNew } } });
    else await api('/v1/betaBuildLocalizations', 'POST', { data: { type: 'betaBuildLocalizations', attributes: { locale, whatsNew }, relationships: { build: { data: { type: 'builds', id: release.id } } } } });
    console.log(JSON.stringify({ locale, saved: true }));
  }
} else if (command === 'distribute') {
  const record = await app(); const release = await build(record.id); const target = await group(record.id);
  if (!target) throw new Error('Internal group missing.');
  if (release.attributes.usesNonExemptEncryption === null) await api(`/v1/builds/${release.id}`, 'PATCH', { data: { type: 'builds', id: release.id, attributes: { usesNonExemptEncryption: false } } });
  await api(`/v1/betaGroups/${target.id}/relationships/builds`, 'POST', { data: [{ type: 'builds', id: release.id }] });
  const detail = (await api(`/v1/builds/${release.id}/buildBetaDetail`))[0];
  await api(`/v1/buildBetaDetails/${detail.id}`, 'PATCH', { data: { type: 'buildBetaDetails', id: detail.id, attributes: { autoNotifyEnabled: true } } });
  console.log(JSON.stringify({ group: target.id, build: release.id, detail: await api(`/v1/builds/${release.id}/buildBetaDetail`) }, null, 2));
} else if (command === 'grant-app-access') {
  const email = process.argv[3];
  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw new Error('Provide the explicitly approved existing user email.');
  const record = await app();
  const user = (await api(`/v1/users?filter[username]=${encodeURIComponent(email)}&limit=10`)).find(x => x.attributes.username.toLowerCase() === email.toLowerCase());
  if (!user) throw new Error('User is not an existing App Store Connect user.');
  const visible = await api(`/v1/users/${user.id}/visibleApps?limit=200`);
  if (!user.attributes.allAppsVisible && !visible.some(x => x.id === record.id)) {
    await api(`/v1/users/${user.id}/relationships/visibleApps`, 'POST', { data: [{ type: 'apps', id: record.id }] });
  }
  const verified = await api(`/v1/users/${user.id}/visibleApps?limit=200`);
  if (!user.attributes.allAppsVisible && !verified.some(x => x.id === record.id)) throw new Error('App access not confirmed.');
  console.log(JSON.stringify({ email, roles: user.attributes.roles, allAppsVisible: user.attributes.allAppsVisible,
    apps: verified.map(x => ({ id: x.id, name: x.attributes.name })) }, null, 2));
} else if (command === 'invite-owner') {
  const email = required('SMAIL_TESTER_EMAIL');
  const record = await app(); const target = await group(record.id);
  if (!target) throw new Error('Internal group missing.');
  const user = (await api(`/v1/users?filter[username]=${encodeURIComponent(email)}&limit=10`)).find(x => x.attributes.username.toLowerCase() === email.toLowerCase());
  if (!user) throw new Error('Owner must already be an App Store Connect user for internal testing.');
  const existing = (await api(`/v1/betaGroups/${target.id}/betaTesters?limit=100`)).find(x => x.attributes.email.toLowerCase() === email.toLowerCase());
  const result = existing ?? (await api('/v1/betaTesters', 'POST', { data: {
    type: 'betaTesters', attributes: { email, firstName: user.attributes.firstName, lastName: user.attributes.lastName },
    relationships: { betaGroups: { data: [{ type: 'betaGroups', id: target.id }] } },
  } }))[0];
  console.log(JSON.stringify(result, null, 2));
} else if (command === 'release-status') {
  const record = await app(); const release = await build(record.id); const target = await group(record.id);
  if (!target) throw new Error('Internal group missing.');
  console.log(JSON.stringify({ app: { id: record.id, name: record.attributes.name }, build: release,
    prerelease: await api(`/v1/builds/${release.id}/preReleaseVersion`), detail: await api(`/v1/builds/${release.id}/buildBetaDetail`),
    group: target, groupBuilds: await api(`/v1/betaGroups/${target.id}/builds?limit=100`), testers: await api(`/v1/betaGroups/${target.id}/betaTesters?limit=100`),
  }, null, 2));
} else throw new Error('Unknown release command.');
