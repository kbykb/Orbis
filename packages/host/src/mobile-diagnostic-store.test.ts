import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { MobileDiagnosticsBatch } from "@orbis/protocol";
import { MOBILE_DIAGNOSTIC_FILE, MobileDiagnosticStore } from "./mobile-diagnostic-store.js";

let directory = "";
beforeEach(async () => { directory = await mkdtemp(join(tmpdir(), "orbis-mobile-diagnostics-")); });
afterEach(async () => { await rm(directory, { recursive: true, force: true }); });
const batch = (id: string): MobileDiagnosticsBatch => ({ type: "diagnostics.mobile.batch", batchId: id,
  events: [{ id, at: 1, event: "attachment.picker.present", severity: "info" }] });
const read = async (path: string) => (await readFile(path, "utf8")).trim().split("\n").map(line => JSON.parse(line));

describe("mobile diagnostic persistence", () => {
  it("acknowledges after persistence and deduplicates retry batches per device", async () => {
    const store = new MobileDiagnosticStore(directory);
    const [first, retry] = await Promise.all([store.append("phone-a", batch("a")), store.append("phone-a", batch("a"))]);
    expect(retry).toBe(first);
    expect(await store.append("phone-a", batch("a"))).toBe(first);
    await store.append("phone-b", batch("a"));
    const records = await read(join(directory, MOBILE_DIAGNOSTIC_FILE));
    expect(records.map(record => record.deviceId)).toEqual(["phone-a", "phone-b"]);
    expect(records[0]).toMatchObject({ batchId: "a", receivedAt: first, event: "attachment.picker.present" });
  });

  it("keeps the preceding log when rotating and appends after a Host restart", async () => {
    const store = new MobileDiagnosticStore(directory, 200);
    await store.append("phone", batch("one"));
    await store.append("phone", batch("two"));
    const path = join(directory, MOBILE_DIAGNOSTIC_FILE);
    expect((await read(`${path}.1`)).map(record => record.id)).toEqual(["one"]);
    const restarted = new MobileDiagnosticStore(directory, 1024);
    await restarted.append("phone", batch("three"));
    expect((await read(path)).map(record => record.id)).toEqual(["two", "three"]);
  });

  it("rejects a failed write and allows the same batch to retry after storage recovers", async () => {
    const unavailable = join(directory, "blocked");
    await writeFile(unavailable, "not a directory");
    const store = new MobileDiagnosticStore(unavailable);
    await expect(store.append("phone", batch("retry"))).rejects.toThrow();
    await rm(unavailable);
    await store.append("phone", batch("retry"));
    expect((await read(join(unavailable, MOBILE_DIAGNOSTIC_FILE)))[0]).toMatchObject({ id: "retry" });
  });
});
