import { describe, expect, it } from "vitest";
import { DeviceE2ePayloadSchema, PROTOCOL_VERSION, RelayToDeviceMessageSchema } from "./index.js";

describe("mobile diagnostics messages", () => {
  const event = { id: "event-1", at: 1, event: "attachment.picker.present", severity: "info", detail: { attemptId: "attempt-1" } };
  const batch = { type: "diagnostics.mobile.batch", protocolVersion: PROTOCOL_VERSION, batchId: "batch-1", events: [event] };

  it("accepts bounded facts on the encrypted request and ack unions", () => {
    expect(DeviceE2ePayloadSchema.parse(batch)).toEqual(batch);
    expect(RelayToDeviceMessageSchema.parse({ type: "diagnostics.mobile.ack", protocolVersion: PROTOCOL_VERSION, batchId: "batch-1", storedAt: 2 }))
      .toMatchObject({ batchId: "batch-1", storedAt: 2 });
    expect(DeviceE2ePayloadSchema.safeParse({ ...batch, events: [] }).success).toBe(false);
    expect(DeviceE2ePayloadSchema.safeParse({ ...batch, events: Array.from({ length: 33 }, () => event) }).success).toBe(false);
    expect(DeviceE2ePayloadSchema.safeParse({ ...batch, events: [{ ...event, body: "chat contents" }] }).success).toBe(false);
    expect(DeviceE2ePayloadSchema.safeParse({ ...batch, events: [{ ...event, detail: { value: "x".repeat(257) } }] }).success).toBe(false);
  });
});
