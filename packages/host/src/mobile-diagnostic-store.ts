import { appendFile, mkdir, rename, stat } from "node:fs/promises";
import { join } from "node:path";
import type { MobileDiagnosticsBatch } from "@orbis/protocol";

export const MOBILE_DIAGNOSTIC_FILE = "mobile-diagnostics.ndjson";

/** Low-volume opt-in phone diagnostics; disk writes never block Host frame dispatch. */
export class MobileDiagnosticStore {
  readonly #path: string;
  readonly #stateDir: string;
  readonly #maxBytes: number;
  readonly #pending = new Map<string, Promise<number>>();
  readonly #stored = new Map<string, number>();
  #writeChain: Promise<unknown> = Promise.resolve();
  #bytes: number | undefined;

  constructor(stateDir: string, maxBytes = 2 * 1024 * 1024) {
    this.#stateDir = stateDir;
    this.#path = join(stateDir, MOBILE_DIAGNOSTIC_FILE);
    this.#maxBytes = maxBytes;
  }

  append(deviceId: string, batch: MobileDiagnosticsBatch): Promise<number> {
    const key = JSON.stringify([deviceId, batch.batchId]);
    const storedAt = this.#stored.get(key);
    if (storedAt !== undefined) return Promise.resolve(storedAt);
    const pending = this.#pending.get(key);
    if (pending) return pending;
    if (this.#pending.size >= 16) return Promise.reject(new Error("Mobile diagnostic write queue is full"));
    const write = this.#writeChain.then(async () => {
      if (this.#bytes === undefined) {
        await mkdir(this.#stateDir, { recursive: true });
        try { this.#bytes = (await stat(this.#path)).size; }
        catch (error) {
          if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
          this.#bytes = 0;
        }
      }
      const at = Date.now();
      const text = batch.events.map(event => JSON.stringify({ deviceId, batchId: batch.batchId, receivedAt: at, ...event }) + "\n").join("");
      const bytes = Buffer.byteLength(text);
      if (this.#bytes > 0 && this.#bytes + bytes > this.#maxBytes) {
        await rename(this.#path, `${this.#path}.1`);
        this.#bytes = 0;
      }
      await appendFile(this.#path, text, { encoding: "utf8", mode: 0o600 });
      this.#bytes += bytes;
      this.#stored.set(key, at);
      if (this.#stored.size > 128) this.#stored.delete(this.#stored.keys().next().value!);
      return at;
    }).finally(() => { this.#pending.delete(key); });
    this.#pending.set(key, write);
    this.#writeChain = write.catch(() => {});
    return write;
  }

  async flush(): Promise<void> { await this.#writeChain; }
}
