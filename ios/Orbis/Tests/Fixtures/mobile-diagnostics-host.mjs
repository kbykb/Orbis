// Isolated Swift interoperability launcher. All pairing, encryption, parsing,
// acknowledgements and diagnostic persistence use the production Node classes.
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const repository = process.env.ORBIS_TEST_REPOSITORY;
if (!repository) throw new Error("Set ORBIS_TEST_REPOSITORY to the built Orbis repository");
const { createRelayServer } = await import(pathToFileURL(join(repository, "packages/relay/dist/index.js")));
const { HostService } = await import(pathToFileURL(join(repository, "packages/host/dist/host-service.js")));
const folder = process.argv[2];
const relay = await createRelayServer({ port: 0, runtimeCredentials: ["isolated-host"],
  adminToken: "isolated-owner", stateFile: join(folder, "relay-state.json") });
const host = await HostService.create({ relayUrl: relay.url, credential: "isolated-host", adminToken: "isolated-owner",
  stateDir: join(folder, "host"), sessionsRoot: join(folder, "sessions"), loopback: false, lan: false, reconnect: false,
  onDeviceError: (_deviceId, error) => { process.stderr.write(`${error.stack ?? error}\n`); } });
let stopping = false;
const stop = async () => {
  if (stopping) return;
  stopping = true;
  await host.stop();
  await relay.close();
};
process.on("SIGTERM", () => { void stop(); });
process.on("SIGINT", () => { void stop(); });
await host.start();
const pairing = await host.openPairingWindow();
await writeFile(join(folder, "qr.json"), JSON.stringify(pairing.payload));
