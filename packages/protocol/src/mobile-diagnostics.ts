import { z } from "zod";

export const HOST_FEATURE_MOBILE_DIAGNOSTICS = "diagnostics.mobile";

/** Opt-in mobile lifecycle facts. Callers must omit chat, filenames, file contents and credentials. */
export const MobileDiagnosticEventSchema = z.strictObject({
  id: z.string().min(1).max(128),
  at: z.number().int().nonnegative(),
  event: z.string().min(1).max(64).regex(/^[a-z][a-z0-9_.-]*$/),
  severity: z.enum(["info", "warning", "error"]),
  detail: z.record(z.string().min(1).max(32), z.string().max(256))
    .refine(value => Object.keys(value).length <= 12).optional(),
});
export type MobileDiagnosticEvent = z.infer<typeof MobileDiagnosticEventSchema>;

export const MobileDiagnosticsBatchSchema = z.strictObject({
  type: z.literal("diagnostics.mobile.batch"),
  batchId: z.string().min(1).max(128),
  events: z.array(MobileDiagnosticEventSchema).min(1).max(32),
});
export type MobileDiagnosticsBatch = z.infer<typeof MobileDiagnosticsBatchSchema>;

/** Sent only after the authenticated device's batch has been written to the Host log. */
export const MobileDiagnosticsAckSchema = z.strictObject({
  type: z.literal("diagnostics.mobile.ack"),
  batchId: z.string().min(1).max(128),
  storedAt: z.number().int().nonnegative(),
});
